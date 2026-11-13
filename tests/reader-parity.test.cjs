/* NODE_PATH=/root/longblog-jsdom/node_modules node -e "require('./ios/LongBlogInbox/tests/reader-parity.test.cjs')"
 * Optional read-only real-note verification: LB_READER_REAL_NOTES=/var/minis/mounts/notes
 * Never prints note text, titles, attributes, URL values or credentials.
 */
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process');
const {JSDOM}=require('jsdom');
const root=path.resolve(__dirname,'..'),repo=path.resolve(root,'../..'),dir=path.join(root,'resources/Reader');
const fixture=name=>fs.readFileSync(path.join(__dirname,'fixtures/reader-parity',name),'utf8');
const site='https://blog.example.test/',capability='lbreader-resource://12345678-abcd-1234-abcd-123456789012/';
function setup(extra={},prepare){
 const dom=new JSDOM(fs.readFileSync(path.join(dir,'index.html'),'utf8'),{url:'https://reader.invalid/',runScripts:'outside-only',pretendToBeVisual:true});
 const w=dom.window,doc=w.document,messages=[];
 for(const file of ['vendor/marked.umd.js','vendor/katex.min.js','vendor/site-highlight.js','reader-mermaid.js','reader.js'])w.eval(fs.readFileSync(path.join(dir,file),'utf8'));
 if(prepare)prepare(w,doc);
 const payload={title:'合成测试文章',meta:'创建：2026年11月01日 12:34:56\n更新：2026年11月07日 01:23:45',site,resourceBase:capability,noteID:'FixtureNote',hasMarkdown:true,markdown:'# 新的正文',html:'',...extra};
 const result=w.LBReader.render(payload,doc,m=>messages.push(m));
 return{dom,w,doc,messages,payload,result};
}
function diagramStub(w,sources){w.mermaid={initialize(config){assert.equal(config.securityLevel,'strict');assert.equal(config.htmlLabels,false);},async render(id,source){sources.push(source);return {svg:'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 90"><text x="2" y="30">合成图表</text></svg>'};}};}
for(const [name,tables,cells,pre,headings]of [['migration-tables',4,36,11,19],['migration-mermaid',4,60,8,22]]){
 test(`structurally anonymized ${name}: canonical HTML body in .md retains tables, prose boundaries and exact code`,async()=>{
  const html=fixture(name+'.html'),markdown=fixture(name+'.md'),original=new JSDOM(html).window.document,sources=[];
  const {dom,w,doc,result}=setup({html:'<p>stale sidecar</p>',markdown:html,bodyFormat:'html'},w=>diagramStub(w,sources));
  assert.equal(result.tables,tables);assert.equal(doc.querySelectorAll('td,th').length,cells);assert.equal(doc.querySelectorAll('pre').length,pre);assert.equal(doc.querySelectorAll('#content h1,#content h2,#content h3,#content h4').length,headings);
  assert.equal(doc.querySelectorAll('.table-scroll > table').length,tables);
  assert.deepEqual(Array.from(doc.querySelectorAll('pre code'),e=>e.textContent),Array.from(original.querySelectorAll('pre code'),e=>e.textContent));
  assert.equal(doc.querySelectorAll('pre table,pre h2,pre p').length,0);
  await w.LBReaderDiagramsComplete;
  assert.equal(doc.querySelectorAll('.mermaid-image').length,name==='migration-mermaid'?1:0);
  assert.equal(doc.querySelectorAll('#content svg,script,iframe,audio,video').length,0);
  if(sources.length){assert.equal(sources[0],'flowchart TD\n A[开始] --> B[结束]\n');assert.equal(doc.querySelector('details').open,false);}
  const lossy=setup({markdown,html,hasHTMLSidecar:false});assert.equal(lossy.doc.querySelectorAll('table').length,0,'legacy Markdown has already lost table semantics');
  lossy.dom.window.close();dom.window.close();
 });
}
test('body-edited and empty Markdown stay authoritative despite legacy sidecar flags; explicit HTML preview uses its own body',()=>{
 const html='<figure class="table"><table><tr><td>保真侧件</td></tr></table></figure>';
 for(const extra of [{hasHTMLSidecar:false},{hasHTMLSidecar:true,isEditorPreview:true}]){
  const {dom,doc}=setup({html,markdown:'# 已经修改',...extra});assert.equal(doc.querySelector('#content h1').textContent,'已经修改');assert.equal(doc.querySelectorAll('table').length,0);dom.window.close();
 }
 const unchanged=setup({html:'<p>stale sidecar</p>',markdown:html,bodyFormat:'html',hasSidecarHtml:true,isEditorPreview:true});assert.equal(unchanged.doc.querySelectorAll('table').length,1);unchanged.dom.window.close();
 const empty=setup({html,markdown:'',hasHTMLSidecar:false});assert.equal(empty.doc.querySelector('#content').textContent,'');empty.dom.window.close();
});
test('rich site semantics survive only explicit safe classes/attributes; author styles and bridge controls do not',()=>{
 const html='<aside class="admonition warning evil" onclick="alert(1)"><p>提示</p></aside><details open class="trilium-collapsible"><summary>折叠</summary><p>内容</p></details><figure class="image image_resized image-style-side" style="width:40%;position:fixed"><img src="/assets/FixtureNote/a.png" onload="alert(1)"></figure><table><tr><th scope="col" colspan="2">列</th><td align="right" style="background:url(https://evil.test)">右</td></tr></table><script>window.pwned=true</script><button data-post="Fake">伪造</button>';
 const {dom,w,doc}=setup({markdown:html,bodyFormat:'html'});
 assert.equal(doc.querySelector('aside').className,'admonition warning');assert.equal(doc.querySelector('details').open,true);assert.equal(doc.querySelector('figure').style.width,'40%');assert.equal(doc.querySelector('figure').style.position,'');assert.equal(doc.querySelector('td').style.textAlign,'right');assert.equal(doc.querySelector('th').getAttribute('colspan'),'2');assert.equal(doc.querySelector('th').getAttribute('scope'),'col');assert.equal(doc.querySelectorAll('[onclick],[onload],script,[data-post]').length,0);assert.equal(w.pwned,undefined);dom.window.close();
});
test('canonical and per-article relative assets use the same capability while memo never sees article assets or CSS',()=>{
 const {dom,doc}=setup({markdown:'![图](./assets/photo.png)\n\n[PDF](assets/report.pdf)\n\n![图](/assets/FixtureNote/photo.png)'});
 assert.equal(doc.querySelector('img').src,capability+'assets/FixtureNote/photo.png');assert.equal(doc.querySelector('a').href,capability+'assets/FixtureNote/report.pdf');assert.equal(doc.querySelector('#legacy-reader-style').media,'not all');assert.equal(doc.documentElement.classList.contains('lb-article-reader'),true);dom.window.close();
 const memo=setup({isMemo:true,hasHTMLSidecar:true,hasSidecarHtml:true,html:'<p>PRIVATE WRONG SIDE</p>',markdown:'## 私密预览\n\n![图](./assets/a.png)'});
 assert.equal(memo.doc.querySelector('h2').textContent,'私密预览');assert.equal(memo.doc.querySelectorAll('img').length,0);assert.equal(memo.doc.documentElement.classList.contains('lb-article-reader'),false);assert.equal(memo.doc.querySelector('#legacy-reader-style').media,'all');memo.dom.window.close();
});
test('site highlight.js MIME aliases preserve exact source and token classes; auto and Mermaid remain literal',()=>{
 const source='key: "hello"\nlist:\n  - one\n';
 const {dom,doc}=setup({markdown:'<pre><code class="language-text-x-yaml">'+source+'</code></pre><pre><code class="language-text-x-trilium-auto">if x\n  sample</code></pre><pre><code class="language-bash">echo x</code></pre>',bodyFormat:'html'});
 const blocks=doc.querySelectorAll('pre');assert.equal(blocks[0].textContent,source);assert.ok(blocks[0].querySelector('.hljs-attr'));assert.equal(blocks[1].querySelector('[class^="hljs-"]'),null);assert.equal(blocks[2].querySelector('[class^="hljs-"]'),null);
 dom.window.close();
});
test('initial render, deferred diagrams/images and font layout start at top; trusted interaction permanently cancels initial resets',async()=>{
 let frames=[],resets=[],listeners={};
 const {dom,w,doc}=setup({markdown:'<p>正文</p><img src="/assets/FixtureNote/a.png">',bodyFormat:'html'},(w,doc)=>{
  Object.defineProperty(doc,'scrollingElement',{value:doc.documentElement,configurable:true});doc.documentElement.scrollTop=700;doc.body.scrollTop=500;
  w.scrollTo=options=>resets.push(options.top);w.requestAnimationFrame=fn=>{frames.push(fn);return frames.length;};
  const add=doc.addEventListener.bind(doc);doc.addEventListener=(type,fn,opts)=>{if(['touchstart','pointerdown','wheel','keydown'].includes(type))listeners[type]=fn;return add(type,fn,opts);};
 });
 assert.equal(doc.documentElement.scrollTop,0);assert.equal(doc.body.scrollTop,0);assert.ok(resets.length>0);
 doc.documentElement.scrollTop=250;doc.querySelector('img').dispatchEvent(new w.Event('load'));for(const frame of frames.splice(0))frame();assert.equal(doc.documentElement.scrollTop,0);
 listeners.touchstart({isTrusted:true});doc.documentElement.scrollTop=321;const count=resets.length;
 doc.querySelector('img').dispatchEvent(new w.Event('load'));await w.LBReaderDiagramsComplete;for(const frame of frames.splice(0))frame();assert.equal(doc.documentElement.scrollTop,321);assert.equal(resets.length,count);
 dom.window.close();
});
test('website CSS is reproducibly extracted with exact declarations and all bundled fonts remain local',()=>{
 if(process.env.LONGBLOG_SITE_ROOT){
  cp.execFileSync('python3',[path.join(root,'tools/extract_reader_site_css.py'),'--check']);
 }
 const css=fs.readFileSync(path.join(dir,'site-article.css'),'utf8');
 for(const token of ['--leading-reading: 1.95','--font-sans: "LXGW WenKai Screen"','#content.site-content figure.table','white-space: pre','line-break: auto','--hl-keyword: #a626a4','details.trilium-collapsible','admonition.warning','@media (max-width: 640px)'])assert.ok(css.includes(token),token);
 assert.equal(css.includes('.post-sidebar'),false);assert.equal(css.includes('.mobile-toc'),false);
 const fontCSS=fs.readFileSync(path.join(dir,'vendor/site-fonts.css'),'utf8');let refs=0;
 for(const match of fontCSS.matchAll(/url\("([^"]+)"\)/g)){assert.ok(!/^(?:https?:|\/)/.test(match[1]));assert.ok(fs.existsSync(path.join(dir,'vendor',match[1])));refs++;}assert.ok(refs>100);
 const engine=fs.readFileSync(path.join(dir,'vendor/site-highlight.js'),'utf8');assert.ok(engine.includes('11.12.0'));assert.equal(/import\s*\(/.test(engine.replace(/\/\*[\s\S]*?\*\//g,'')),false);
});
test('native source keeps root-scoped read-only store mapping, full dates, isolated world and native top inset',()=>{
 const native=fs.readFileSync(path.join(root,'src/LBPostReader.m'),'utf8');
 for(const text of ['resourceURLForLocalPath:encoded','activeRoot.path isEqualToString:_rootURL.path','NSURLIsRegularFileKey','URLByResolvingSymlinksInPath','@"bodyFormat"','showArticleDetails','yyyy年MM月dd日 HH:mm:ss','@"创建"','更新：','adjustedContentInset','CGPointMake(-inset.left, -inset.top)','inContentWorld:_world','body.count != 3','message.frameInfo.mainFrame'])assert.ok(native.includes(text),text);
 assert.equal(native.includes('LBDateText('),false);const resourceClass=native.slice(native.indexOf('@implementation LBReaderResources'),native.indexOf('#pragma mark - Bounded native image preview'));assert.equal(resourceClass.includes('createDirectory'),false);assert.equal(resourceClass.includes('assetsFolderForNote:'),false);
});
test('valid Markdown GFM tables and closed fences keep following prose out of code',()=>{
 const markdown='# 新文章\n\n| 项目 | 结果 |\n|:---|---:|\n| 表格 | 保留 |\n\n```yaml\nkey: value\n```\n\n代码块后的正常正文。\n\n```mermaid\nflowchart TD\n A --> B\n```\n\n流程图后仍然是正文。';
 const {dom,doc}=setup({markdown,isEditorPreview:true});
 assert.equal(doc.querySelectorAll('table').length,1);assert.equal(doc.querySelectorAll('pre').length,2);assert.equal(doc.querySelector('pre code').textContent,'key: value\n');
 for(const text of ['代码块后的正常正文。','流程图后仍然是正文。']){const p=Array.from(doc.querySelectorAll('#content p')).find(e=>e.textContent===text);assert.ok(p);assert.equal(p.closest('pre,code'),null);}
 dom.window.close();
});
if(process.env.LB_READER_REAL_NOTES){
 test('opt-in read-only real-note DOM: complete sidecars retain all tables/code/headings and one offline Mermaid',async()=>{
  const folder=process.env.LB_READER_REAL_NOTES;
  for(const [id,tableCount,codeCount,headingCount]of [['cyZ6AgNjauV8',4,11,19],['xtusIYhPQyK5',4,8,22]]){
   const html=fs.readFileSync(path.join(folder,id+'.html'),'utf8'),raw=fs.readFileSync(path.join(folder,id+'.md'),'utf8'),markdown=raw.replace(/^---\r?\n[\s\S]*?\r?\n---(?:\r?\n|$)/,'');
   const original=new JSDOM(html),sources=[];
   const {dom,w,doc}=setup({noteID:id,hasMarkdown:false,html,markdown,hasHTMLSidecar:true},w=>diagramStub(w,sources));
   // Do not put original strings in assertion errors/logs: counts and equality
   // booleans are sufficient, even if real code contains passwords or tokens.
   assert.equal(doc.querySelectorAll('table').length,tableCount);assert.equal(doc.querySelectorAll('pre code').length,codeCount);assert.equal(doc.querySelectorAll('#content h1,#content h2,#content h3,#content h4').length,headingCount);
   const before=Array.from(original.window.document.querySelectorAll('pre code'),n=>n.textContent),after=Array.from(doc.querySelectorAll('pre code'),n=>n.textContent);
   assert.equal(before.length,after.length);assert.ok(before.every((s,i)=>s===after[i]),'all code bytes retained');
   await w.LBReaderDiagramsComplete;
   assert.equal(doc.querySelectorAll('.mermaid-image').length,id==='xtusIYhPQyK5'?1:0);assert.equal(doc.querySelectorAll('script,iframe,object,#content svg').length,0);
   original.window.close();dom.window.close();
  }
 });
}
test('dark diagram uses site muted-foreground ink rather than muted surface for readable arrows',async()=>{
 let config;
 const {dom,w}=setup({markdown:'```mermaid\nflowchart TD\n A --> B\n```'},(w,doc)=>{
  w.matchMedia=()=>({matches:true,addEventListener(){}});
  for(const [key,value]of Object.entries({'--surface':'#2b2823','--code':'#35312b','--muted':'#35312b','--foreground':'#e8e0d4','--muted-foreground':'#bcb2a2','--border':'#494238'}))doc.documentElement.style.setProperty(key,value);
  w.mermaid={initialize(value){config=value;},async render(){return{svg:'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 80"><text>合成</text></svg>'};}};
 });
 await w.LBReaderDiagramsComplete;assert.equal(config.themeVariables.darkMode,true);assert.equal(config.themeVariables.lineColor,'#bcb2a2');assert.equal(config.themeVariables.primaryTextColor,'#e8e0d4');assert.notEqual(config.themeVariables.lineColor,config.themeVariables.primaryColor);assert.equal(config.securityLevel,'strict');assert.equal(config.htmlLabels,false);dom.window.close();
});
