/* Static synthetic content only. This debug preview enables scripts explicitly;
 * the bundled native index.html retains script-src 'none' + isolated execution. */
const fs=require('node:fs'),path=require('node:path');
const dir=path.resolve(__dirname,'../resources/Reader');
const payload={title:'文章详情 · 顶部与单源验收',meta:'2026年11月01日\n更新：2026年11月07日',summary:'此页所有文字与代码均为合成样例，不读取任何真实笔记或账户信息。精确时间位于原生右上角「详情」。',hasMarkdown:true,bodyFormat:'html',initialTopGeneration:'preview',noteID:'FixtureNote',site:'https://blog.example.test/',posts:[{id:'RelatedNote',slug:'related-note',title:'相关文章：阅读器与站点一致性',summary:'安全重建的站内卡片，使用本地标题与摘要。'}],markdown:String.raw`
<p>这段是正常正文。表格、公式、代码块与流程图各自独立，代码结束后的文字必须仍是正文。</p>
<h2>一、表格与长字段</h2>
<figure class="table"><table><thead><tr><th>项目</th><th>结果</th><th>说明</th></tr></thead><tbody><tr><td>HTML 格式正文</td><td>显式标志</td><td>保留单元格、标题与代码边界</td></tr><tr><td>本地 Markdown</td><td>唯一正文</td><td>没有 bodyFormat: html 时离线解析 Markdown</td></tr><tr><td colspan="2">横向滚动，不撑破整页</td><td>非常长的合成单词_LongSyntheticIdentifier_0123456789_ABCDEFGHIJKLMNOPQRSTUVWXYZ</td></tr></tbody></table></figure>
<h2>二、公式与代码边界</h2>
<p>未标记的 HTML 段落公式 $x_1^2+y_2^2$，以及行内 $\frac{a}{b}$；代码与货币 $20、$30 不应误算。</p>
<p>行内公式 <span class="math-tex">\(E=mc^2\)</span>，以及带下标的 <span class="math-tex">\(x_1^2+y_2^2\)</span>，不应被 Markdown 损坏。</p>
<div class="math-tex">\[\sum_{i=1}^{n}i=\frac{n(n+1)}{2}\]</div>
<pre><code class="language-text-x-yaml">reader:
  source: canonical-md
  literal: "$not_math$"
  safe: true
  assets: local
</code></pre>
<p id="after-code">代码块已经结束：本段必须显示为正文，而不是 monospace 代码块。</p>
<pre><code class="language-text-x-trilium-auto">开始 ──► 内容重建 ──► 结束
  │          │
  └── 安全 ──┘</code></pre>
<h2>三、离线 Mermaid</h2>
<pre><code class="language-mermaid">flowchart TD
  A[读取唯一正文] --> B{显式 HTML 格式}
  B -->|是| C[安全重建 HTML]
  B -->|否| D[离线解析 Markdown]
  C --> E[文章顶部开始]
  D --> E
</code></pre>
<p>流程图应变成惯性图片，下方源码默认折叠；绝不执行作者回调或插入原始 SVG。</p>
<aside class="admonition tip"><p>提示框、嵌套列表与折叠块都继承博客文章详情的原版 CSS。</p></aside>
<details class="trilium-collapsible"><summary>展开查看安全边界</summary><p>脚本、事件属性、跨域图片与伪造 bridge 控件均无法从笔记进入阅读器。</p></details>
<blockquote><p>使用精确的站点正文样式和字体，而不是另写一份视觉近似。</p></blockquote>
<a class="include-note-card" data-note-id="RelatedNote" href="/blog/related-note/">相关文章</a>
`};
let html=fs.readFileSync(path.join(dir,'index.html'),'utf8');
html=html.replace(/<meta http-equiv="Content-Security-Policy"[^>]*>/,'');
html=html.replace('<head>','<head><base href="../resources/Reader/">');
const files=['vendor/marked.umd.js','vendor/katex.min.js','vendor/site-highlight.js','vendor/mermaid.min.js','reader-mermaid.js','reader.js'];
html=html.replace('</body>',files.map(file=>`<script src="${file}"></script>`).join('\n')+`<script>window.previewMessages=[];window.previewResult=LBReader.render(${JSON.stringify(payload).replace(/</g,'\\u003c')},document,message=>previewMessages.push(message));window.previewDone=LBReaderDiagramsComplete;</script></body>`);
const hash=file=>require('node:crypto').createHash('sha256').update(fs.readFileSync(path.join(dir,file))).digest('hex').slice(0,12);
html=html.replace(/(href|src)="([^":]+\.(?:css|js))"/g,(_,attr,file)=>`${attr}="${file}?v=${hash(file)}"`);
const output=process.argv[2]||path.join(__dirname,'reader-parity-preview.html');fs.writeFileSync(output,html);console.log(output);
