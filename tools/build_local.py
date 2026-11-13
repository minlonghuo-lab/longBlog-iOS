#!/usr/bin/env python3
"""Compile serially on iSH (parallel clang can leave empty .o), then run ios-dev mk.py.
Usage: python3 tools/build_local.py [path/to/ios-dev/scripts/mk.py]
"""
import glob
import os
from pathlib import Path
import subprocess
import sys
import time
import yaml

root = Path(__file__).resolve().parent.parent
config = yaml.safe_load((root / 'project.yaml').read_text())
sdk = Path(config['sdk']).expanduser()
objects = root / 'build' / 'obj'
objects.mkdir(parents=True, exist_ok=True)
flags = ['clang', '-target', f"arm64-apple-ios{config['min_ios']}", '-isysroot', str(sdk),
         '-F', str(sdk / 'System/Library/SubFrameworks'), '-fobjc-arc', '-I', str(root / 'src')]
flags += config.get('cflags', [])
hdrs = list((root / 'src').glob('*.h'))
newest_hdr = max([h.stat().st_mtime for h in hdrs]) if hdrs else 0
for pattern in config['sources']:
    for source in sorted(glob.glob(str(root / pattern))):
        obj = objects / (os.path.relpath(source, root).replace('/', '_') + '.o')
        src_time = max(os.path.getmtime(source), newest_hdr)
        if obj.exists() and obj.stat().st_size > 0 and obj.stat().st_mtime >= src_time:
            continue
        success = False
        for attempt in range(4):
            if obj.exists():
                obj.unlink()
            result = subprocess.run(flags + ['-c', source, '-o', str(obj)], check=False)
            if result.returncode == 0 and obj.exists() and obj.stat().st_size > 0:
                os.utime(obj, (src_time + 1, src_time + 1))
                success = True
                break
            if obj.exists():
                obj.unlink()
        if not success:
            raise SystemExit(f'Empty object file from clang for {source}; rerun this script.')

# Touch all valid .o files to be newer than newest header and source, preventing mk.py parallel recompile
future_time = time.time() + 300
for o in objects.glob('*.o'):
    if o.stat().st_size > 0:
        os.utime(o, (future_time, future_time))

mk = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('/var/minis/skills/ios-dev/scripts/mk.py')
subprocess.run([sys.executable, str(mk), str(root)], check=True)
