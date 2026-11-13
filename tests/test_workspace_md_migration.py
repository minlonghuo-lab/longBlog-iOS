"""Exercise production tool, not a Python reimplementation of its protocol.

All documents here are synthetic. Never mutate/read actual notes in tests.
"""
from pathlib import Path
import importlib.util
import json
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('migration', ROOT/'tools/migrate_workspace_md.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)

HTML = b'<details open><summary>card</summary>\n\n<figure class="table"><table><tbody><tr><td rowspan="2">A<br>B</td><td>x</td></tr><tr><td><em>y</em></td></tr></tbody></table></figure><pre><code class="language-mermaid">flowchart TD\nA--&gt;B</code></pre><p>$x_1$</p><div class="math">$$x^2$$</div></details>'
MD = b'---\nid: "Note1"\ntitle: "Fixture"\npublish: true\ncreatedAt: "2020-01-01T00:00:00Z"\ncustom: "keep-me"\n---\n\nlossy projection\n'

class ProductionMigration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)/'notes'
        self.root.mkdir()
        (self.root/'Note1.md').write_bytes(MD)
        (self.root/'Note1.html').write_bytes(HTML)
        assets = self.root/'assets/Note1/nested'
        assets.mkdir(parents=True)
        (assets/'unreferenced.bin').write_bytes(b'\x00\xffasset')
        state = {'version':1, 'repository':'owner/repo', 'branch':'main', 'files':{
            'Note1.md':{'remote':'content/posts/Note1.md','sha':'1'*40,'baseline':m.digest(MD)},
            'Note1.html':{'remote':'content/posts/Note1.html','sha':'2'*40,'baseline':m.digest(HTML)}}}
        (self.root/m.SYNC).write_bytes(m.canonical_json(state))
    def plan(self, **kwargs):
        return m.build_plan(self.root, **kwargs)
    def apply(self, fail=None):
        journal,payloads = self.plan()
        transaction,journal = m.prepare(self.root,journal,payloads)
        m.install(self.root,transaction,journal,fail)
        return transaction,journal
    def token(self):
        return json.loads((self.root/m.ACTIVE).read_bytes())['token']
    def target(self):
        return self.root/'已发布/Fixture_Note1'
    def test_dry_run_writes_nothing(self):
        before = m.inventory(self.root.parent,'notes')
        journal,payloads = self.plan()
        self.assertEqual(m.inventory(self.root.parent,'notes'),before)
        self.assertEqual(journal['phase'],'planned')
        self.assertEqual(payloads['Note1'].split(b'---\n',2)[2],HTML)
    def test_lossless_structure_metadata_assets_and_idempotency(self):
        transaction,journal = self.apply()
        body = (self.target()/'index.md').read_bytes()
        self.assertEqual(body.split(b'---\n',2)[2],HTML)
        self.assertIn(b'bodyFormat: html',body)
        self.assertIn(b'custom: "keep-me"',body)
        self.assertIn(b'createdAt: "2020-01-01T00:00:00Z"',body)
        self.assertEqual((self.target()/'assets/nested/unreferenced.bin').read_bytes(),b'\x00\xffasset')
        self.assertFalse((self.target()/'index.html').exists())
        self.assertFalse((self.root/'Note1.html').exists())
        self.assertEqual((self.root/transaction/'originals/Note1.html').read_bytes(),HTML)
        self.assertEqual((self.root/transaction/'retired/Note1.html').read_bytes(),HTML)
        self.assertEqual(journal['phase'],'complete')
        state = m.read_json(self.root,m.SYNC)
        self.assertEqual(state['files']['Note1.md']['baseline'],m.digest(MD))
        self.assertEqual(state['singleSource']['Note1']['status'],'needs-publish')
        plan,_ = self.plan()
        self.assertEqual(plan['plans'][0]['status'],'already_single_source')
        # Authors can edit their migrated source; a second apply never rewrites it.
        (self.target()/'index.md').write_bytes(body+b'<!-- author edit -->')
        self.assertEqual(self.plan()[0]['plans'][0]['status'],'already_single_source')
    def test_full_document_body_is_preserved_without_wrapper(self):
        full = b'<!DOCTYPE html><html><head><title>not article</title></head><body class="main">'+HTML+b'</body></html>'
        self.assertEqual(m.html_body(full),HTML.decode())
        with self.assertRaises(m.Refused):
            m.html_body(b'<html><head><style>td{color:red}</style></head><body>x</body></html>')
    def test_no_silent_loss_of_modified_md(self):
        (self.root/'Note1.md').write_bytes(MD+b'NEW AUTHOR WORDS')
        with self.assertRaisesRegex(m.Refused,'authority'):
            self.plan()
        journal,payloads = self.plan(html_policy='prefer-html-preserve-md')
        transaction,journal = m.prepare(self.root,journal,payloads)
        m.install(self.root,transaction,journal)
        self.assertEqual((self.root/transaction/'originals/Note1.md').read_bytes(),MD+b'NEW AUTHOR WORDS')
    def test_differing_collision_never_overwritten(self):
        self.target().mkdir(parents=True)
        (self.target()/'index.md').write_bytes(b'EXTERNAL EDIT')
        before = m.inventory(self.root.parent,'notes')
        with self.assertRaisesRegex(m.Refused,'existing_target_differs'):
            self.plan()
        self.assertEqual(m.inventory(self.root.parent,'notes'),before)
    def test_equal_existing_target_adopted_and_rollback_retains_it(self):
        journal,payloads = self.plan()
        self.target().mkdir(parents=True)
        (self.target()/'index.md').write_bytes(payloads['Note1'])
        (self.target()/'README.longblog.txt').write_bytes(m.README)
        import shutil
        shutil.copytree(self.root/'assets/Note1',self.target()/'assets')
        journal,payloads = self.plan()
        self.assertEqual(journal['plans'][0]['status'],'adopt_equal')
        transaction,journal = m.prepare(self.root,journal,payloads)
        m.install(self.root,transaction,journal)
        m.rollback(self.root,transaction,journal)
        self.assertTrue(self.target().exists())
        self.assertEqual((self.root/'Note1.md').read_bytes(),MD)
    def test_pending_exactly_preserved_and_guarded(self):
        state = m.read_json(self.root,m.SYNC)
        pending = {'operation':'publish','confirmed':True,'payloads':{'old':'secret'},'commit':'3'*40}
        state['pending']=pending
        (self.root/m.SYNC).write_bytes(m.canonical_json(state))
        with self.assertRaisesRegex(m.Refused,'sync_pending'):
            self.plan()
        journal,payloads = self.plan(allow_pending=True)
        transaction,journal=m.prepare(self.root,journal,payloads)
        m.install(self.root,transaction,journal)
        after = m.read_json(self.root,m.SYNC)
        self.assertEqual(after['pending'],pending)
        self.assertIn('singleSourcePendingReview',after)
        m.rollback(self.root,transaction,journal)
        self.assertEqual(m.read_json(self.root,m.SYNC),state)
    def test_crash_each_phase_resume_and_rollback(self):
        for phase in ('staged_verified','target_claimed','first_install','installed_verified','state_guarded','manifest_committed','verified','first_retirement','complete'):
            with self.subTest(phase=phase):
                journal,payloads = self.plan()
                transaction,journal=m.prepare(self.root,journal,payloads)
                if phase != 'staged_verified':
                    with self.assertRaises(m.Refused):
                        m.install(self.root,transaction,journal,phase)
                transaction,journal=m.load_transaction(self.root,journal['token'])
                m.install(self.root,transaction,journal)
                self.assertEqual(journal['phase'],'complete')
                m.rollback(self.root,transaction,journal)
                self.assertEqual((self.root/'Note1.md').read_bytes(),MD)
                self.assertEqual((self.root/'Note1.html').read_bytes(),HTML)
                self.assertFalse(self.target().exists())
    def test_rollback_never_discards_author_changes(self):
        transaction,journal=self.apply()
        p=self.target()/'index.md'
        p.write_bytes(p.read_bytes()+b'edited')
        before=m.inventory(self.root.parent,'notes')
        with self.assertRaisesRegex(m.Refused,'has_edits'):
            m.rollback(self.root,transaction,journal)
        self.assertEqual(m.inventory(self.root.parent,'notes'),before)
    def test_source_race_refused_before_install(self):
        journal,payloads=self.plan()
        transaction,journal=m.prepare(self.root,journal,payloads)
        (self.root/'Note1.md').write_bytes(MD+b'edit after stage')
        with self.assertRaisesRegex(m.Refused,'source_changed'):
            m.install(self.root,transaction,journal)
        self.assertFalse(self.target().exists())
    def test_symlink_and_outside_root_rejected(self):
        for rel in ('../escape','assets/../escape','/etc/passwd'):
            with self.assertRaises(m.Refused):
                m.inside(self.root,rel)
        outside=Path(self.temp.name)/'external'
        outside.mkdir()
        (self.root/'已发布').symlink_to(outside,target_is_directory=True)
        with self.assertRaisesRegex(m.Refused,'symlink'):
            self.plan()
        self.assertEqual(list(outside.iterdir()),[])
    def test_asset_symlink_rejected(self):
        (self.root/'assets/Note1/link').symlink_to('/etc/passwd')
        with self.assertRaisesRegex(m.Refused,'symlink'):
            self.plan()
    def test_stdout_never_discloses_titles_ids_or_body(self):
        result=subprocess.run(['python3',str(ROOT/'tools/migrate_workspace_md.py'),'dry-run','--root',str(self.root)],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('Note1',result.stdout+result.stderr)
        self.assertNotIn('Fixture',result.stdout+result.stderr)
        self.assertNotIn('lossy projection',result.stdout+result.stderr)
    def test_directory_url_trailing_slashes_identical(self):
        # The production Python filesystem functions operate on canonical root,
        # including roots supplied as bookmark-style trailing slash strings.
        a=m.root_path(str(self.root))
        b=m.root_path(str(self.root)+'///')
        self.assertEqual(a,b)
        self.assertEqual(m.build_plan(a)[0],m.build_plan(b)[0])

    def test_metadata_only_edit_uses_body_baseline_and_retains_dates(self):
        state=m.read_json(self.root,m.SYNC)
        state['files']['Note1.md']['bodyBaseline']=m.digest(b'lossy projection')
        (self.root/m.SYNC).write_bytes(m.canonical_json(state))
        changed=MD.replace(b'custom: "keep-me"',b'custom: "keep-me"\nupdatedAt: "2026-11-07T03:10:00Z"')
        (self.root/'Note1.md').write_bytes(changed)
        _,payloads=self.plan()
        self.assertIn(b'updatedAt: "2026-11-07T03:10:00Z"',payloads['Note1'])
    def test_verified_pending_pure_function_checks_git_sha_identity_local_bytes(self):
        import base64,hashlib,copy
        state=m.read_json(self.root,m.SYNC)
        path='content/posts/Note1.md'
        sha=hashlib.sha1(b'blob '+str(len(MD)).encode()+b'\x00'+MD).hexdigest()
        state['pending']={'operation':'publish','confirmed':True,'repository':'owner/repo',
            'credentialID':'synthetic-id','commit':'a'*40,'base':'b'*40,
            'payloads':{path:base64.b64encode(MD).decode()},'before':{'Note1.md':'old'},'shas':{path:sha}}
        proof={'repository':'owner/repo','branch':'main','credentialID':'synthetic-id',
            'state':'applied','commit':'a'*40,'head':'a'*40,'files':{path:{'sha':sha,'mode':'100644'}}}
        before=copy.deepcopy(state)
        result=m.verified_pending_completion(state,proof,{'Note1.md':MD})
        self.assertEqual(state,before)
        self.assertNotIn('pending',result)
        self.assertEqual(result['files']['Note1.md']['baseline'],m.digest(MD))
        for key,value in [('credentialID','wrong'),('head',''),('state','unchanged')]:
            wrong=dict(proof,**{key:value})
            with self.assertRaises(m.Refused):
                m.verified_pending_completion(state,wrong,{'Note1.md':MD})
        with self.assertRaisesRegex(m.Refused,'local_payload_differs'):
            m.verified_pending_completion(state,proof,{'Note1.md':MD+b'edit'})
    def test_claimed_partial_copy_resumes_without_overwriting_bytes(self):
        journal,payloads=self.plan()
        transaction,journal=m.prepare(self.root,journal,payloads)
        with self.assertRaises(m.Refused):
            m.install(self.root,transaction,journal,'target_claimed')
        (self.target()/'index.md').write_bytes(payloads['Note1'][:39])
        m.install(self.root,transaction,journal)
        self.assertEqual((self.target()/'index.md').read_bytes(),payloads['Note1'])
    def test_claimed_target_with_differing_byte_is_preserved(self):
        journal,payloads=self.plan()
        transaction,journal=m.prepare(self.root,journal,payloads)
        with self.assertRaises(m.Refused):
            m.install(self.root,transaction,journal,'target_claimed')
        p=self.target()/'index.md'
        p.write_bytes(b'EXTERNAL WORDS')
        with self.assertRaises(m.Refused):
            m.install(self.root,transaction,journal)
        self.assertEqual(p.read_bytes(),b'EXTERNAL WORDS')
        self.assertTrue((self.root/'Note1.md').exists())
        self.assertFalse((self.root/m.LAYOUT).exists())
    def test_empty_target_appearing_after_stage_is_not_clobbered(self):
        journal,payloads=self.plan()
        transaction,journal=m.prepare(self.root,journal,payloads)
        self.target().mkdir(parents=True)
        inode=self.target().stat().st_ino
        with self.assertRaisesRegex(m.Refused,'existing_target_differs'):
            m.install(self.root,transaction,journal)
        self.assertEqual(self.target().stat().st_ino,inode)
        self.assertEqual(list(self.target().iterdir()),[])
    def test_rollback_after_claim_only_preserves_originals(self):
        journal,payloads=self.plan()
        transaction,journal=m.prepare(self.root,journal,payloads)
        with self.assertRaises(m.Refused):
            m.install(self.root,transaction,journal,'target_claimed')
        m.rollback(self.root,transaction,journal)
        self.assertFalse(self.target().exists())
        self.assertEqual((self.root/'Note1.md').read_bytes(),MD)
    def test_claim_without_marker_is_not_owned_after_restart(self):
        journal,payloads=self.plan()
        transaction,journal=m.prepare(self.root,journal,payloads)
        self.target().mkdir(parents=True)
        # Simulates process death between exclusive mkdir and marker creation.
        # Even an empty directory is NOT automatically adopted without proof.
        transaction,journal=m.load_transaction(self.root,journal['token'])
        with self.assertRaisesRegex(m.Refused,'existing_target_differs'):
            m.install(self.root,transaction,journal)
        self.assertEqual(list(self.target().iterdir()),[])
        self.assertTrue((self.root/'Note1.md').exists())
        self.assertFalse((self.root/m.LAYOUT).exists())
    def test_partial_owned_copy_rollback_preserves_original_bytes(self):
        journal,payloads=self.plan()
        transaction,journal=m.prepare(self.root,journal,payloads)
        with self.assertRaises(m.Refused):
            m.install(self.root,transaction,journal,'target_claimed')
        (self.target()/'index.md').write_bytes(payloads['Note1'][:51])
        transaction,journal=m.load_transaction(self.root,journal['token'])
        m.rollback(self.root,transaction,journal)
        self.assertFalse(self.target().exists())
        self.assertEqual((self.root/'Note1.md').read_bytes(),MD)
        self.assertEqual((self.root/'Note1.html').read_bytes(),HTML)
        self.assertEqual((self.root/transaction/'rollback-installed/Note1/index.md').read_bytes(),payloads['Note1'][:51])
    def test_old_staged_journal_without_claim_events_resumes_safely(self):
        journal,payloads=self.plan()
        transaction,journal=m.prepare(self.root,journal,payloads)
        self.assertEqual(journal['version'],1)
        self.assertEqual(journal['events'],[])
        transaction,journal=m.load_transaction(self.root,journal['token'])
        m.install(self.root,transaction,journal)
        self.assertEqual(journal['phase'],'complete')
        self.assertEqual((self.target()/'index.md').read_bytes(),payloads['Note1'])
    def test_production_objc_and_foundation_fixture_strict_compile(self):
        sdk=Path.home()/'.ios-sdk/iPhoneOS26.5.sdk'
        if not sdk.exists():
            self.skipTest('iOS SDK unavailable; Foundation runtime execution needs iOS runner')
        result=subprocess.run(['clang','-target','arm64-apple-ios26.0','-isysroot',str(sdk),
            '-F',str(sdk/'System/Library/SubFrameworks'),'-fobjc-arc','-fsyntax-only',
            '-Wall','-Wextra','-Werror','-Wno-unused-parameter','-Wno-nullability-completeness',
            '-I',str(ROOT/'src'),str(ROOT/'tests/MDArchiveURLFixtures.m')],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)

if __name__=='__main__':unittest.main()
