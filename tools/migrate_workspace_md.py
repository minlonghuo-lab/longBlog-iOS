#!/usr/bin/env python3
"""Offline, fail-closed MD migration. Close the App and stop sync before apply.

No article text, paths, titles, IDs, payloads or credentials are printed. dry-run is
read-only. All transaction material stays in root/.longblog-backups/<transaction>.
Requires Python 3.9+, stdlib only; uses actual filesystem lstat/hash/rename semantics.
"""
import argparse
import hashlib
import html.parser
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import unicodedata
import uuid

LAYOUT = '.longblog-layout.json'
SYNC = '.longblog-sync.json'
JOURNAL = 'migration-journal.json'
ACTIVE = '.longblog-md-migration-active.json'
README = ('index.md is the ONLY active article body. bodyFormat: html means the body '
          'is original HTML, not lossy generated Markdown. index.html is backup only.\n'
          'assets/ contains this article attachments, including unreferenced files.\n'
          'Canonical /assets/<ID>/... and /trilium-assets/<ID>/... URLs require the '
          'workspace manifest/App or website resolver. Cross-article references remain '
          'canonical. This is NOT a completely relative, independently movable package.\n'
          'Do not remove .longblog-layout.json. Recoverable originals and transaction '
          'journal are in workspace/.longblog-backups/.\n').encode()

class Refused(Exception):
    pass

def require(ok, reason):
    if not ok:
        raise Refused(reason)

def digest(data):
    return hashlib.sha256(data).hexdigest()

def canonical_json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()

def safe_rel(rel, hidden=False):
    require(isinstance(rel, str) and rel and not rel.startswith('/') and '\\' not in rel
            and '%' not in rel and not any(ord(c) < 32 or ord(c) == 127 for c in rel), 'unsafe_path')
    require(all(p and p not in ('.', '..') and (hidden or not p.startswith('.'))
                for p in rel.split('/')), 'unsafe_path_component')
    return rel

def root_path(value):
    p = Path(os.path.abspath(value))
    for part in (p, *p.parents):
        require(not part.is_symlink(), 'symlink_root')
    require(p.is_dir(), 'missing_root')
    return p

def inside(root, rel):
    safe_rel(rel, hidden=True)
    p = root
    for component in rel.split('/'):
        p = p / component
        try:
            mode = p.lstat().st_mode
        except FileNotFoundError:
            continue
        require(not stat.S_ISLNK(mode), 'symlink_component')
        require(stat.S_ISDIR(mode) or stat.S_ISREG(mode), 'nonregular_component')
    require(os.path.commonpath([root, p]) == str(root), 'outside_root')
    return p

def inventory(root, rel):
    p = inside(root, rel)
    if not p.exists():
        return None
    if p.is_file():
        return {'type': 'file', 'sha256': digest(p.read_bytes()), 'size': p.stat().st_size}
    require(p.is_dir(), 'nonregular_source')
    result = {'': {'type': 'dir'}}
    for base, dirs, files in os.walk(p, followlinks=False):
        for name in sorted(dirs + files):
            q = Path(base) / name
            child = str(q.relative_to(root))
            inside(root, child)
            result[str(q.relative_to(p))] = ({'type': 'dir'} if q.is_dir() else
                {'type': 'file', 'sha256': digest(q.read_bytes()), 'size': q.stat().st_size})
    return {'type': 'tree', 'entries': result}

def sync_dir(path):
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        # Some iOS File Providers do not implement directory fsync; verified
        # copies + persistent journal still protect process interruption, not power loss.
        pass

def atomic(root, rel, data):
    p = inside(root, rel)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = inside(root, str(p.relative_to(root)) + '.tmp-' + uuid.uuid4().hex)
    with open(tmp, 'xb') as out:
        out.write(data)
        out.flush()
        os.fsync(out.fileno())
    inside(root, rel)
    os.replace(tmp, p)
    sync_dir(p.parent)

def read_json(root, rel, default=None):
    p = inside(root, rel)
    if not p.exists():
        return default
    require(p.is_file(), 'json_not_regular')
    try:
        result = json.loads(p.read_bytes())
    except (ValueError, UnicodeError):
        raise Refused('invalid_json') from None
    require(isinstance(result, dict), 'json_not_object')
    return result

def copy_verified(root, source, dest, expected):
    src, dst = inside(root, source), inside(root, dest)
    require(inventory(root, source) == expected, 'source_changed')
    if dst.exists():
        require(inventory(root, dest) == expected, 'backup_or_stage_differs')
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_dir():
        shutil.copytree(src, dst, copy_function=shutil.copy2)
    else:
        shutil.copy2(src, dst)
    require(inventory(root, dest) == expected and inventory(root, source) == expected,
            'copy_verification_failed')
    for base, _, files in os.walk(dst if dst.is_dir() else dst.parent):
        for name in files:
            with open(Path(base) / name, 'rb') as f:
                os.fsync(f.fileno())
    sync_dir(dst.parent)

def scalar(value):
    value = value.strip()
    if value.startswith('"'):
        try:
            return json.loads(value)
        except ValueError:
            raise Refused('unsupported_quoted_metadata') from None
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1].replace("''", "'")
    return value.split(' #', 1)[0].strip()

def parse_md(data):
    try:
        text = data.decode('utf-8')
    except UnicodeError:
        raise Refused('non_utf8_article') from None
    match = re.match(r'\A---\r?\n(.*?)\r?\n---(?:\r?\n|\Z)', text, re.S)
    require(match is not None, 'missing_frontmatter')
    meta = {}
    for line in match[1].splitlines():
        m = re.match(r'^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$', line)
        if m:
            require(m[1] not in meta, 'duplicate_metadata_key')
            meta[m[1]] = m[2]
    return text, match, meta

class BodyBoundary(html.parser.HTMLParser):
    def __init__(self, text):
        super().__init__(convert_charrefs=False)
        self.text = text
        self.offsets = [0]
        for line in text.splitlines(keepends=True):
            self.offsets.append(self.offsets[-1] + len(line))
        self.start = self.end = None
        self.bodies = 0
    def absolute_offset(self):
        line, column = self.getpos()
        return self.offsets[line - 1] + column
    def handle_starttag(self, tag, attrs):
        if tag == 'body':
            self.bodies += 1
            require(self.start is None, 'multiple_html_bodies')
            self.start = self.absolute_offset() + len(self.get_starttag_text())
    def handle_endtag(self, tag):
        if tag == 'body':
            require(self.end is None, 'multiple_html_bodies')
            self.end = self.absolute_offset()

def html_body(data):
    try:
        text = data.decode('utf-8')
    except UnicodeError:
        raise Refused('non_utf8_html') from None
    parser = BodyBoundary(text)
    parser.feed(text)
    if parser.start is None:
        require(not re.search(r'<(?:html|head)\b|<!doctype', text, re.I), 'html_document_missing_body')
        return text
    require(parser.end is not None and parser.end >= parser.start, 'unclosed_html_body')
    # A head stylesheet/script can carry article semantics; do not silently discard it.
    head = text[:parser.start]
    require(not re.search(r'<(?:style|script|link)\b', head, re.I), 'head_dependencies_need_manual_review')
    return text[parser.start:parser.end]

def converted(md, sidecar, note):
    text, match, meta = parse_md(md)
    require(scalar(meta.get('id', note)) == note, 'metadata_id_mismatch')
    already = scalar(meta.get('singleSourceVersion', '')) == '1'
    if already:
        require(sidecar is None, 'single_source_has_active_sidecar')
        return md, meta
    body = html_body(sidecar) if sidecar is not None else text[match.end():]
    body_format = 'html' if sidecar is not None else 'markdown'
    header = match[1]
    header = re.sub(r'(?m)^(?:bodyFormat|bodySource|singleSourceVersion):[^\r\n]*(?:\r?\n|$)', '', header)
    if 'id' not in meta:
        header += '\nid: ' + json.dumps(note)
    header += '\nbodyFormat: ' + body_format + '\nbodySource: ' + ('legacy-html' if sidecar is not None else 'original-markdown') + '\nsingleSourceVersion: 1'
    result = ('---\n' + header + '\n---\n' + body).encode()
    # The original body is byte-for-byte preserved after UTF-8 roundtrip. No DOM
    # serializer, whitespace normalization, Markdown parser or lossy HTML converter.
    require(parse_md(result)[0][parse_md(result)[1].end():] == body, 'body_verification_failed')
    return result, meta

def title_component(title, note):
    title = re.sub(r'[/\\:%\n\r\t"<>|?*\x00-\x1f\x7f-\x9f]', '_', title)
    # Match NSString's 70 UTF-16 code-unit boundary without splitting surrogates.
    title = title.encode('utf-16-le')[:140].decode('utf-16-le', errors='ignore').strip(' .')
    return (title or '未命名文章') + '_' + note

def verified_pending_completion(state, proof, local_bytes):
    """PURE function; no IO/network and never mutates input.

    proof must come from authenticated read-only GitHub confirmation, not a
    caller-supplied assumption: repository/branch, state='applied', commit, head,
    credentialID and a full remote files map {path: {sha, mode}} at that head.
    local_bytes maps CANONICAL local paths to bytes or None for absent files.
    Returns a candidate sync state; caller MUST archive exact original sync bytes
    and proof, compare-and-swap the sync digest, then atomically persist it.
    Never call this to infer that a timed-out request probably succeeded.
    """
    import base64
    import binascii
    require(isinstance(state, dict) and isinstance(proof, dict) and isinstance(local_bytes, dict), 'invalid_recovery_input')
    pending = state.get('pending')
    require(isinstance(pending, dict) and pending.get('operation') in ('publish', 'unpublish', 'delete'), 'invalid_pending')
    require(state.get('repository') == pending.get('repository') == proof.get('repository')
            and state.get('branch') == proof.get('branch') == 'main', 'recovery_repository_mismatch')
    require(proof.get('state') == 'applied' and proof.get('commit') == pending.get('commit')
            and re.fullmatch('[0-9a-f]{40}', proof.get('head', '')) is not None,
            'remote_commit_not_proven_applied')
    require(pending.get('credentialID') and proof.get('credentialID') == pending.get('credentialID'),
            'recovery_identity_mismatch')
    require(isinstance(proof.get('files'), dict) and isinstance(pending.get('payloads'), dict)
            and isinstance(pending.get('before'), dict) and isinstance(pending.get('shas'), dict), 'invalid_recovery_proof')
    result = json.loads(json.dumps(state))
    records = result['files']
    for remote, encoded in pending['payloads'].items():
        safe_rel(remote)
        if remote.startswith('content/posts/'):
            local = remote[len('content/posts/'):]
            require('/' not in local and local.endswith(('.md', '.html')), 'unexpected_recovery_article_path')
        elif remote.startswith('public/assets/'):
            local = remote[len('public/'):]
        elif remote.startswith('public/trilium-assets/'):
            local = 'assets/' + remote[len('public/trilium-assets/'):]
        else:
            raise Refused('unexpected_recovery_path')
        safe_rel(local)
        require(local in local_bytes and local in pending['before'], 'local_recovery_evidence_missing')
        entry = proof['files'].get(remote)
        current = local_bytes[local]
        if encoded is None:
            require(entry is None and current is None, 'recovery_deletion_not_applied')
            records.pop(local, None)
            continue
        require(isinstance(encoded, str), 'invalid_pending_payload')
        try:
            payload = base64.b64decode(encoded, validate=True)
        except (ValueError, binascii.Error):
            raise Refused('invalid_pending_payload') from None
        sha = hashlib.sha1(b'blob ' + str(len(payload)).encode() + b'\x00' + payload).hexdigest()
        require(isinstance(entry, dict) and entry.get('mode') == '100644'
                and sha == pending['shas'].get(remote) == entry.get('sha'), 'remote_payload_not_proven')
        require(current == payload, 'local_payload_differs_preserve_pending')
        record = {'remote': remote, 'sha': sha, 'baseline': digest(payload)}
        if local.endswith('.md') and '/' not in local:
            normalized = payload.decode('utf-8').replace('\r\n', '\n').replace('\r', '\n')
            _, match, _ = parse_md(normalized.encode())
            body = normalized[match.end():].lstrip('\n').rstrip('\n').replace('/trilium-assets/', '/assets/')
            record['bodyBaseline'] = digest(body.encode())
        records[local] = record
    result['head'] = proof['head']
    result.pop('pending')
    # Caller can retain this audit digest without retaining payloads in active state.
    result['completedPendingAudit'] = {'version': 1, 'commit': pending['commit'],
        'pendingDigest': digest(canonical_json(pending)), 'proofDigest': digest(canonical_json(proof))}
    return result


def validate_layout(layout):
    require(isinstance(layout, dict) and layout.get('version') == 1
            and isinstance(layout.get('articles'), dict), 'invalid_layout')
    seen = set()
    for note, directory in layout['articles'].items():
        safe_rel(note)
        require('/' not in note and len(note) <= 160, 'unsafe_id')
        safe_rel(directory)
        parts = directory.split('/')
        require(len(parts) == 2 and parts[0] in ('草稿', '已发布')
                and parts[1].endswith('_' + note), 'invalid_mapping')
        folded = unicodedata.normalize('NFC', directory).lower()
        require(folded not in seen, 'case_unicode_collision')
        seen.add(folded)

def exclusive_copy_file(root, source, destination):
    """Copy into a transaction-owned tree. Existing prefixes resume, never replace.

    Caller MUST prove the destination tree is claimed by this transaction, or is
    a private unique backup tree. A truncated file is resumable only when every
    existing byte equals the source prefix. No differing byte is overwritten.
    """
    src, dst = inside(root, source), inside(root, destination)
    require(src.is_file() and not src.is_symlink(), 'copy_source_not_regular')
    payload = src.read_bytes()
    if dst.exists():
        require(dst.is_file(), 'copy_destination_not_regular')
        prefix = dst.read_bytes()
        require(len(prefix) <= len(payload) and payload.startswith(prefix), 'partial_copy_has_edits')
        if len(prefix) == len(payload):
            return
        with open(dst, 'ab') as out:
            out.write(payload[len(prefix):])
            out.flush()
            os.fsync(out.fileno())
    else:
        dst.parent.mkdir(parents=True, exist_ok=True)
        with open(dst, 'xb') as out:
            out.write(payload)
            out.flush()
            os.fsync(out.fileno())
    require(dst.read_bytes() == payload and src.read_bytes() == payload, 'exclusive_copy_verification_failed')
    shutil.copystat(src, dst, follow_symlinks=False)
    sync_dir(dst.parent)


def require_owned_partial(root, source, destination, expected):
    actual = inventory(root, destination)
    require(actual and actual['type'] == 'tree', 'owned_partial_missing')
    marker = inside(root, destination + '/.longblog-install-token')
    for path, value in actual['entries'].items():
        if path == '.longblog-install-token':
            continue
        target_value = expected['entries'].get(path)
        require(target_value and target_value['type'] == value['type'], 'partial_tree_has_extra_entries')
        if value['type'] == 'file':
            payload = inside(root, source + '/' + path).read_bytes()
            require(payload.startswith(inside(root, destination + '/' + path).read_bytes()), 'partial_copy_has_edits')


def copy_owned_tree(root, source, destination, expected):
    """Only add expected dirs/files; unknown entries, symlinks and edits stop."""
    src, dst = inside(root, source), inside(root, destination)
    require(inventory(root, source) == expected and expected['type'] == 'tree', 'owned_copy_source_changed')
    entries = expected['entries']
    actual = inventory(root, destination)
    require(actual is not None and actual['type'] == 'tree', 'owned_copy_target_missing')
    for path, value in actual['entries'].items():
        if path == '.longblog-install-token':
            continue
        require(path in entries and entries[path]['type'] == value['type'], 'partial_tree_has_extra_entries')
    for path, value in sorted(entries.items(), key=lambda item: (item[0].count('/'), item[0])):
        if not path:
            continue
        dest_rel = destination + '/' + path
        target = inside(root, dest_rel)
        if value['type'] == 'dir':
            if not target.exists():
                target.mkdir()  # exclusive; never merge an outside symlink
            require(target.is_dir(), 'partial_tree_type_changed')
        else:
            exclusive_copy_file(root, source + '/' + path, dest_rel)
    final = inventory(root, destination) if '.longblog-install-token' in entries else target_content(root, destination)
    require(final == expected, 'owned_tree_verification_failed')


def retire_original(root, item, retired_rel, journal, transaction):
    """Verified private backup copy, then remove only individually matching bytes.

    No rename required on iSH. A partial retirement resumes from the complete
    retired copy; unknown/changed remaining files abort without deleting edits.
    """
    source_rel, expected = item['path'], item['inventory']
    source, retired = inside(root, source_rel), inside(root, retired_rel)
    if inventory(root, retired_rel) != expected:
        require(inventory(root, source_rel) == expected, 'source_changed_before_retire_copy')
        if expected['type'] == 'file':
            exclusive_copy_file(root, source_rel, retired_rel)
        else:
            if not retired.exists():
                retired.mkdir(parents=True)  # exclusive creation; no replacement
            copy_owned_tree(root, source_rel, retired_rel, expected)
    require(inventory(root, retired_rel) == expected, 'retired_copy_not_verified')
    journal['events'].append({'action': 'retire_copy_verified', 'path': source_rel})
    journal_write(root, transaction, journal)
    remaining = inventory(root, source_rel)
    if remaining is None:
        return
    if expected['type'] == 'file':
        require(remaining == expected, 'original_edited_before_retirement')
        source.unlink()
        sync_dir(source.parent)
        return
    require(remaining['type'] == 'tree', 'original_type_changed')
    for path, value in remaining['entries'].items():
        require(expected['entries'].get(path) == value, 'original_edited_during_retirement')
    for path, value in sorted(remaining['entries'].items(), key=lambda item: (item[0].count('/'), item[0]), reverse=True):
        if not path:
            continue
        p = inside(root, source_rel + '/' + path)
        if value['type'] == 'dir':
            p.rmdir()  # an unexpected new child causes failure, not recursive loss
        else:
            require(inventory(root, source_rel + '/' + path) == value, 'original_edited_during_retirement')
            p.unlink()
    source.rmdir()
    sync_dir(source.parent)


def expected_tree(md, assets):
    entries = {'': {'type': 'dir'}, 'index.md': {'type': 'file', 'sha256': digest(md), 'size': len(md)},
               'README.longblog.txt': {'type': 'file', 'sha256': digest(README), 'size': len(README)}}
    if assets:
        require(assets['type'] == 'tree', 'assets_not_directory')
        for key, value in assets['entries'].items():
            entries['assets' + ('/' + key if key else '')] = value
    return {'type': 'tree', 'entries': entries}

def target_content(root, rel):
    value = inventory(root, rel)
    # Install token belongs to recovery metadata, never article content.
    if value and value['type'] == 'tree':
        value['entries'].pop('.longblog-install-token', None)
    return value

def old_snapshot(root, rel):
    value = inventory(root, rel)
    return {'path': rel, 'inventory': value}

def build_plan(root, allow_pending=False, html_policy='refuse-edited'):
    active = read_json(root, ACTIVE)
    if active:
        _, old = load_transaction(root, active.get('token', ''))
        require(old['phase'] in ('complete', 'rolled_back'), 'unfinished_migration_use_resume_or_rollback')
    require(not inside(root, '.longblog-layout-pending.json').exists(), 'app_layout_pending_requires_recovery')
    layout = read_json(root, LAYOUT, {'version': 1, 'articles': {}})
    validate_layout(layout)
    state = read_json(root, SYNC)
    if state:
        require(state.get('version') == 1 and isinstance(state.get('files'), dict), 'invalid_sync_state')
        require(not state.get('pending') or allow_pending, 'sync_pending_requires_explicit_verification')
    ids = set(layout['articles'])
    for p in root.iterdir():
        if p.suffix == '.md' and not p.name.startswith('.'):
            require(not p.is_symlink() and p.is_file(), 'unsafe_md')
            ids.add(p.stem)
    plans, sources, payloads = [], {}, {}
    after = dict(layout['articles'])
    for note in sorted(ids):
        safe_rel(note)
        require('/' not in note and len(note) <= 160, 'unsafe_id')
        directory = layout['articles'].get(note)
        mdpath = directory + '/index.md' if directory else note + '.md'
        htmlpath = directory + '/index.html' if directory else note + '.html'
        assetpath = directory + '/assets' if directory else 'assets/' + note
        mdfile = inside(root, mdpath)
        if not mdfile.exists():
            continue  # Manifest tombstone, not a new blank article.
        if directory and inside(root, note + '.md').exists():
            require(inside(root, note + '.md').read_bytes() == mdfile.read_bytes(), 'shadow_root_md_differs')
            sources[note + '.md'] = inventory(root, note + '.md')
        md = mdfile.read_bytes()
        sidecar = inside(root, htmlpath).read_bytes() if inside(root, htmlpath).exists() else None
        oldmeta = parse_md(md)[2]
        if sidecar is not None:
            # A changed Markdown projection may contain newer edits than HTML.
            # Do NOT throw those edits away by blindly selecting the HTML body.
            record = (state or {}).get('files', {}).get(note + '.md')
            # Exact production MDBodyDigest: parse normalizes CRLF/CR; strips
            # leading blank body lines and trailing LF, canonicalizes legacy URLs.
            normalized = md.decode('utf-8').replace('\r\n', '\n').replace('\r', '\n')
            _, body_match, _ = parse_md(normalized.encode())
            baseline_body = normalized[body_match.end():].lstrip('\n').rstrip('\n').replace('/trilium-assets/', '/assets/')
            body_digest = digest(baseline_body.encode())
            known_clean = record and (record.get('baseline') == digest(md)
                or record.get('bodyBaseline') == body_digest)
            require(known_clean or html_policy == 'prefer-html-preserve-md', 'html_md_authority_requires_review')
        newmd, meta = converted(md, sidecar, note)
        title = scalar(meta.get('title', ''))
        published = scalar(meta.get('publish', 'false')) == 'true'
        desired = ('已发布' if published else '草稿') + '/' + title_component(title, note)
        assets = inventory(root, assetpath)
        expected = expected_tree(newmd, assets)
        current = target_content(root, desired)
        if desired == directory:
            # Already migrated packages are a genuine no-op; preserve README edits,
            # extra files and any author changes rather than attempting reinstallation.
            if scalar(meta.get('singleSourceVersion', '')) == '1' and sidecar is None:
                plans.append({'note': note, 'desired': desired, 'source': directory,
                              'status': 'already_single_source', 'expected': current})
                continue
            require(False, 'inplace_legacy_layout_requires_distinct_staging_target')
        status = 'adopt_equal' if current is not None else 'install'
        require(current is None or current == expected, 'existing_target_differs')
        for parent in (desired.split('/')[0],):
            p = inside(root, parent)
            require(not p.exists() or p.is_dir(), 'target_parent_not_directory')
        # Detect case/Unicode aliases on a case-sensitive fixture as well as APFS.
        parent = inside(root, desired.split('/')[0])
        if parent.exists():
            key = unicodedata.normalize('NFC', desired.split('/')[1]).lower()
            for p in parent.iterdir():
                if unicodedata.normalize('NFC', p.name).lower() == key:
                    require(p.name == desired.split('/')[1], 'case_unicode_target_alias')
        if directory:
            sources[directory] = inventory(root, directory)
        else:
            for rel in (mdpath, htmlpath, assetpath):
                inv = inventory(root, rel)
                if inv is not None:
                    sources[rel] = inv
        plans.append({'note': note, 'desired': desired, 'source': directory,
                      'status': status, 'expected': expected,
                      'md': mdpath, 'html': htmlpath if sidecar is not None else None,
                      'assets': assetpath if assets else None,
                      'bodyFormat': 'html' if sidecar is not None else scalar(meta.get('bodyFormat', 'markdown'))})
        payloads[note] = newmd
        after[note] = desired
    manifest = dict(layout, articles=after, singleSourceVersion=1)
    validate_layout(manifest)
    pending = (state or {}).get('pending')
    upgraded = json.loads(json.dumps(state)) if state else None
    if upgraded is not None:
        guards = upgraded.setdefault('singleSource', {})
        for plan in plans:
            note = plan['note']
            guards[note] = {'version': 1, 'status': 'needs-publish',
                'bodyFormat': plan.get('bodyFormat', 'html'),
                'mdBaseline': plan['expected']['entries']['index.md']['sha256']}
        if pending:
            upgraded['singleSourcePendingReview'] = {'version': 1, 'pendingDigest': digest(canonical_json(pending)),
                'reason': 'verified remote transaction retained; do not replay old HTML/MD over migrated source'}
    return {'version': 1, 'phase': 'planned', 'plans': plans,
            'sources': [{'path': p, 'inventory': v} for p, v in sorted(sources.items())],
            'before': [old_snapshot(root, p) for p in (LAYOUT, SYNC)],
            'manifest': manifest, 'state': upgraded, 'pendingPreserved': bool(pending)}, payloads

def summary(plan):
    counts = {}
    for p in plan['plans']:
        counts[p['status']] = counts.get(p['status'], 0) + 1
    return {'phase': plan['phase'], 'articles': len(plan['plans']), 'actions': counts,
            'source_entries': len(plan['sources']), 'pending_preserved': plan['pendingPreserved'],
            'body_policy': 'original_html_body_bytes_in_md; no_lossy_conversion'}

def journal_write(root, transaction, journal):
    atomic(root, transaction + '/' + JOURNAL, canonical_json(journal))

def checkpoint(journal, phase, root, transaction, fail_at):
    journal['phase'] = phase
    journal_write(root, transaction, journal)
    if fail_at == phase:
        raise Refused('injected_stop_' + phase)

def load_transaction(root, token):
    require(re.fullmatch(r'[a-f0-9]{32}', token) is not None, 'invalid_transaction')
    transaction = '.longblog-backups/' + token
    journal = read_json(root, transaction + '/' + JOURNAL)
    require(journal and journal.get('version') == 1 and journal.get('token') == token,
            'invalid_journal')
    # Never trust editable journal paths without the same root guards.
    validate_layout(journal['manifest'])
    for item in journal['sources'] + journal['before']:
        inside(root, item['path'])
    for item in journal['plans']:
        inside(root, item['desired'])
        safe_rel(item['note'])
        require('/' not in item['note'], 'invalid_journal_id')
    return transaction, journal

def verify_sources(root, journal, allow_retired=False):
    transaction = '.longblog-backups/' + journal['token']
    for item in journal['sources']:
        current = inventory(root, item['path'])
        if allow_retired and current != item['inventory']:
            retired = inventory(root, transaction + '/retired/' + item['path'])
            require(retired == item['inventory'], 'source_changed_since_plan')
            if current is not None:
                require(current['type'] == 'tree' and item['inventory']['type'] == 'tree', 'source_changed_since_plan')
                for path, value in current['entries'].items():
                    require(item['inventory']['entries'].get(path) == value, 'source_changed_since_plan')
            current = retired
        require(current == item['inventory'], 'source_changed_since_plan')

def prepare(root, journal, payloads, fail_at=None):
    token = uuid.uuid4().hex
    transaction = '.longblog-backups/' + token
    journal['token'] = token
    journal['events'] = []
    # A journal is installed BEFORE creating any staged/backup file; failure is
    # observable and nothing has been removed or switched.
    checkpoint(journal, 'preparing', root, transaction, None)
    atomic(root, ACTIVE, canonical_json({'version': 1, 'token': token}))
    if fail_at == 'preparing':
        raise Refused('injected_stop_preparing')
    for item in journal['sources'] + journal['before']:
        if item['inventory'] is not None:
            copy_verified(root, item['path'], transaction + '/originals/' + item['path'], item['inventory'])
    for plan in journal['plans']:
        if plan['status'] == 'already_single_source':
            continue
        stage = transaction + '/stage/' + plan['note']
        atomic(root, stage + '/index.md', payloads[plan['note']])
        atomic(root, stage + '/README.longblog.txt', README)
        if plan['assets']:
            copy_verified(root, plan['assets'], stage + '/assets', inventory(root, plan['assets']))
        require(inventory(root, stage) == plan['expected'], 'stage_verification_failed')
    verify_sources(root, journal)
    for item in journal['before']:
        require(inventory(root, item['path']) == item['inventory'], 'control_file_changed')
    # Keep exact committed control bytes for reentrancy checks and rollback.
    atomic(root, transaction + '/after-layout.json', canonical_json(journal['manifest']))
    if journal['state'] is not None:
        atomic(root, transaction + '/after-sync.json', canonical_json(journal['state']))
    checkpoint(journal, 'staged_verified', root, transaction, fail_at)
    return transaction, journal

def install(root, transaction, journal, fail_at=None):
    require(journal['phase'] not in ('preparing', 'rolled_back', 'rolling_back'), 'transaction_not_installable')
    if journal['phase'] == 'complete':
        return journal
    verify_sources(root, journal, allow_retired=True)
    # Before a manifest switch a third-party metadata/pending edit must abort.
    for item in journal['before']:
        current = inventory(root, item['path'])
        after_rel = transaction + ('/after-layout.json' if item['path'] == LAYOUT else '/after-sync.json')
        after = inventory(root, after_rel)
        require(current == item['inventory'] or (after is not None and current == after), 'control_file_changed')
    for plan in journal['plans']:
        if plan['status'] == 'already_single_source':
            require(target_content(root, plan['desired']) == plan['expected'], 'existing_single_source_changed')
            continue
        target, stage = inside(root, plan['desired']), inside(root, transaction + '/stage/' + plan['note'])
        current = target_content(root, plan['desired'])
        marker_rel = plan['desired'] + '/.longblog-install-token'
        marker = inside(root, marker_rel)
        owned = marker.exists() and marker.is_file() and marker.read_bytes() == journal['token'].encode()
        if current is None:
            require(inventory(root, str(stage.relative_to(root))) == plan['expected'], 'stage_missing_or_changed')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.mkdir()  # exclusive claim; EEXIST never replaces even an empty directory
            with open(marker, 'xb') as out:
                out.write(journal['token'].encode())
                out.flush()
                os.fsync(out.fileno())
            sync_dir(target)
            owned = True
            journal['events'].append({'action': 'target_claimed', 'note': plan['note']})
            journal_write(root, transaction, journal)
            if fail_at == 'target_claimed':
                raise Refused('injected_stop_target_claimed')
        if owned:
            copy_owned_tree(root, str(stage.relative_to(root)), plan['desired'], plan['expected'])
        else:
            require(current == plan['expected'], 'existing_target_differs')
        require(target_content(root, plan['desired']) == plan['expected'], 'installed_verification_failed')
        journal['events'].append({'action': 'installed_or_adopted_verified', 'note': plan['note']})
        journal_write(root, transaction, journal)
        if fail_at == 'first_install':
            raise Refused('injected_stop_first_install')
    checkpoint(journal, 'installed_verified', root, transaction, fail_at)
    # Guards are persisted before layout commit; a crash here conservatively
    # protects the old source. Pending payloads and SHA baselines are not altered.
    if journal['state'] is not None:
        atomic(root, SYNC, inside(root, transaction + '/after-sync.json').read_bytes())
    checkpoint(journal, 'state_guarded', root, transaction, fail_at)
    atomic(root, LAYOUT, inside(root, transaction + '/after-layout.json').read_bytes())
    checkpoint(journal, 'manifest_committed', root, transaction, fail_at)
    require(read_json(root, LAYOUT) == journal['manifest'], 'manifest_readback_failed')
    for plan in journal['plans']:
        require(target_content(root, plan['desired']) == plan['expected'], 'postcommit_content_changed')
    checkpoint(journal, 'verified', root, transaction, fail_at)
    # Originals leave the active root only AFTER complete install/manifest readback.
    # iSH lacks exclusive rename: retain TWO verified copies (originals + retired)
    # then unlink only matching individual source files; never rmtree author edits.
    for item in journal['sources']:
        retired_rel = transaction + '/retired/' + item['path']
        retire_original(root, item, retired_rel, journal, transaction)
        require(inventory(root, retired_rel) == item['inventory'], 'retirement_verification_failed')
        journal['events'].append({'action': 'original_retired_verified', 'path': item['path']})
        journal_write(root, transaction, journal)
        if fail_at == 'first_retirement':
            raise Refused('injected_stop_first_retirement')
    checkpoint(journal, 'complete', root, transaction, fail_at)
    return journal

def rollback(root, transaction, journal):
    if journal['phase'] == 'rolled_back':
        return journal
    # Preflight EVERYTHING before moving anything. Edits after migration are never
    # discarded. Copy the workspace and merge such edits manually before rollback.
    for plan in journal['plans']:
        if plan['status'] != 'install':
            continue
        current = target_content(root, plan['desired'])
        evacuated = transaction + '/rollback-installed/' + plan['note']
        if current is not None and current != plan['expected']:
            marker = inside(root, plan['desired'] + '/.longblog-install-token')
            require(marker.is_file() and marker.read_bytes() == journal['token'].encode(), 'rollback_target_has_edits')
            require_owned_partial(root, transaction + '/stage/' + plan['note'], plan['desired'], plan['expected'])
        if current is None and inside(root, evacuated).exists():
            require(target_content(root, evacuated) == plan['expected'], 'rollback_saved_target_has_edits')
    for item in journal['sources'] + journal['before']:
        expected = item['inventory']
        current = inventory(root, item['path'])
        after_rel = transaction + ('/after-layout.json' if item['path'] == LAYOUT else '/after-sync.json')
        after = inventory(root, after_rel) if item in journal['before'] else None
        require(current is None or current == expected or (after is not None and current == after), 'rollback_source_has_edits')
        if expected is not None and current != expected:
            require(inventory(root, transaction + '/originals/' + item['path']) == expected,
                    'rollback_backup_missing_or_changed')
    checkpoint(journal, 'rolling_back', root, transaction, None)
    for plan in journal['plans']:
        if plan['status'] != 'install':
            continue  # Pre-existing identical targets are NEVER removed by rollback.
        target = inside(root, plan['desired'])
        if target.exists():
            retired_rel = transaction + '/rollback-installed/' + plan['note']
            actual = inventory(root, plan['desired'])
            retire_original(root, {'path': plan['desired'], 'inventory': actual}, retired_rel, journal, transaction)
    for item in journal['sources']:
        if not inside(root, item['path']).exists():
            copy_verified(root, transaction + '/originals/' + item['path'], item['path'], item['inventory'])
    for item in journal['before']:
        if item['inventory'] is not None:
            if inventory(root, item['path']) != item['inventory']:
                atomic(root, item['path'], inside(root, transaction + '/originals/' + item['path']).read_bytes())
        else:
            p = inside(root, item['path'])
            if p.exists():
                os.rename(p, inside(root, transaction + '/rolled-back-' + p.name))
                sync_dir(p.parent)
    checkpoint(journal, 'rolled_back', root, transaction, None)
    return journal

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('dry-run', 'apply', 'resume', 'rollback'))
    parser.add_argument('--root', required=True)
    parser.add_argument('--transaction', help='Opaque hex token returned by apply; required for resume/rollback')
    parser.add_argument('--allow-verified-pending', action='store_true',
                        help='Operator has verified remote pending commit; preserve pending and block App replay')
    parser.add_argument('--html-policy', choices=('refuse-edited', 'prefer-html-preserve-md'), default='refuse-edited',
                        help='Explicitly choose original HTML if MD authority cannot be proven; all originals backed up')
    parser.add_argument('--expect-plan', help='Require exact dry-run plan fingerprint before apply')
    parser.add_argument('--fail-at', choices=('preparing', 'staged_verified', 'target_claimed', 'first_install', 'installed_verified',
                        'state_guarded', 'manifest_committed', 'verified', 'first_retirement', 'complete'), help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    token = args.transaction
    try:
        root = root_path(args.root)
        if args.command in ('resume', 'rollback'):
            require(token is not None, 'transaction_required')
            transaction, journal = load_transaction(root, token)
            result = rollback(root, transaction, journal) if args.command == 'rollback' else install(root, transaction, journal, args.fail_at)
        else:
            journal, payloads = build_plan(root, args.allow_verified_pending, args.html_policy)
            fingerprint = digest(canonical_json(journal))
            if args.command == 'dry-run':
                print(json.dumps(dict(summary(journal), plan_fingerprint=fingerprint), ensure_ascii=False))
                return 0
            require(not args.expect_plan or args.expect_plan == fingerprint, 'dry_run_plan_changed')
            if all(p['status'] == 'already_single_source' for p in journal['plans']):
                print(json.dumps(dict(summary(journal), phase='complete', idempotent=True)))
                return 0
            transaction, journal = prepare(root, journal, payloads, args.fail_at)
            token = journal['token']
            result = install(root, transaction, journal, args.fail_at)
        print(json.dumps(dict(summary(result), transaction=token), ensure_ascii=False))
        return 0
    except (Refused, OSError, ValueError, KeyError, TypeError) as exc:
        # Never echo filenames, JSON/body text, payloads or OS exception strings.
        reason = str(exc) if isinstance(exc, Refused) else type(exc).__name__
        output = {'error': reason, 'writes': 'none' if args.command == 'dry-run' else 'inspect_transaction_journal',
                  'secrets_printed': False}
        if not token and args.command != 'dry-run':
            try:
                active = read_json(root, ACTIVE)
                token = active.get('token') if active else None
            except (Refused, OSError, ValueError, KeyError, TypeError, UnboundLocalError):
                pass
        if token:
            output['transaction'] = token
        print(json.dumps(output), file=sys.stderr)
        return 2

if __name__ == '__main__':
    sys.exit(main())
