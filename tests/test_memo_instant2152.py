"""Immediate memo contracts + real renderer DOM (no UIKit/layout simulation).
Run: python3 -m unittest discover -s ios/LongBlogInbox/tests -p test_memo_instant2152.py
DOM dependency: NODE_PATH=/tmp/lb-reader-tests/node_modules (jsdom 26).
No SDK compilation, account I/O or live writes.
"""
import os
import pathlib
import shutil
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DETAIL = (ROOT / 'src/LBMemosDetail.m').read_text()
CONTENT = (ROOT / 'src/LBMemoContentView.m').read_text()
JS = (ROOT / 'resources/Reader/memo-detail.js').read_text()


def method(source, name, following):
    return source.split(name, 1)[1].split(following, 1)[0]


class InstantMemoContracts(unittest.TestCase):
    def test_display_precedes_network_and_appearance(self):
        load = method(DETAIL, '- (void)viewDidLoad', '- (void)viewWillAppear')
        self.assertLess(load.index('cachedState:'), load.index('[self rebuild]'))
        self.assertLess(load.index('[self rebuild]'), load.index('[LBMemosClient.shared memo:'))
        self.assertIn('if (foundCached) return;', load)
        rebuild = method(DETAIL, '- (void)rebuild', '- (UIMenu *)menu')
        self.assertNotIn('if (!_visible)', rebuild)
        self.assertNotIn('_pending', DETAIL)
        self.assertIn('displayMemo:_displayMemo generation:_context', rebuild)
        appear = method(DETAIL, '- (void)viewDidAppear', '- (void)viewWillDisappear')
        self.assertNotIn('[self rebuild]', appear)
        self.assertIn('setPageVisible:YES', appear)

    def test_full_native_body_precedes_engine_and_never_truncates(self):
        init = method(CONTENT, '- (instancetype)initWithPreview:', '- (void)prepareWebView')
        self.assertNotIn('[self prepareWebView]', init)
        self.assertIn('_initialBody.numberOfLines = 0', init)
        display = method(CONTENT, '- (void)displayMemo:', '- (BOOL)currentRevision:')
        self.assertLess(display.index('_initialBody.text ='), display.index('[self prepareWebView]'))
        self.assertIn('memo[@"content"]', display)
        for truncation in ['substringToIndex:', 'LBMemoSnippet', 'lineBreakMode = NSLineBreakByTruncating']:
            self.assertNotIn(truncation, display)
        self.assertIn('_web.hidden = YES', display)
        self.assertIn('_notice.hidden = YES', display)

    def test_cold_bundle_loading_is_background_and_cancellable(self):
        prepare = method(CONTENT, '- (void)prepareWebView', '- (void)displayMemo:')
        self.assertLess(prepare.index('dispatch_get_global_queue'), prepare.index('stringWithContentsOfURL'))
        self.assertLess(prepare.index('dispatch_get_main_queue'), prepare.index('installWebViewWithSource:source'))
        self.assertIn('epoch != self->_webEpoch', prepare)
        self.assertIn('![self currentRevision:self->_revision]', prepare)
        invalidate = method(CONTENT, '- (void)invalidateContent', '- (void)clearContentState')
        self.assertIn('++_webEpoch; _preparing = NO', invalidate)
        self.assertIn('removeAllUserScripts', invalidate)
        self.assertIn('_web = nil', invalidate)

    def test_handoff_requires_revision_checked_actual_height(self):
        bridge = method(CONTENT, '- (void)userContentController:', '- (void)webView:(WKWebView *)webView decidePolicy')
        self.assertLess(bridge.index('currentRevision:'), bridge.index('_web.hidden = NO'))
        self.assertIn('!isfinite(height)', bridge)
        handoff = bridge.split('if (!_initialBody.hidden)', 1)[1]
        self.assertLess(handoff.index('_webHeight.constant = _pendingHeight'), handoff.index('_web.hidden = NO'))
        self.assertIn('performWithoutAnimation:', handoff)
        self.assertIn('_initialBody.hidden = YES; self->_initialBody.text = nil', handoff)
        render = method(CONTENT, '- (void)renderMarkdown', '- (void)setPageVisible:')
        self.assertNotIn('_web.hidden = NO', render)
        self.assertIn('measure();schedule();', JS)

    def test_native_fallback_and_old_async_state_clear_on_account_change(self):
        display = method(CONTENT, '- (void)displayMemo:', '- (BOOL)currentRevision:')
        self.assertLess(display.index('generation != LBMemosClient.shared.generation'), display.index('_initialBody.text ='))
        clear = method(CONTENT, '- (void)clearContentState', '- (void)cacheBecameAvailable:')
        self.assertIn('_initialBody.hidden = YES; _initialBody.text = nil', clear)
        self.assertIn('++_revision', clear)
        self.assertIn('[task cancel]', clear)
        self.assertIn('self.resetMedia()', clear)
        self.assertIn('self.resetDiagram()', clear)
        self.assertIn('window.LBMemoDetail.clear(revision)', clear)
        self.assertIn('WKWebsiteDataStore.nonPersistentDataStore', CONTENT)
        self.assertIn('message.webView != _web', CONTENT)
        self.assertIn('body[@"nonce"]', CONTENT)
        rebuild = method(DETAIL, '- (void)rebuild', '- (UIMenu *)menu')
        self.assertIn('_context != LBMemosClient.shared.generation', rebuild)

    def test_media_and_preview_stay_visibility_gated(self):
        self.assertIn('!owner->_visible', DETAIL)
        self.assertIn('setPageVisible:self->_visible', DETAIL)
        self.assertIn('QLPreviewController', DETAIL)
        self.assertIn('LBReaderImageController', DETAIL)
        self.assertIn('LBDiagramPreviewController', DETAIL)
        self.assertIn('if (fullscreen && !self.isMovingFromParentViewController', DETAIL)
        self.assertIn('self->_visible && self->_preview', CONTENT)
        self.assertIn('kCGImageSourceThumbnailMaxPixelSize:@2048', CONTENT)

    def test_renderer_crash_preserves_body_while_reloading(self):
        crash = method(CONTENT, '- (void)webViewWebContentProcessDidTerminate:', '- (void)dealloc')
        self.assertIn('currentRevision:', crash)
        self.assertLess(crash.index('_initialBody.text ='), crash.index('loadFileURL:'))
        self.assertIn('_web.hidden = YES', crash)
        self.assertIn('_initialBody.hidden = NO', crash)


class InstantMemoDOM(unittest.TestCase):
    def test_real_markdown_sync_height_replacement_and_stale_clear(self):
        if not shutil.which('node'):
            self.skipTest('Node unavailable; native contracts still run')
        env = dict(os.environ)
        if not env.get('NODE_PATH') and pathlib.Path('/tmp/lb-reader-tests/node_modules/jsdom').exists():
            env['NODE_PATH'] = '/tmp/lb-reader-tests/node_modules'
        available = subprocess.run(['node', '-e', "require('jsdom')"], capture_output=True, env=env, timeout=30)
        if available.returncode:
            self.skipTest('Install jsdom@26 and set NODE_PATH for real DOM coverage')
        script = r'''
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require('jsdom'), base=process.argv[1];
const dom=new JSDOM(fs.readFileSync(path.join(base,'memo-detail.html'),'utf8'),{url:'https://memo.invalid/',runScripts:'outside-only'});
const w=dom.window,d=w.document,messages=[];
// Deliberately never deliver rAF: hidden WKWebViews may suspend animation.
w.requestAnimationFrame=()=>0;
d.getElementById('reader').getBoundingClientRect=()=>({height:537,width:320});
for(const f of ['vendor/marked.umd.js','vendor/katex.min.js','reader.js','memo-detail.js'])w.eval(fs.readFileSync(path.join(base,f),'utf8'));
const api=w.LBMemoDetail.install(d,m=>messages.push(m));
assert.equal(messages[0].type,'ready');
const markdown='## Local body\n\n**bold** and $x^2$\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```js\nconst x = 1;\n```\n\n'+('Full private text. '.repeat(1500))+'TAIL_2152\n\n![tracker](https://evil.invalid/pixel)\n<script>window.pwned=true</script>';
assert.equal(api.render({markdown,site:'https://memo.invalid/',posts:[]},11),true);
assert.ok(messages.some(m=>m.type==='height'&&m.revision===11&&m.value===537),'height must arrive without a single animation frame');
assert.equal(d.querySelector('#content h2').textContent,'Local body');
assert.equal(d.querySelector('#content strong').textContent,'bold');
assert.ok(d.querySelector('#content table'));assert.ok(d.querySelector('#content .katex'));
assert.ok(d.querySelector('#content pre code').textContent.includes('const x = 1;'));
assert.ok(d.getElementById('content').textContent.includes('TAIL_2152'));
assert.equal(d.querySelectorAll('#content img,#content script').length,0);assert.equal(w.pwned,undefined);
api.clear(12);assert.equal(d.getElementById('content').textContent,'');
const afterClear=messages.length;
assert.equal(api.render({markdown:'OLD_SECRET'},11),false);assert.equal(messages.length,afterClear);
api.render({markdown:'**Updated local body**',site:'https://memo.invalid/',posts:[]},13);
assert.equal(d.getElementById('content').textContent.trim(),'Updated local body');
assert.ok(!d.getElementById('content').textContent.includes('TAIL_2152'));
api.render({markdown:'',site:'https://memo.invalid/',posts:[]},14);assert.equal(d.getElementById('content').textContent,'（仅附件说说）');
api.clear(15);assert.equal(d.getElementById('content').children.length,0);
console.log(JSON.stringify({fullTextTail:true,markdown:true,synchronousHeight:true,staleRejected:true,replacement:true,emptyMemo:true,authoredImagesBlocked:true}));
dom.window.close();
'''
        result = subprocess.run(['node', '-e', script, str(ROOT / 'resources/Reader')], capture_output=True, text=True, env=env, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('"synchronousHeight":true', result.stdout)


if __name__ == '__main__':
    unittest.main()
