// Build a browser-only layout fixture from REAL generated article fragments.
// This is NOT the production template/bridge; native uses isolated user scripts and script-src 'none'.
const fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'..');
const siteRoot=process.env.LONGBLOG_SITE_ROOT?path.resolve(process.env.LONGBLOG_SITE_ROOT):null;
let snippets='<p><span class="math-tex">$x^2$</span></p><figure class="table"><table><tr><td>合成预览</td></tr></table></figure><pre><code>sample</code></pre>';
let posts=[{id:'sample',slug:'sample',title:'合成文章',summary:'合成摘要'}];
if(siteRoot&&fs.existsSync(path.join(siteRoot,'src/data/trilium-posts.content.generated.ts'))){
  function records(name,key){const s=fs.readFileSync(path.join(siteRoot,'src/data',name),'utf8');return JSON.parse(s.slice(s.indexOf('= [',s.indexOf('export const '+key))+2).trim().replace(/;\s*$/,''));}
  posts=records('trilium-posts.content.generated.ts','triliumPostContents').map(p=>({...p,slug:p.id}));
  const {JSDOM}=require('jsdom');
  const capsule=posts.find(p=>p.id==='dDI26xYqquzY')||posts[0];const doc=new JSDOM(capsule.contentHtml).window.document;
  const mathPost=posts.find(p=>p.contentHtml.includes('math-tex'))||posts[0];const md=new JSDOM(mathPost.contentHtml).window.document;
  snippets=[...Array.from(md.querySelectorAll('.math-tex')).slice(0,3),...Array.from(doc.querySelectorAll('figure.table')).slice(0,2),doc.querySelector('pre'),doc.querySelector('.include-note-card')].filter(Boolean).map(e=>e.outerHTML).join('\n');
}
const payload={title:'阅读器：公式 · 表格 · 代码 · 相关文章',meta:'浏览器布局夹具（非原生运行截图）',html:snippets,site:'https://huowenlong.com/',posts:posts.map(({id,slug,title,summary})=>({id,slug,title,summary}))};
const json=JSON.stringify(payload).replace(/</g,'\\u003c');
const html=`<!doctype html><html lang=zh-CN><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><link rel=stylesheet href="../resources/Reader/vendor/katex.min.css"><link rel=stylesheet href="../resources/Reader/reader.css"><main id=reader><h1 id=title></h1><p id=meta></p><article id=content></article><p id=status></p></main><script src="../resources/Reader/vendor/katex.min.js"></script><script src="../resources/Reader/reader.js"></script><script>window.bridgeEvents=[];LBReader.render(${json},document,m=>{bridgeEvents.push(m);document.getElementById('status').textContent=m.type==='copy'?'已发送复制请求':JSON.stringify(m)});</script></html>`;
fs.writeFileSync(path.join(__dirname,'reader-preview.html'),html);
console.log('Generated tests/reader-preview.html from actual article fragments.');
