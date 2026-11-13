"""Visual17 regressions: source contracts + real bundled-JS DOM checks, not UIKit pixel proof.
Run python3 -m unittest discover -s tests -p 'test_visual17.py' -v.
Optional DOM tooling: NODE_PATH=/tmp/lb-reader-tests/node_modules (existing jsdom).
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
READER = (ROOT / 'src/LBPostReader.m').read_text()
VIEWS = (ROOT / 'src/LBMemosViews.m').read_text()
NAV = (ROOT / 'src/LBNavigationController.m').read_text()


def preview_bootstrap():
    block = READER.split('if ([self memoPreview]) [script appendString:', 1)[1].split('];', 1)[0]
    return ''.join(json.loads(s) for s in re.findall(r'@?("(?:[^"\\]|\\.)*")', block))


class Visual17Contracts(unittest.TestCase):
    def test_draft_does_not_synthesize_epoch_or_slug(self):
        preview = VIEWS.split('UIViewController *LBMemoMarkdownPreview(', 1)[1].split('@interface', 1)[0]
        for text in ('isfinite(seconds)', 'seconds > 0', 'if (hasCreationDate)', '@"草稿预览"', '@"isPrivateMemoPreview":@YES'):
            self.assertIn(text, preview)
        self.assertNotIn('@"slug"', preview)
        self.assertIn('[self hasPublishedDate] ?', READER)
        self.assertIn('self.navigationItem.subtitle = nil', READER)
        self.assertIn('@"title":[self memoPreview] ? @""', READER)
        self.assertIn('meta = [NSString stringWithFormat:@"发布：%@    更新：%@", primary, update];', READER)
        self.assertIn('meta = [NSString stringWithFormat:@"创建：%@    更新：%@", primary, update];', READER)
        self.assertIn('LBReaderDateText', READER)

    def test_theme_is_native_resolved_and_no_shared_asset_change_needed(self):
        # 2.15: memo preview reuses the website article stylesheet (memoSiteStyle),
        # so no native colour bridge or transparent override remains.
        for text in ('inContentWorld:_world', 'memosPreviewCurrent', '@"memoSiteStyle":@([self memoPreview])',
                     '_web.backgroundColor = LBTheme.paper'):
            self.assertIn(text, READER)
        self.assertNotIn('applyMemoPreviewTheme', READER)
        bootstrap = preview_bootstrap()
        for text in ('#title:empty', '#meta:empty', "p.textContent='暂无内容'"):
            self.assertIn(text, bootstrap)
        self.assertNotIn('background:transparent', bootstrap)
        self.assertNotIn('innerHTML', bootstrap)
        self.assertNotIn('fetch(', bootstrap)
        template = (ROOT / 'resources/Reader/index.html').read_text()
        self.assertIn("script-src 'none'", template)
        self.assertIn("connect-src 'none'", template)

    def test_interactive_pop_freezes_until_completion_not_just_finger_up(self):
        # The entire custom transition/mask implementation was removed in 1.9.
        for text in ('_geometryFrozen', '_geometryCoordinator', 'maskView',
                     'convertRect:', 'searchFrame', 'additionalSafeAreaInsets',
                     '_backdrop', 'animateAlongsideTransition:'):
            self.assertNotIn(text, NAV)
        self.assertIn('item.titleView = nil', NAV)
        self.assertIn('UINavigationItemStyleBrowser', NAV)

    def test_real_bundled_markdown_and_native_preview_bootstrap(self):
        if not shutil.which('node'):
            self.skipTest('node unavailable; source contracts still run')
        env = os.environ.copy()
        env['NODE_PATH'] = env.get('NODE_PATH', '/tmp/lb-reader-tests/node_modules')
        check = subprocess.run(['node', '-e', "require.resolve('jsdom')"], env=env, capture_output=True)
        if check.returncode:
            self.skipTest('optional jsdom unavailable; no network install performed')
        script = r'''
const fs=require('node:fs'), assert=require('node:assert/strict');
const {JSDOM}=require('jsdom');
const root=ROOT, bootstrap=BOOTSTRAP;
function setup(markdown, meta='') {
  const dom=new JSDOM(fs.readFileSync(root+'/resources/Reader/index.html','utf8'), {url:'https://reader.invalid/',runScripts:'outside-only'});
  const w=dom.window, doc=w.document, messages=[];
  for(const file of ['vendor/marked.umd.js','vendor/katex.min.js','reader.js']) w.eval(fs.readFileSync(root+'/resources/Reader/'+file,'utf8'));
  w.eval(bootstrap);
  const payload={isMemo:true,memoSiteStyle:true,markdown,title:'',meta,html:'',site:'https://memos.invalid/',posts:[]};
  w.LBReader.render(payload,doc,m=>messages.push(m));
  w.LBMemoPreviewDidRender(payload);
  return {dom,w,doc,messages};
}
for (const empty of ['', '  \n\t']) {
  const {dom,doc}=setup(empty);
  assert.equal(doc.querySelector('#content').textContent,'暂无内容');
  assert.equal(doc.querySelector('#title').textContent,'');
  assert.equal(doc.querySelector('#meta').textContent,'');
  assert.ok(!doc.body.textContent.includes('1970'));
  assert.equal(doc.querySelectorAll('.memo-preview-empty[role=status]').length,1);
  assert.ok(doc.documentElement.classList.contains('lb-article-reader'));
  dom.window.close();
}
const {dom,w,doc,messages}=setup('## 正文\n\n**粗体**\n\n<span class="math-tex">$x^2$</span>\n\n![a](https://evil.invalid/beacon)\n\n<script>window.pwned=true</script>', '2026年11月4日');
assert.equal(doc.querySelector('article h2').textContent,'正文');
assert.equal(doc.querySelector('article strong').textContent,'粗体');
assert.equal(doc.querySelectorAll('.katex').length,1);
assert.equal(doc.querySelectorAll('article script,article img').length,0);
assert.equal(w.pwned,undefined); assert.equal(messages.length,0);
assert.equal(doc.querySelectorAll('.memo-preview-empty').length,0);
assert.equal(doc.querySelector('#meta').textContent,'2026年11月4日');
// Same site typography/classes as articles, but memo safety (no authored img) kept.
assert.ok(doc.documentElement.classList.contains('lb-article-reader'));
assert.ok(doc.querySelector('#content').classList.contains('site-content'));
dom.window.close();
console.log('empty/whitespace/date/theme/markdown/math/no-beacon/sanitizer passed');
'''.replace('ROOT', json.dumps(str(ROOT))).replace('BOOTSTRAP', json.dumps(preview_bootstrap()))
        result = subprocess.run(['node'], input=script, text=True, env=env, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
