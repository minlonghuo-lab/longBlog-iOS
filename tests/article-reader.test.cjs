/* Run without spawning workers on iSH:
 * NODE_PATH=/tmp/lb-reader-tests/node_modules node -e "require('./ios/LongBlogInbox/tests/article-reader.test.cjs')"
 * Test dependency: npm install --prefix /tmp/lb-reader-tests jsdom@26.1.0
 */
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {JSDOM} = require('jsdom');
const root = path.resolve(__dirname,'..');
const dir = path.join(root,'resources/Reader');
const site = 'https://blog.example.test/';
const capability = 'lbreader-resource://12345678-abcd-1234-abcd-123456789012/';
function setup(markdown, extra = {}) {
  const dom = new JSDOM(fs.readFileSync(path.join(dir,'index.html'),'utf8'),{url:'https://reader.invalid/',runScripts:'outside-only'});
  for (const file of ['vendor/marked.umd.js','vendor/katex.min.js','reader-mermaid.js','reader.js']) dom.window.eval(fs.readFileSync(path.join(dir,file),'utf8'));
  const messages=[];
  const payload={hasMarkdown:true,markdown,html:'<p>STALE LOSSY HTML</p>',title:'文章而非说说预览',summary:'摘要 <script>只显示文字</script>',meta:'2026年11月6日',site,posts:[],resourceBase:capability,...extra};
  const result=dom.window.LBReader.render(payload,dom.window.document,m=>messages.push(m));
  return {dom,w:dom.window,doc:dom.window.document,messages,result};
}
function formulas(doc) { return Array.from(doc.querySelectorAll('.katex annotation'),n=>n.textContent.trim()); }
test('raw article Markdown wins over stale HTML; actual KaTeX DOM preserves single dollars, multiline TeX, escapes and environments',()=>{
  const md=String.raw`# Markdown标题

行内 $x_1^2 + y_2^2$ 和 $\frac{a}{b}$。

$$
\begin{aligned}
a_1 &= b_2 + c_3 \\
x &< y
\end{aligned}
$$

括号 \(E=mc^2\) 和方括号：

\[
\sum_{i=1}^n i = \frac{n(n+1)}{2}
\]

行内显示 $$a+b$$。

![图片](/assets/Note123/photo.png)
`;
  const {dom,doc,result}=setup(md);
  assert.equal(result.formulas,6);
  assert.equal(doc.querySelectorAll('.katex').length,6);
  assert.equal(doc.querySelectorAll('.katex-display').length,3);
  assert.equal(doc.querySelectorAll('.math-error').length,0);
  assert.ok(formulas(doc).includes('x_1^2 + y_2^2'));
  assert.ok(formulas(doc).some(x=>x.includes('a_1 &= b_2 + c_3') && x.includes('x &< y')));
  assert.equal(doc.querySelector('#content h1').textContent,'Markdown标题');
  assert.equal(doc.querySelector('#title').textContent,'文章而非说说预览');
  assert.equal(doc.querySelector('#meta').textContent,'2026年11月6日');
  assert.equal(doc.querySelector('#summary').textContent,'摘要 <script>只显示文字</script>');
  assert.equal(doc.querySelector('#summary').hidden,false);
  assert.equal(doc.querySelectorAll('script').length,0);
  assert.ok(!doc.querySelector('#content').textContent.includes('STALE LOSSY HTML'));
  assert.equal(doc.querySelector('img').src,capability+'assets/Note123/photo.png');
  dom.window.close();
});
test('Markdown code, fenced blocks, escaped currency and ordinary prices stay literal; malformed math remains readable',()=>{
  const {dom,doc}=setup(String.raw`价格 $20 与 $30，转义 \$x$。

代码 \`$x_1$\` 不应计算。

\`\`\`tex
$$
x_1^2
$$
\`\`\`

错误 $\badcommand{x}$，以及 $\text{<script>alert(1)</script>}$。
`.replace(/\\`/g,'`'));
  assert.equal(doc.querySelectorAll('pre .katex,code .katex').length,0);
  assert.ok(doc.querySelector('pre').textContent.includes('x_1^2'));
  assert.ok(doc.querySelector('#content').textContent.includes('$20 与 $30'));
  assert.ok(doc.querySelector('#content').textContent.includes('$x$'));
  assert.equal(doc.querySelectorAll('.math-error').length,1);
  assert.equal(doc.querySelectorAll('script').length,0);
  dom.window.close();
  const numeric=setup('数字起始 $1 + x$ 和 $2\\\\alpha$。');
  assert.equal(numeric.doc.querySelectorAll('.katex').length,2);
  numeric.dom.window.close();
});
test('canonical assets and legacy migration prefix resolve locally; audio/video/files are native attachment links',()=>{
  const {dom,doc,messages}=setup(`![图](/assets/Note123/%E5%9B%BE%20%E7%89%87.png)

![旧图](/trilium-assets/Note123/old.jpg)

[PDF](/assets/Note123/report.pdf)

[音频](/assets/Note123/sound.m4a)

<audio autoplay src="/assets/Note123/sound.m4a"></audio>
<video autoplay poster="https://evil.test/beacon"><source src="/assets/Note123/video.mp4"></video>`);
  const images=Array.from(doc.querySelectorAll('img'));
  assert.equal(images.length,2);
  assert.equal(decodeURIComponent(images[0].src),capability+'assets/Note123/图 片.png');
  assert.equal(images[1].src,capability+'assets/Note123/old.jpg');
  assert.equal(doc.querySelectorAll('audio,video,source,[autoplay],[poster]').length,0);
  const links=Array.from(doc.querySelectorAll('#content a'));
  assert.equal(links.length,4);
  for (const a of links) assert.ok(a.href.startsWith(capability+'assets/Note123/'));
  assert.equal(doc.querySelectorAll('a.local-attachment').length,2);
  images[0].click(); links[0].click(); assert.deepEqual(messages,[],'synthetic events never activate native bridge');
  dom.window.close();
});
test('article sanitization cannot forge the custom capability or read files/off-site images',()=>{
  const {dom,doc}=setup(`<script>window.pwned=true</script>
<img src="${capability}assets/Note123/private.png" onerror="alert(1)">
<img src="file:///etc/passwd">
<img src="https://evil.test/assets/Note123/beacon.png">
<img src="/assets/Note123/%2fetc%2fpasswd">
<a href="${capability}assets/Note123/private.pdf">forged capability</a>
<a href="file:///etc/passwd">file</a>
<iframe src="/assets/Note123/private.html"></iframe>
<audio src="https://evil.test/beacon.mp3"></audio>`);
  assert.equal(doc.querySelectorAll('script,iframe,audio,video').length,0);
  assert.equal(dom.window.pwned,undefined);
  for (const img of doc.querySelectorAll('img')) assert.ok(!img.src.startsWith(capability));
  for (const a of doc.querySelectorAll('#content a')) assert.equal(a.getAttribute('href'),null);
  dom.window.close();
});
test('explicit private memo still strips ALL image/media loads, ignores article capability, and clears summary',()=>{
  const {dom,doc,messages}=setup('# 说说\n\n**正常排版** $x^2$\n\n![图](/assets/Note123/p.png)\n\n![远程](https://memos.example.test/token-image)\n\n<audio src="/assets/Note123/a.m4a"></audio>',{isMemo:true,title:'',summary:'不应出现文章摘要'});
  assert.equal(doc.querySelector('#content h1').textContent,'说说');
  assert.equal(doc.querySelector('#content strong').textContent,'正常排版');
  assert.equal(doc.querySelectorAll('.katex').length,1);
  assert.equal(doc.querySelectorAll('img,audio,video,source').length,0);
  assert.ok(doc.querySelector('#content').textContent.includes('图片请在附件区预览'));
  assert.equal(doc.querySelector('#summary').hidden,true);
  assert.equal(doc.querySelector('#summary').textContent,'');
  assert.deepEqual(messages,[]);
  dom.window.close();
});
test('empty article Markdown is authoritative; legacy HTML articles still render without changing the math contract',()=>{
  const {dom,doc}=setup('');
  assert.equal(doc.querySelector('#content').textContent,'');
  dom.window.close();
  const old=setup('',{hasMarkdown:false,html:'<p>旧文价格 $20 与 $30 <span class="math-tex">$x^2$</span></p><img src="/trilium-assets/old.png">'});
  assert.equal(old.doc.querySelectorAll('.katex').length,1);
  assert.ok(old.doc.querySelector('#content').textContent.includes('$20 与 $30'));
  assert.equal(old.doc.querySelector('img').src,site+'trilium-assets/old.png');
  old.dom.window.close();
});
test('native source uses explicit memo identity, raw Markdown, scoped read-only resources and shared publish operations',()=>{
  const source=fs.readFileSync(path.join(root,'src/LBPostReader.m'),'utf8');
  const identity=source.match(/- \(BOOL\)memoPreview \{[^}]+\}/)[0];
  assert.ok(identity.includes('isPrivateMemoPreview') && identity.includes('memosGeneration'));
  assert.ok(!identity.includes('markdown'));
  assert.ok(!source.includes('removeObjectForKey:@"markdown"'));
  assert.ok(source.includes('#import "LBMarkdown.h"'));
  assert.ok(!source.includes('#import "LBTriliumClient.h"'));
  assert.ok(!source.includes('requestSyncCurrentPost'));
  assert.ok(!source.includes('putArticleFile:'));
  assert.ok(!source.includes('LBGitHub.shared'));
  assert.ok(source.includes('published ? @[ details, edit, unpub, safari ] : @[ details, edit, publish, del ]'));
  assert.ok(source.includes('deleteArticle:noteId done:'));
  for (const text of ['publishArticle:noteId done:','unpublishArticle:noteId done:','setURLSchemeHandler:_resources','URLByResolvingSymlinksInPath','NSURLIsRegularFileKey','isEqualToString:_host','initWithLocalFile:file','QLPreviewController','AVPlayer playerWithURL:file','body.count != 3','message.frameInfo.mainFrame','inContentWorld:_world']) assert.ok(source.includes(text),text);
  assert.ok(source.includes('allowingReadAccessToURL:[_entry URLByDeletingLastPathComponent]'));
  assert.ok(!source.includes('allowFileAccessFromFileURLs'));
  const html=fs.readFileSync(path.join(dir,'index.html'),'utf8');
  assert.ok(html.includes("script-src 'none'"));
  assert.ok(html.includes("connect-src 'none'"));
  assert.ok(html.includes('img-src https: data: lbreader-resource:'));
});
test('Markdown Mermaid fences enter the bounded offline diagram pipeline without math splitting or HTML injection',async()=>{
  const {dom,w,doc,messages}=setup('');
  const graphs=[];
  w.mermaid={initialize(config){assert.equal(config.securityLevel,'strict');},async render(id,source){graphs.push(source);return {svg:'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 90"><text x="2" y="30">离线图</text></svg>'};}};
  w.LBReader.render({hasMarkdown:true,markdown:'# 图示\n\n```mermaid\nflowchart TD\nA[开始] --> B[完成]\n```\n\n公式 $x_1^2$。',site,title:'图文',resourceBase:capability},doc,m=>messages.push(m));
  await w.LBReaderDiagramsComplete;
  assert.deepEqual(graphs,['flowchart TD\nA[开始] --> B[完成]\n']);
  assert.equal(doc.querySelectorAll('.mermaid-image').length,1);
  assert.equal(doc.querySelectorAll('#content svg').length,0);
  assert.equal(doc.querySelectorAll('.katex').length,1);
  assert.ok(doc.querySelector('.mermaid-image').src.startsWith('data:image/svg+xml'));
  assert.deepEqual(messages,[]);
  dom.window.close();
});
test('trusted branch forwards only sanitized local images and attachment links to native; local paths cannot be chosen by custom author scheme',()=>{
  const {dom,doc,messages}=setup('![本地图](/assets/Note123/photo.png)\n\n[文件](/assets/Note123/report.pdf)');
  const content=doc.querySelector('#content'),image=content.querySelector('img'),link=content.querySelector('a');
  const click=target=>({target,isTrusted:true,preventDefault(){}});
  content.onclick(click(image)); content.onclick(click(link));
  assert.deepEqual(messages.map(x=>({...x})),[
    {type:'image',value:capability+'assets/Note123/photo.png'},
    {type:'attachment',value:capability+'assets/Note123/report.pdf'}
  ]);
  dom.window.close();
});
