#!/usr/bin/env python3
"""Bundle the website's pinned fonts and bounded highlight.js language set.
No repository npm install, note access, author script or external runtime load.
"""
from pathlib import Path
import urllib.request
import tarfile
import io
import json
import re
import hashlib
import argparse
import os

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'resources/Reader/vendor'


def package(name, version):
    meta = json.load(urllib.request.urlopen('https://registry.npmjs.org/' + name + '/' + version, timeout=30))
    data = urllib.request.urlopen(meta['dist']['tarball'], timeout=60).read()
    if hashlib.sha1(data).hexdigest() != meta['dist']['shasum']: raise ValueError('npm package digest mismatch')
    archive = tarfile.open(fileobj=io.BytesIO(data), mode='r:gz')
    files = {m.name.removeprefix('package/'): m for m in archive.getmembers() if m.isfile()}
    return meta, lambda path: archive.extractfile(files[path]).read(), files


def fonts():
    packages = [('lxgw-wenkai-screen-webfont', '1.7.0', ['lxgwwenkaiscreen.css']),
                ('@fontsource-variable/eb-garamond', '5.3.0', ['wght.css', 'wght-italic.css']),
                ('@fontsource-variable/jetbrains-mono', '5.2.5', ['wght.css'])]
    manifest, allcss = [], []
    for name, version, styles in packages:
        meta, read, files = package(name, version)
        sub = DEST / 'site-fonts' / name.split('/')[-1]
        sub.mkdir(parents=True, exist_ok=True)
        for license in files:
            if 'LICENSE' in license.upper() or 'OFL' in license.upper(): (sub / Path(license).name).write_bytes(read(license))
        total = 0
        for style in styles:
            css = read(style).decode()
            for ref in set(re.findall(r'url\([\'\"]?([^\)\'\"]+)', css)):
                key = str(Path(style).parent / ref).removeprefix('./')
                if '..' in Path(key).parts or Path(key).is_absolute(): raise ValueError('unsafe font path')
                target = sub / key
                target.parent.mkdir(parents=True, exist_ok=True)
                blob = read(key); target.write_bytes(blob); total += len(blob)
            css = re.sub(r'url\([\'\"]?([^\)\'\"]+)[\'\"]?\)', lambda m: 'url("site-fonts/' + name.split('/')[-1] + '/' + m[1].removeprefix('./') + '")', css)
            allcss.append(css)
        manifest.append({'package': name, 'version': version, 'tarballSHA1': meta['dist']['shasum'], 'fontBytes': total})
    (DEST / 'site-fonts.css').write_text('/* Exact pinned website fonts, bundled for offline use. */\n' + '\n'.join(allcss))
    (DEST / 'SiteFonts-PROVENANCE.json').write_text(json.dumps(manifest, indent=2) + '\n')
    boxicons_dest = DEST / 'site-fonts/boxicons-subset.woff'
    site_root = Path(os.environ.get('LONGBLOG_SITE_ROOT', '')).expanduser() if os.environ.get('LONGBLOG_SITE_ROOT') else None
    if site_root and (site_root / 'public/fonts/boxicons-subset.woff').exists():
        boxicons_dest.write_bytes((site_root / 'public/fonts/boxicons-subset.woff').read_bytes())
    elif not boxicons_dest.exists():
        raise FileNotFoundError('boxicons-subset.woff missing; specify LONGBLOG_SITE_ROOT containing public/fonts/boxicons-subset.woff')


def highlight():
    meta, read, _ = package('highlight.js', '11.12.0')
    source = '/* highlight.js 11.12.0, BSD-3-Clause; site language set only. */\n(function(root){"use strict";\nconst hljs=(()=>{const module={exports:{}};\n' + read('lib/core.js').decode() + '\nreturn module.exports;})();\n'
    for language in ['bash', 'latex', 'python', 'yaml']:
        source += 'hljs.registerLanguage(' + json.dumps(language) + ',(()=>{const module={exports:{}};\n' + read('lib/languages/' + language + '.js').decode() + '\nreturn module.exports;})());\n'
    source += 'root.LBSiteHighlight=hljs;\n})(typeof window!=="undefined"?window:globalThis);\n'
    source = '\n'.join(line.rstrip() for line in source.splitlines()) + '\n'
    (DEST / 'site-highlight.js').write_text(source)
    (DEST / 'Highlight-LICENSE.txt').write_bytes(read('LICENSE'))
    (DEST / 'Highlight-PROVENANCE.json').write_text(json.dumps({'package':'highlight.js','version':'11.12.0','tarballSHA1':meta['dist']['shasum']}, indent=2) + '\n')


if __name__ == '__main__':
    fonts()
    highlight()
    print('Reader website fonts, boxicons and highlight.js bundled with verified npm SHA1')
