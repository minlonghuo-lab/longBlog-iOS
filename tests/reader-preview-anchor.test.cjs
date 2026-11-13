/* Editor preview caret anchor. Run without workers on iSH:
 * NODE_PATH=/root/longblog-jsdom/node_modules node -e "require('./ios/LongBlogInbox/tests/reader-preview-anchor.test.cjs')"
 */
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {JSDOM} = require('jsdom');
const dir = path.join(path.resolve(__dirname,'..'),'resources/Reader');
const site = 'https://blog.example.test/';
function setup(markdown, extra = {}) {
  const dom = new JSDOM(fs.readFileSync(path.join(dir,'index.html'),'utf8'),{url:'https://reader.invalid/',runScripts:'outside-only',pretendToBeVisual:true});
  for (const file of ['vendor/marked.umd.js','vendor/katex.min.js','reader-mermaid.js','reader.js']) dom.window.eval(fs.readFileSync(path.join(dir,file),'utf8'));
  const payload = {hasMarkdown:true,markdown,html:'',title:'预览',summary:'',meta:'',site,posts:[],resourceBase:'',...extra};
  const result = dom.window.LBReader.render(payload,dom.window.document,()=>{});
  return {dom,doc:dom.window.document,result};
}
const marker = 'LBCARET1A2B3C4D';
// Same shape the native editor produces: a marker paragraph before the caret's block.
const md = `# 第一节\n\n前文段落 $a+b$。\n\n${marker}\n\n## 第二节\n\n$$\nx^2\n$$\n\n| a | b |\n|---|---|\n| 1 | 2 |\n`;

test('marker paragraph becomes an invisible anchor right before the caret block', () => {
  const {dom,doc,result} = setup(md,{isEditorPreview:true,previewAnchor:marker});
  const content = doc.getElementById('content');
  assert.ok(!content.textContent.includes(marker));
  const anchor = content.querySelector('.reader-preview-anchor');
  assert.ok(anchor, 'anchor element exists');
  assert.equal(anchor.localName,'div');
  assert.equal(anchor.nextElementSibling.localName,'h2');
  assert.equal(anchor.nextElementSibling.textContent,'第二节');
  assert.equal(result.formulas,2);
  assert.equal(content.querySelectorAll('table').length,1);
  dom.window.close();
});

test('marker text is left alone outside editor preview or when malformed', () => {
  let {dom,doc} = setup(md,{isEditorPreview:false,previewAnchor:marker});
  assert.ok(doc.getElementById('content').textContent.includes(marker));
  assert.equal(doc.querySelector('.reader-preview-anchor'),null);
  dom.window.close();
  ({dom,doc} = setup(md,{isEditorPreview:true,previewAnchor:'<img src=x>'}));
  assert.equal(doc.querySelector('.reader-preview-anchor'),null);
  dom.window.close();
});

test('marker inside a paragraph keeps the surrounding text', () => {
  const {dom,doc} = setup(`前半${marker}后半`,{isEditorPreview:true,previewAnchor:marker});
  const p = doc.querySelector('#content p');
  assert.equal(p.textContent,'前半后半');
  assert.equal(p.querySelector('span.reader-preview-anchor') !== null,true);
  dom.window.close();
});
