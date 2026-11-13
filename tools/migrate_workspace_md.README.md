# Offline single-source workspace migration

Run from the repository root with Python 3.9+ (stdlib only). Close LongBlogInbox,
editors, sync clients and other writers first. This is an offline exclusive-writer
maintenance operation, not a concurrent live migration. Do not commit a real notes
workspace, journals, proofs, original frontmatter/body, or backups to the repository.
The tool's stdout/stderr contain only counts, statuses, opaque transaction/plan
hashes and fixed error codes; no titles, article IDs, bodies, payloads or credentials.

## Format contract

```yaml
bodyFormat: html
bodySource: legacy-html
singleSourceVersion: 1
```

`index.md` is the sole active source. Its body is the original HTML fragment, NOT a
lossy Markdown projection or pure Markdown syntax. Rich table/details/card markup,
attributes, whitespace, `$...$`/`$$...$$` source and `language-mermaid` code remain
unchanged. This tool does not convert formulas/mermaid into generated SVG/HTML;
existing Reader/site rendering handles original HTML encodings. Reader/site MUST
use explicit `bodyFormat: html` to bypass Markdown parsing of the complete body.
A full HTML document is reduced to its exact body substring; original HTML full
bytes remain in backup. Head style/script/link dependencies cause refusal instead
of silently losing semantics. HTML fragments are stored unchanged. No HTML
sanitization occurs in migration; normal Reader/site security boundaries remain.

When there is no sidecar, the original Markdown body stays Markdown and is marked
`bodyFormat: markdown`, `bodySource: original-markdown`, `singleSourceVersion: 1`.
All frontmatter lines and existing metadata dates/IDs are retained; explicit format
markers are added. MD+HTML ambiguity is allowed by default only when the MD file
baseline OR production-equivalent bodyBaseline matches the recorded clean state.
Thus metadata-only edits retain metadata without being mistaken for body edits.
A genuine/unproven MD body edit refuses automatic HTML selection. The explicit
`--html-policy prefer-html-preserve-md` option selects HTML while retaining the
entire original MD in verified backups; use only after manual review of both bodies.

## Dry-run

```sh
python3 ios/LongBlogInbox/tools/migrate_workspace_md.py dry-run --root /path/to/notes
```

Dry-run never creates directories, journals, stages, locks, or state files. It hashes
real source/asset trees, checks manifest/path/type/case/Unicode collisions and returns
`plan_fingerprint`. The default HTML policy is `refuse-edited`. By default any sync
pending or App layout-pending blocks planning. No GitHub calls are made.

## Apply and resume

```sh
python3 ios/LongBlogInbox/tools/migrate_workspace_md.py apply \
  --root /path/to/notes --expect-plan HASH_FROM_LATEST_DRY_RUN

python3 ios/LongBlogInbox/tools/migrate_workspace_md.py resume \
  --root /path/to/notes --transaction OPAQUE_32_HEX_TOKEN
```

The transaction lives at `.longblog-backups/TOKEN/`; the persistent active pointer
is `.longblog-md-migration-active.json`. An unfinished transaction blocks a new
apply; use resume/rollback with its token. Preparing failures can be rolled back;
resume begins from staged_verified, not incomplete unverified staging.

The journal records every source inventory, old manifest/state inventories, planned
mapping, expected SHA256/size tree, stage/install/retirement events and phase.
Original files and original state/layout bytes are copied into `originals/` and
verified before stage commitment. After `staged_verified`, installation uses an
exclusive `mkdir` claim and `.longblog-install-token`, not directory rename. This
works on iSH/File Providers without `renameat2`/`renamex_np` and cannot replace an
existing empty target directory. Only this transaction's marker permits resuming a
partial copy; existing bytes must equal the staged prefix. Different bytes, extra
files, symlinks and nonregular entries stop rather than overwrite.

The manifest's version remains 1 and `articles` maps canonical IDs to
`草稿|已发布/标题_ID`; extra `singleSourceVersion: 1` is backwards-compatible. The
manifest is the single article-layout switch. State guards are persisted first,
then the manifest; both are read back/verified. Only after complete installed/body/
asset/manifest verification are original active files retired. Because exclusive
rename is unsupported on this platform, retirement verifies a second complete copy
in `retired/`, journals it, then removes only individually matching original files
and empty directories. `rmtree` is never used. Both `originals/` and `retired/` remain
recoverable, and stages are retained. Unknown/new/edited bytes are not deleted.

Identical pre-existing target trees can be adopted without moving them. Different
existing targets are never replaced. Already migrated packages are a no-op, including
later author edits. All assets are copied recursively, including unreferenced assets.
Canonical `/assets/ID/...`, legacy `/trilium-assets/ID/...` and cross-article links are
retained. Packages are NOT fully relative, independently movable folders: App uses
the workspace manifest and website uses canonical asset routing. Per-article README
states this restriction. Keep workspace-level unowned assets; no orphan pruning.

## Rollback

```sh
python3 ios/LongBlogInbox/tools/migrate_workspace_md.py rollback \
  --root /path/to/notes --transaction OPAQUE_32_HEX_TOKEN
```

Rollback preflights installed/source/state/backup inventories before modification.
It preserves installed trees in transaction rollback storage, restores exact original
files/state/manifest and retains journals/backups. A pre-existing identical adopted
target is NOT removed. Post-migration author edits cause refusal, not data loss;
copy/merge those edits manually before rollback. Claim-only and supported partial
installation rollback are covered by actual filesystem tests. During a partial
original-retirement interruption, resume is the preferred recovery path before
rollback. Never hand-delete active pointer/journal to force a new migration.

## Sync pending

Default: refuse and leave pending untouched. A pending confirmed flag alone is NOT
proof that remote main still contains its payloads. Never simply delete it.

Preferred: authenticated read-only GitHub verification of repository/branch/identity,
commit application/ancestry, exact remote blob SHAs/modes at verified head, and local
payload byte equality (including null/deletion). The module exposes a PURE helper:

```python
candidate = migration.verified_pending_completion(state, {
    'repository': state['repository'],
    'branch': 'main',
    'credentialID': state['pending']['credentialID'],
    'state': 'applied',
    'commit': state['pending']['commit'],
    'head': verified_head_sha,
    'files': {remote_path: {'sha': verified_blob_sha, 'mode': '100644'}},
}, {canonical_local_path: local_file_bytes_or_None})
```

Pass a full remote file map obtained at that verified head. The helper itself makes
no IO/network call, does not mutate its input, recomputes Git blob SHAs, compares
exact local/payload bytes and rejects identity/deletion conflicts. The caller must
archive exact original sync bytes plus proof, compare-and-swap its current digest,
then atomically write the candidate. Only that proven pending is cleared. A digest
of the proof/pending remains in `completedPendingAudit`. No credentials belong in
the proof JSON; credentialID is the existing non-secret identity hash, not a token.

Alternative operator-only option: `--allow-verified-pending` preserves pending and
adds `singleSourcePendingReview`. App then fails closed on replay until manual
review. This is NOT a way to silently clear a real pending transaction. Migrated
files retain old remote ownership SHA baselines, and state.singleSource records
local migrated SHA256 with needs-publish status. Old repo HTML/lossy MD cannot
replace migrated sources; a later explicit successful publish atomically removes
remote HTML and advances clean single-source baselines. Remote tombstone checks
continue to reject accidental resurrection of deleted remote articles. New versioned
single-source pending can recover; old pending replay cannot overwrite migration.

## Limits and verification

- This tool deliberately refuses legacy in-place layouts whose mapped existing
  source is already the identical target path, rather than performing a destructive
  swap. Flat legacy workspaces and repeat runs after successful migration are
  supported. For that older layout, use a separately reviewed distinct target plan.
- It does not write remote repositories, resolve merge conflicts, remove shared
  assets, or verify GitHub credentials itself.
- Concurrent/malicious writers during maintenance are out of scope. lstat checks,
  exclusive claims and before/after hashes reject detected races, but there is no
  kernel-wide filesystem snapshot or App coordination lock. Stop all writers.
- Some iOS File Providers do not implement directory fsync. File bytes are fsynced;
  full power-loss durability still requires an external independently verified backup.
- Rich body fidelity means raw HTML in .md, not conversion into pure Markdown.
- tests/test_workspace_md_migration.py invokes actual production migration functions
  against real temporary directories, including failure injection, SHA/hash inventory,
  pending proof validation, copy ownership, no-clobber and rollback.
- tests/MDArchiveURLFixtures.m includes actual LBMdStore.m and exercises NSURL roots
  with/without directory trailing slash, production archive adoption/collision and
  embedded-HTML roundtrip. It is strictly SDK compiled in this environment; runtime
  execution requires an iOS test runner calling LBRunMDArchiveURLFixtures(). Strict
  compilation alone is NOT evidence of actual Apple NSURL runtime slash behavior.
