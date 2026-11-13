/* DOM/security/queue tests ONLY: real SVG measurements are in mermaid-preview.html. */
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),{JSDOM}=require('jsdom');
const dir=path.resolve(__dirname,'../resources/Reader');
const sample='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 90"><style>@keyframes dash{to{stroke-dashoffset:0;}}#a text{fill:#302b25}</style><text x="2" y="30">测试</text></svg>';
function setup(){const dom=new JSDOM(fs.readFileSync(path.join(dir,'index.html'),'utf8'),{url:'https://reader.invalid',runScripts:'outside-only'});for(const f of ['vendor/katex.min.js','reader-mermaid.js','reader.js'])dom.window.eval(fs.readFileSync(path.join(dir,f),'utf8'));return dom;}
const payload=html=>({html,title:'test',meta:'',site:'https://huowenlong.com/',posts:[]});
test('source gate rejects directives, frontmatter, callbacks, HTML, CSS, external resources and oversized diagrams',()=>{const dom=setup(),m=dom.window.LBMermaid;assert.equal(m.validate('flowchart TD\nA-->B'),'flowchart TD\nA-->B');for(const s of ['%%{init: {}}%%\nflowchart TD\nA-->B','---\nconfig: {}\n---\nflowchart TD\nA-->B','flowchart TD\nclick A call evil()','flowchart TD\nclick A "https://evil.invalid"','flowchart TD\nclassDef foo fill:red','flowchart TD\nA[<img src=x>]','flowchart TD\nA@{img: "https://x"}','flowchart TD\nA[$$x$$]','flowchart TD\n'+ 'x'.repeat(16001),'flowchart TD\n'+'A-->B\n'.repeat(121)])assert.throws(()=>m.validate(s),undefined,s);dom.window.close();});
test('SVG image reconstruction removes script, event handlers, foreignObject, links and external use; rejects unsafe CSS/entities',()=>{const dom=setup(),m=dom.window.LBMermaid,doc=dom.window.document;const malicious=sample.replace('</svg>','<script>alert(1)</script><foreignObject><div>bad</div></foreignObject><a href="https://evil.invalid"><text>link</text></a><use href="https://evil.invalid/x.svg#x"/><rect onclick="bad()" fill="url(https://evil.invalid/x)"/></svg>');const out=m.imageSVG(malicious,doc);const text=decodeURIComponent(out.url.split(',').slice(1).join(','));assert.ok(!/script|foreignObject|https:\/\/evil|onclick|@keyframes/.test(text));assert.equal(out.width,240);assert.throws(()=>m.imageSVG(sample.replace('fill:#302b25','fill:url(https://evil.invalid/x)'),doc));assert.throws(()=>m.imageSVG('<!DOCTYPE svg>'+sample,doc));assert.throws(()=>m.imageSVG(sample.replace('240 90','20001 90'),doc));dom.window.close();});
test('article ready is synchronous, rendering asynchronous, one failed graph does not stop later diagrams or source copy',async()=>{const dom=setup(),w=dom.window,doc=w.document,messages=[];let calls=0;w.mermaid={initialize(c){assert.equal(c.securityLevel,'strict');assert.equal(c.htmlLabels,false);},async render(id,s){calls++;if(s.includes('bad'))throw Error('bad');return {svg:sample};}};const html='<pre><code class="language-mermaid">flowchart TD\nA-->B</code></pre><pre><code class="language-text-x-mermaid">flowchart TD\nbad</code></pre><pre><code class="language-mermaid">flowchart LR\nC-->D</code></pre><pre><code class="language-js">plain</code></pre>';const result=w.LBReader.render(payload(html),doc,x=>messages.push(x));assert.equal(result.tables,0);assert.equal(calls,0);await w.LBReaderDiagramsComplete;assert.equal(calls,3);assert.equal(doc.querySelectorAll('.mermaid-image').length,2);assert.equal(doc.querySelectorAll('details .code-toolbar button').length,2);assert.equal(doc.querySelectorAll('.mermaid-status').length,1);assert.equal(doc.querySelectorAll('#content svg').length,0);assert.equal(doc.querySelector('.language-js').textContent,'plain');doc.querySelector('.mermaid-image').click();assert.deepEqual(messages,[]);assert.equal(doc.querySelector('.diagram-preview'),null);dom.window.close();});
test('diagram count is bounded, unsafe article data-image cannot impersonate generated image',async()=>{const dom=setup(),w=dom.window,doc=w.document;let count=0;w.mermaid={initialize(){},async render(){count++;return {svg:sample};}};w.LBReader.render(payload('<img src="data:image/svg+xml,unsafe">'+'<pre><code class="language-mermaid">flowchart TD\nA-->B</code></pre>'.repeat(14)),doc,()=>{});await w.LBReaderDiagramsComplete;assert.equal(count,12);assert.equal(doc.querySelectorAll('img').length,12);assert.equal(doc.querySelectorAll('.mermaid-status').length,2);dom.window.close();});
test('native diagram handoff is trusted-only, uses sanitized closure not mutable DOM, and never creates an overlay',async()=>{
  const dom=setup(),w=dom.window,doc=w.document,messages=[];
  w.mermaid={initialize(){},async render(){return {svg:sample};}};
  w.LBReader.render(payload('<pre><code class="language-mermaid">flowchart TD\nA-->B</code></pre>'),doc,x=>messages.push(x));
  await w.LBReaderDiagramsComplete;
  const image=doc.querySelector('.mermaid-image'),original=image.src;
  assert.deepEqual(messages,[]);
  assert.equal(image.getAttribute('role'),'button');
  image.click();image.dispatchEvent(new w.KeyboardEvent('keydown',{key:'Enter',bubbles:true}));
  image.dispatchEvent(new w.KeyboardEvent('keydown',{key:' ',bubbles:true}));
  assert.deepEqual(messages,[]);
  image.src='https://evil.invalid/replacement.svg';
  let prevented=0,stopped=0;
  // Unit-call trusted branch; jsdom cannot manufacture browser trusted gestures.
  const trusted={isTrusted:true,preventDefault(){prevented++;},stopPropagation(){stopped++;}};
  image.onclick(trusted);image.onkeydown({...trusted,key:'Enter'});image.onkeydown({...trusted,key:' '});
  image.onkeydown({...trusted,key:'Escape'});
  assert.equal(messages.length,3);assert.equal(prevented,3);assert.equal(stopped,3);
  for(const event of messages){assert.equal(event.type,'diagram');assert.equal(event.value,original);assert.deepEqual(Object.keys(event).sort(),['type','value']);}
  assert.equal(doc.querySelector('.diagram-preview'),null);
  const source=fs.readFileSync(path.join(dir,'reader-mermaid.js'),'utf8');
  assert.equal(source.includes('Math.max(800'),false);
  assert.equal(fs.readFileSync(path.join(dir,'reader.css'),'utf8').includes('.diagram-preview{'),false);
  dom.window.close();
});
test('bundled engine is pinned standalone IIFE with no dynamic imports; page scripts remain disabled',()=>{const js=fs.readFileSync(path.join(dir,'vendor/mermaid.min.js'),'utf8');assert.equal(js.length>5000000,true);assert.equal(/\bimport\(/.test(js),false);const template=fs.readFileSync(path.join(dir,'index.html'),'utf8');assert.ok(template.includes("script-src 'none'"));assert.ok(template.includes('img-src https: data:'));});
