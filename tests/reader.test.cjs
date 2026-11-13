/* Run: NODE_PATH=/tmp/lb-reader-tests/node_modules node --test ios/LongBlogInbox/tests/reader.test.cjs
   Install tooling only in /tmp: npm install --prefix /tmp/lb-reader-tests jsdom@26.1.0 */
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {JSDOM} = require('jsdom');
const root = path.resolve(__dirname, '..');
const resources = path.join(root, 'resources/Reader');
// Synthetic records keep default tests independent of personal blog exports.
const posts = Array.from({length:18}, (_, i) => ({
  id: i === 1 ? 'FixtureTarget' : (i === 2 ? '2epdE8sgosX8' : `Fixture${i}`),
  slug: i === 1 ? 'fixture-target' : (i === 2 ? '2epdE8sgosX8' : `fixture-${i}`),
  title: `合成文章 ${i}`, summary: `合成摘要 ${i}`,
  contentHtml: '<p><span class="math-tex">$x^2$</span></p>' +
    '<table><tr><td>合成表格</td></tr></table><pre><code>sample</code></pre>' +
    '<img src="/trilium-assets/fixture.png">' +
    (i === 0 ? '<a class="include-note-card" data-note-id="FixtureTarget" href="/blog/fixture-target/">合成关联</a>' : '')
}));
function setup(html, extra = {}) {
  const dom = new JSDOM(fs.readFileSync(path.join(resources,'index.html'),'utf8'), {url:'https://reader.invalid/index.html',runScripts:'outside-only'});
  for (const file of ['vendor/katex.min.js','reader.js']) dom.window.eval(fs.readFileSync(path.join(resources,file),'utf8'));
  const messages=[];
  dom.window.LBReader.render({title:'测试 <script>',meta:'只读',html,site:'https://huowenlong.com/',posts,...extra}, dom.window.document, m=>messages.push(m));
  return {dom, doc:dom.window.document, messages, api:dom.window.LBReader};
}
test('real generated content: every post renders; real Trilium math, code, image, table and card shapes survive', () => {
  let math=0, tables=0, code=0, images=0, cards=0;
  for (const post of posts) {
    const {doc,dom} = setup(post.contentHtml);
    math += doc.querySelectorAll('.katex').length;
    tables += doc.querySelectorAll('.table-scroll > table').length;
    code += doc.querySelectorAll('.code-toolbar button').length;
    images += doc.querySelectorAll('img[src^="https://huowenlong.com/trilium-assets/"]').length;
    cards += doc.querySelectorAll('.include-note-card[data-post]').length;
    for (const table of doc.querySelectorAll('table')) assert.equal(table.parentElement.className,'table-scroll');
    assert.equal(doc.querySelectorAll('script,iframe,object').length,0);
    dom.window.close();
  }
  assert.ok(posts.length >= 18); assert.ok(math>0); assert.ok(tables>0); assert.ok(code>0); assert.ok(images>0); assert.ok(cards>0);
  console.log(JSON.stringify({posts:posts.length,math,tables,code,images,cards}));
});
test('math matches site contract: marked single dollars, display delimiters, raw delimiters, prices and code exclusions', () => {
  const html = String.raw`<p>价格 $20 与 $30</p><p><span class="math-tex">$x^2$</span></p><span class="math-tex">\[\frac{a}{b}\]</span><p>\(E=mc^2\) 和 $$x+y$$</p><pre><code>\(not math\)</code></pre><span class="math-tex">\badcommand{x}</span>`;
  const {doc,dom} = setup(html);
  assert.equal(doc.querySelectorAll('.katex').length,4);
  assert.equal(doc.querySelectorAll('.katex-display').length,2);
  assert.ok(doc.querySelector('article p').textContent.includes('$20'));
  assert.equal(doc.querySelectorAll('pre .katex').length,0);
  assert.ok(doc.querySelector('.math-error').textContent.includes('badcommand'));
  dom.window.close();
});
test('sanitize before attach: host injections, event attributes, SVG, executable URLs, srcdoc and forged controls cannot survive', () => {
  const html = `<link data-trilium-fnos-manager href="https://evil.invalid/x.css"><script data-trilium-fnos-manager>window.pwned=true</script><p id="title" onclick="webkit.messageHandlers.reader.postMessage({})" style="position:fixed;background:url(https://evil.invalid/x)">safe</p><img src="/trilium-assets/test.png" onerror="window.pwned=true" srcset="https://evil.invalid/x 2x"><img src="data:image/svg+xml,evil"><img src="https://evil.invalid/tracker"><a href="javascript:alert(1)">bad</a><a href="file:///etc/passwd">file</a><a href="https://user:pass@huowenlong.com/">creds</a><svg onload="alert(1)"><a href="x">svg</a></svg><iframe srcdoc="bad"></iframe><button data-post="x">fake</button><form action="https://evil.invalid/"><input></form>`;
  const {doc,dom,messages} = setup(html);
  assert.equal(dom.window.pwned,undefined); assert.deepEqual(messages,[]);
  assert.equal(doc.querySelectorAll('link:not([rel="stylesheet"]),script,svg,iframe,button,input,form').length,0);
  assert.equal(doc.querySelectorAll('img').length,1);
  for (const el of doc.getElementById('content').querySelectorAll('*')) for (const a of el.attributes) assert.ok(!a.name.startsWith('on') && !['srcset','srcdoc'].includes(a.name));
  assert.equal(doc.querySelector('#article-title').getAttribute('style'),null);
  for (const a of doc.querySelectorAll('article a')) assert.equal(a.getAttribute('href'),null);
  dom.window.close();
});
test('internal resolution uses real ids/slugs/include-note references, never an off-site slug collision', () => {
  const {api,dom} = setup(''); const p = posts.find(p=>p.id==='2epdE8sgosX8'); assert.ok(p);
  for (const raw of [`/blog/${p.slug}/`,`https://huowenlong.com/blog/${p.slug}/`,`#root/parent/${p.id}`,`/#root/parent/${p.id}`,`#${p.id}`,`/notes/${p.id}`,`/api/notes/${p.id}`]) assert.equal(api.findPost(raw,null,posts,'https://huowenlong.com/').id,p.id,raw);
  assert.equal(api.findPost('/missing',p.id,posts,'https://huowenlong.com/').id,p.id);
  assert.equal(api.findPost(`https://evil.invalid/blog/${p.slug}/`,null,posts,'https://huowenlong.com/'),null);
  assert.equal(api.safeURL('javascript:alert(1)','https://huowenlong.com/',false),null);
  assert.equal(api.safeURL('https://evil.invalid/a','https://huowenlong.com/',true),null);
  const renamed=[{...p,slug:'custom-slug'}]; assert.equal(api.findPost('/blog/custom-slug/',null,renamed,'https://huowenlong.com/').id,p.id);
  dom.window.close();
});
test('real included article card is rebuilt with corresponding internal post title and summary', () => {
  const source = posts.find(p=>p.contentHtml.includes('include-note-card'));
  const {doc,dom} = setup(source.contentHtml); const card=doc.querySelector('.include-note-card');
  const target=posts.find(p=>p.id===card.dataset.post); assert.ok(target);
  assert.equal(card.querySelector('.include-note-card-title').textContent,target.title);
  assert.equal(card.querySelector('.include-note-card-summary').textContent,target.summary);
  dom.window.close();
});
test('code copy source is preserved byte-for-byte; non-user synthetic events cannot call bridge', () => {
  const source='printf "你好"\n\t echo x < y\n';
  const {doc,dom,messages}=setup('<pre><code class="language-text-x-sh">printf "你好"\n\t echo x &lt; y\n</code></pre>');
  assert.equal(doc.querySelector('pre code').textContent,source);
  assert.equal(doc.querySelector('.code-toolbar span').textContent,'text-x-sh');
  doc.querySelector('button').click(); assert.deepEqual(messages,[]);
  dom.window.close();
});
test('bounded article size and nesting fail predictably',()=>{
  assert.throws(()=>setup('x'.repeat(4194305)),/文章过大/);
  assert.throws(()=>setup('<div>'.repeat(102)+'x'+'</div>'.repeat(102)),/结构过于复杂/);
});
test('bundled template CSP and native source retain isolated-world and bounded image safeguards',()=>{
  const html=fs.readFileSync(path.join(resources,'index.html'),'utf8');
  assert.ok(html.includes("script-src 'none'")); assert.ok(!html.includes('<script'));
  const native=fs.readFileSync(path.join(root,'src/LBPostReader.m'),'utf8');
  for (const text of ['WKContentWorld worldWithName','body.count != 3','message.frameInfo.mainFrame','_token','12 * 1024 * 1024','kCGImageSourceThumbnailMaxPixelSize:@2560','safeAreaLayoutGuide.topAnchor','inContentWorld:_world']) assert.ok(native.includes(text),text);
  const css=fs.readFileSync(path.join(resources,'reader.css'),'utf8');
  for(const text of ['.table-scroll','overflow-x:auto','margin:0 auto','prefers-color-scheme:dark','white-space:pre','tab-size:4']) assert.ok(css.includes(text),text);
});
