const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require('jsdom');
const root=path.resolve(__dirname,'../resources/Reader');
function fixture(){
 const dom=new JSDOM(fs.readFileSync(path.join(root,'memo-detail.html'),'utf8'),{runScripts:'outside-only',url:'https://memo.invalid/'});
 const {window:w}=dom; const events=[],frames=[];
 w.requestAnimationFrame=cb=>{frames.push(cb);return frames.length;};
 let height=80;
 w.document.getElementById('reader').getBoundingClientRect=()=>({height});
 for(const file of ['vendor/marked.umd.js','vendor/katex.min.js','reader.js','memo-detail.js'])w.eval(fs.readFileSync(path.join(root,file),'utf8'));
 const api=w.LBMemoDetail.install(w.document,e=>events.push(e));
 return {dom,w,api,events,height:n=>height=n,flush:()=>{while(frames.length)frames.shift()();},render:(markdown,revision=1)=>api.render({markdown,site:'https://memo.invalid/',posts:[]},revision)};
}
test('same document renders sanitized Markdown, math, tables and code; never authored media',()=>{
 const f=fixture();
 f.render('# 正文\n\n**粗体**\n\n$$x^2$$\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```js\nconst x=1\n```\n\n![秘密](https://private.test/api/v1/resource/1/file)\n\n<img src="https://evil.test/pixel" onerror="alert(1)"><iframe src="https://evil.test"></iframe><script>window.hacked=1</script>');
 const c=f.w.document.getElementById('content');
 assert.equal(c.querySelector('h1').textContent,'正文');
 assert.equal(c.querySelector('strong').textContent,'粗体');
 assert.equal(c.querySelectorAll('.katex').length,1);
 assert.equal(c.querySelectorAll('.table-scroll table').length,1);
 assert.equal(c.querySelectorAll('.code-block code').length,1);
 assert.equal(c.querySelectorAll('script,img,iframe,svg,video,audio,[onerror]').length,0);
 assert.equal(f.w.hacked,undefined);
 f.flush();assert.equal(f.events.at(-1).type,'height');f.dom.window.close();
});
test('measurement can shrink after width change and clamps excessive content',()=>{
 const f=fixture();f.render('hello'); f.flush();
 assert.equal(f.events.at(-1).value,80);
 f.height(30);f.api.measure();assert.equal(f.events.at(-1).value,30);
 f.height(200000);f.api.measure();assert.equal(f.events.at(-1).value,120000);
 f.height(NaN);f.api.measure();assert.equal(f.events.at(-1).value,1);
 f.dom.window.close();
});
test('reset wipes DOM immediately and older render cannot repopulate it',()=>{
 const f=fixture();f.render('private **memo**',10);f.flush();
 f.api.clear(11);assert.equal(f.w.document.getElementById('content').textContent,'');
 assert.equal(f.render('stale',10),false);
 f.height(100);const count=f.events.length;f.api.measure();assert.equal(f.events.length,count);
 assert.equal(f.render('new',12),true);f.flush();assert.equal(f.events.at(-1).revision,12);
 f.dom.window.close();
});
test('diagrams completion and font/layout observers request trusted remeasurement',async()=>{
 const f=fixture();let resolve;
 f.w.LBMermaid={install:()=>({complete:new Promise(r=>resolve=r)})};
 f.render('```mermaid\ngraph TD; A-->B\n```');f.flush();
 f.height(280);resolve();await Promise.resolve();await Promise.resolve();f.flush();
 assert.equal(f.events.at(-1).value,280);f.dom.window.close();
});
test('empty memo provides attachment-only text and CSP has no network permission',()=>{
 const f=fixture();f.render('');
 assert.match(f.w.document.getElementById('content').textContent,/仅附件说说/);
 const csp=f.w.document.querySelector('meta[http-equiv="Content-Security-Policy"]').content;
 assert.match(csp,/img-src data:/);assert.match(csp,/connect-src 'none'/);assert.match(csp,/script-src 'none'/);
 assert.doesNotMatch(csp,/https:/);f.dom.window.close();
});
