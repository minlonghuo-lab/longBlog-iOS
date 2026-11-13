/* Browser-only fixture: real Mermaid SVG layout (never claim jsdom proves it).
   NODE_PATH=/tmp/lb-reader-tests/node_modules node tests/build-mermaid-preview.cjs */
const fs=require('node:fs'),path=require('node:path'),{JSDOM}=require('jsdom');
const root=path.resolve(__dirname,'..');
const siteRoot=process.env.LONGBLOG_SITE_ROOT?path.resolve(process.env.LONGBLOG_SITE_ROOT):null;
let actual='<pre><code class="language-mermaid">flowchart TD\n A --> B</code></pre>';
let articleId='synthetic-mermaid';
if(siteRoot&&fs.existsSync(path.join(siteRoot,'src/data/trilium-posts.content.generated.ts'))){
  const s=fs.readFileSync(path.join(siteRoot,'src/data/trilium-posts.content.generated.ts'),'utf8');
  const records=JSON.parse(s.slice(s.indexOf('= [')+2).trim().replace(/;\s*$/,''));
  const article=records.find(p=>p.contentHtml.includes('language-mermaid'));
  if(article){
    const d=new JSDOM(article.contentHtml).window.document;
    actual=d.querySelector('code.language-mermaid').closest('pre').outerHTML;
    articleId=article.id;
  }
}
const extra=`<h2>Sequence / malformed / blocked / later valid</h2><pre><code class="language-text-x-mermaid">sequenceDiagram\nparticipant A as 读者\nparticipant B as 离线阅读器\nA-&gt;&gt;B: 打开文章\nB--&gt;&gt;A: 本地图表</code></pre><pre><code class="language-mermaid">flowchart TD\nthis is malformed [</code></pre><pre><code class="language-mermaid">%%{init: {'securityLevel':'loose'}}%%\nflowchart TD\nA--&gt;B</code></pre><pre><code class="language-mermaid">flowchart LR\nA[后续正常图] --&gt; B[完成]</code></pre><p>普通代码不可转换</p><pre><code class="language-js">console.log('plain code');</code></pre>`;
const payload={title:'Mermaid 离线图片：真实文章与安全回归',meta:'文章 '+articleId+' · 浏览器布局验证，非原生运行截图',html:actual+extra,site:'https://huowenlong.com/',posts:[]};
const json=JSON.stringify(payload).replace(/</g,'\\u003c');
const html=`<!doctype html><html lang=zh-CN><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><link rel=stylesheet href="../resources/Reader/vendor/katex.min.css"><link rel=stylesheet href="../resources/Reader/reader.css"><main id=reader><h1 id=title></h1><p id=meta></p><article id=content></article><p id=status></p></main><script>window.networkAttempts=[];window.fetch=(...a)=>{networkAttempts.push('fetch');throw Error('Offline test');};window.XMLHttpRequest=function(){networkAttempts.push('xhr');throw Error('Offline test');};window.WebSocket=function(){networkAttempts.push('ws');throw Error('Offline test');};</script><script src="../resources/Reader/vendor/katex.min.js"></script><script src="../resources/Reader/vendor/mermaid.min.js"></script><script src="../resources/Reader/reader-mermaid.js"></script><script src="../resources/Reader/reader.js"></script><script>window.bridgeEvents=[];window.testPayload=${json};window.initialResult=LBReader.render(testPayload,document,m=>bridgeEvents.push(m));window.LBReaderDiagramsComplete.then(()=>{window.diagramTestsComplete=true;});</script></html>`;
fs.writeFileSync(path.join(__dirname,'mermaid-preview.html'),html);
// Insert production CSP AFTER trusted fixture scripts loaded; subsequent async
// graph rendering/image decoding must succeed under script-none/connect-none.
const csp=fs.readFileSync(path.join(root,'resources/Reader/index.html'),'utf8').match(/http-equiv="Content-Security-Policy" content="([^"]+)"/)[1];
const strict=html.replace('</html>',`<script>setTimeout(()=>{const meta=document.createElement('meta');meta.httpEquiv='Content-Security-Policy';meta.content=${JSON.stringify(csp)};document.head.append(meta);},0);</script></html>`);
fs.writeFileSync(path.join(__dirname,'mermaid-csp-preview.html'),strict);
console.log(JSON.stringify({article:article.id,source:d.querySelector('code.language-mermaid').textContent}));
