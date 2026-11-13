/* DOM execution of production reader.js. Offline; no device/FPS claims. */
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {JSDOM} = require('jsdom');
const dir = path.resolve(__dirname, '../resources/Reader');
const capability = 'lbreader-resource://12345678-abcd-1234-abcd-123456789012/';
function render(markdown, extra={}) {
  const dom = new JSDOM(fs.readFileSync(path.join(dir, 'index.html'), 'utf8'), {url:'https://reader.invalid/', runScripts:'outside-only'});
  for (const file of ['vendor/marked.umd.js', 'vendor/katex.min.js', 'reader-mermaid.js', 'reader.js']) dom.window.eval(fs.readFileSync(path.join(dir,file),'utf8'));
  dom.window.LBReader.render({hasMarkdown:true, markdown, site:'https://blog.example.test/', resourceBase:capability, ...extra}, dom.window.document, ()=>{});
  return dom;
}
test('H2 H3 H4 map to semantic headings; single-line and nested code stay fenced', ()=> {
  const dom=render('## 二级\n\n### 三级\n\n#### 四级\n\n```\none line\n```\n\n````\n```js\nconst x=1;\n```\n````');
  const doc=dom.window.document;
  assert.deepEqual(Array.from(doc.querySelectorAll('#content h2,h3,h4'), n=>n.localName), ['h2','h3','h4']);
  assert.equal(doc.querySelectorAll('pre code').length,2);
  assert.match(doc.querySelectorAll('pre code')[1].textContent,/```js/);
  dom.window.close();
});
test('third-party direct and source media are removed, including nested fallback', ()=> {
  const dom=render('<audio src="https://evil.test/a.mp3"></audio><video><source src="https://evil.test/v.mp4"></video><source src="https://evil.test/s.mp3">');
  assert.equal(dom.window.document.querySelectorAll('audio,video,source').length,0);
  dom.window.close();
});
test('private memo site-style preview cannot emit media fetch nodes', ()=> {
  const dom=render('<audio src="/assets/Note1/a.mp3"></audio><video src="https://blog.example.test/v.mp4"></video><source src="https://evil.test/s.mp3">', {isMemo:true,memoSiteStyle:true});
  assert.equal(dom.window.document.querySelectorAll('audio,video,source').length,0);
  dom.window.close();
});
test('local article capability and same-origin playback remain available without autoplay', ()=> {
  const dom=render('<audio autoplay src="/assets/Note1/a.mp3"></audio><video autoplay><source src="https://blog.example.test/v.mp4"></video>');
  const doc=dom.window.document;
  assert.equal(doc.querySelector('audio').src,capability+'assets/Note1/a.mp3');
  assert.equal(doc.querySelector('video').src,'https://blog.example.test/v.mp4');
  assert.equal(doc.querySelectorAll('[autoplay],source').length,0);
  dom.window.close();
});
