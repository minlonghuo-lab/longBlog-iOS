/* NODE_PATH=/root/longblog-jsdom/node_modules node -e "require('./ios/LongBlogInbox/tests/reader-initial-details.test.cjs')"
 * All fixtures are synthetic. This is DOM/source-contract coverage, NOT a UIKit runtime test.
 */
const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),{JSDOM}=require('jsdom');
const root=path.resolve(__dirname,'..'),dir=path.join(root,'resources/Reader');
function setup(extra={},prepare){
 const dom=new JSDOM(fs.readFileSync(path.join(dir,'index.html'),'utf8'),{url:'https://reader.invalid/',runScripts:'outside-only'});
 const w=dom.window,doc=w.document,messages=[];
 for(const file of ['vendor/marked.umd.js','vendor/katex.min.js','reader-mermaid.js','reader.js'])w.eval(fs.readFileSync(path.join(dir,file),'utf8'));
 if(prepare)prepare(w,doc);
 const result=w.LBReader.render({site:'https://blog.example.test/',title:'合成公开测试',hasMarkdown:true,markdown:'',...extra},doc,m=>messages.push({...m}));
 return{dom,w,doc,messages,result};
}
const formulas=doc=>Array.from(doc.querySelectorAll('.katex annotation'),n=>n.textContent);
test('HTML-mode canonical body keeps blank lines/tables/TeX and strips active content without needing sidecars',async()=>{
 const html=String.raw`<h2 id="heading">复杂结构</h2><div><p>第一段

公式 $x_1^2 + \\alpha$ 与 $\frac{a}{b}$。</p><table><tr><td colspan="2">$z_2$</td></tr></table>
<pre><code class="language-latex">$literal_1$ &lt;script&gt;
$$
x_2
$$</code></pre><p>价格 $20 与 $30；转义 \$literal$；数字 $1 + x$。</p>
<p>显示：$$\begin{aligned}a&=b\\c&=d\end{aligned}$$</p>
<script>window.pwned=true</script><iframe src="https://evil.test"></iframe><img src="https://evil.test/a" onerror="alert(1)"><a href="javascript:alert(1)">危险</a></div>`;
 const before=new JSDOM(html),{dom,w,doc}=setup({bodyFormat:'html',markdown:html,html:'<p>STALE</p>',hasHTMLSidecar:true});
 assert.equal(doc.querySelectorAll('table').length,1);assert.equal(doc.querySelector('td').colSpan,2);
 assert.equal(doc.querySelector('pre code').textContent,before.window.document.querySelector('pre code').textContent);
 assert.equal(doc.querySelectorAll('pre .katex,code .katex').length,0);
 assert.equal(doc.querySelectorAll('.katex').length,5);assert.equal(doc.querySelectorAll('.katex-display').length,1);
 assert.ok(formulas(doc).includes('\\frac{a}{b}'));assert.ok(formulas(doc).includes('1 + x'));
 assert.equal(doc.querySelectorAll('script,iframe,[onerror],[href^="javascript:"]').length,0);assert.equal(w.pwned,undefined);
 assert.ok(doc.querySelector('#content').textContent.includes('$20 与 $30'));assert.ok(!doc.querySelector('#content').textContent.includes('STALE'));
 dom.window.close();before.window.close();
});
test('Markdown raw HTML math shares KaTeX pipeline; escaped dollars/code/mermaid stay literal',()=>{
 const {dom,doc}=setup({markdown:String.raw`<div><p>HTML里的 $x_1$ 和 \(a_2\)。</p></div>

普通 $y_3$、转义 \$not_math$。

\`$inline$\`

\`\`\`tex
$block$
\`\`\`

<div class="mermaid">flowchart TD
 A["$not_math$"] --> B</div>`.replace(/\\`/g,'`')});
 assert.deepEqual(formulas(doc),['x_1','a_2','y_3']);
 assert.equal(doc.querySelectorAll('pre .katex,code .katex,.mermaid .katex').length,0);
 assert.ok(doc.querySelector('#content').textContent.includes('$not_math$'));dom.window.close();
});
test('existing Markdown always wins, including empty body, regardless of all legacy sidecar flags',()=>{
 for(const markdown of ['', '# 新正文']){
  const {dom,doc}=setup({markdown,html:'<table><tr><td>STALE</td></tr></table>',hasHTMLSidecar:true,hasSidecarHtml:true});
  assert.equal(doc.querySelectorAll('table').length,0);assert.equal(doc.querySelector('#content').textContent.includes('STALE'),false);dom.window.close();
 }
 const {dom,doc}=setup({hasMarkdown:false,html:'<p>旧载荷 $x_1$。</p>'});assert.deepEqual(formulas(doc),['x_1']);dom.window.close();
});
test('top session awaits slow fonts and Mermaid beyond former 1.5s boundary, reports generation once, and then stops',async()=>{
 let frames=[],fontReady,diagramReady,listeners={},timers=[];
 const {dom,w,doc,messages}=setup({markdown:'正文',initialTopGeneration:'17'},(w,doc)=>{
  Object.defineProperty(doc,'scrollingElement',{value:doc.documentElement});
  Object.defineProperty(doc,'fonts',{value:{ready:new Promise(resolve=>fontReady=resolve)}});
  w.LBMermaid={install:()=>({complete:new Promise(resolve=>diagramReady=resolve)})};
  w.scrollTo=()=>{};w.requestAnimationFrame=fn=>frames.push(fn);
  w.setTimeout=(fn,ms)=>{timers.push({fn,ms});return timers.length;};w.clearTimeout=()=>{};
  const add=doc.addEventListener.bind(doc);doc.addEventListener=(type,fn,opts)=>{listeners[type]=fn;return add(type,fn,opts);};
 });
 const flush=()=>{for(let i=0;i<5&&frames.length;i++)for(const fn of frames.splice(0))fn();};
 assert.equal(timers.some(t=>t.ms===1500),false);assert.ok(timers.some(t=>t.ms===10000));
 flush();doc.documentElement.scrollTop=500;listeners.load({target:{localName:'img'}});flush();assert.equal(doc.documentElement.scrollTop,0);
 fontReady();await Promise.resolve();flush();assert.equal(messages.length,0);
 diagramReady();await w.LBReaderDiagramsComplete;await Promise.resolve();await Promise.resolve();flush();await w.LBReaderInitialTopComplete;
 assert.deepEqual(messages,[{type:'initial-top-settled',value:'17'}]);
 doc.documentElement.scrollTop=400;listeners.load({target:{localName:'img'}});flush();assert.equal(doc.documentElement.scrollTop,400);dom.window.close();
});
test('native cancellation and DOM trusted input permanently revoke queued reset capability',async()=>{
 for(const native of [false,true]){
  let frames=[],listeners={},ready;
  const {dom,w,doc,messages}=setup({markdown:'正文',initialTopGeneration:'18'},(w,doc)=>{
   Object.defineProperty(doc,'scrollingElement',{value:doc.documentElement});Object.defineProperty(doc,'fonts',{value:{ready:new Promise(resolve=>ready=resolve)}});
   w.scrollTo=()=>{};w.requestAnimationFrame=fn=>frames.push(fn);
   const add=doc.addEventListener.bind(doc);doc.addEventListener=(type,fn,opts)=>{listeners[type]=fn;return add(type,fn,opts);};
  });
  if(native)w.LBReaderStopInitialTop();else listeners.touchstart({isTrusted:true});
  doc.documentElement.scrollTop=333;ready();await Promise.resolve();await Promise.resolve();for(const fn of frames)fn();await w.LBReaderInitialTopComplete;
  assert.equal(doc.documentElement.scrollTop,333);assert.deepEqual(messages,native?[]:[{type:'initial-top-interacted',value:'18'}]);dom.window.close();
 }
 const cancelled=setup({initialTopCancelled:true,initialTopGeneration:'19'},(w,doc)=>{doc.documentElement.scrollTop=250;});
 assert.equal(cancelled.doc.documentElement.scrollTop,250);cancelled.dom.window.close();
});
test('native article excludes automatic inset, preserves memo chrome, and details retain all three exact dates',()=>{
 const source=fs.readFileSync(path.join(root,'src/LBPostReader.m'),'utf8');
 for(const text of ['UIScrollViewContentInsetAdjustmentNever','self.view.safeAreaLayoutGuide.topAnchor','viewDidLayoutSubviews','_initialTopPending','LBReaderTouchObserver','touchesBegan:','initial-top-interacted','initial-top-settled','_initialTopCompletionGeneration','showArticleDetails','@"bodyFormat"','@"下架文章"','yyyy年MM月dd日 HH:mm:ss','@"createdAtString"','@"publishedAtString"','@"updatedAtString"','@"详情"','@"未记录"','时区：'])assert.ok(source.includes(text),text);
 assert.equal(source.includes('从博客撤下'),false);assert.equal(source.includes('self.navigationItem.title = refreshed'),false);
 const title=source.match(/self.navigationItem.title = \[self memoPreview\][^;]+;/)[0];assert.ok(title.includes('说说预览'));assert.ok(title.endsWith(': @"";'));
 assert.ok(!source.includes('@"hasHTMLSidecar":'));assert.ok(!source.includes('@"hasSidecarHtml":'));
});
test('display math spans HTML paragraphs/br/inline spans without crossing code or destroying surrounding prose',()=>{
 const html=String.raw`<p>前文。</p><p>$$</p><p>\begin{aligned}a_1&amp;=b_2\\</p><p>c_3&amp;=d_4\end{aligned}</p><p>$$</p><p>后文。</p>
<p>\[</p><p>\frac{a}{b}<br>+ c</p><p>\]</p>
<p>$$x_<span>1</span> + y_2$$ 后缀。</p>
<p>$$不能跨代码</p><pre><code>$literal$</code></pre><p>另一端$$</p>`;
 const {dom,doc}=setup({bodyFormat:'html',markdown:html});
 assert.equal(doc.querySelectorAll('.katex').length,3);assert.equal(doc.querySelectorAll('.katex-display').length,3);
 assert.equal(doc.querySelectorAll('.math-error').length,0);
 const all=formulas(doc);assert.ok(all[0].includes('a_1&=b_2\\\\'));assert.ok(all[0].includes('c_3&=d_4'));assert.ok(all[1].includes('\\frac{a}{b}\n+ c'));assert.ok(all[2].includes('x_1 + y_2'));
 assert.ok(doc.querySelector('#content').textContent.includes('前文。'));assert.ok(doc.querySelector('#content').textContent.includes('后文。'));assert.ok(doc.querySelector('#content').textContent.includes('后缀。'));
 assert.equal(doc.querySelector('pre code').textContent,'$literal$');assert.equal(doc.querySelectorAll('pre .katex,code .katex').length,0);dom.window.close();
});
