#!/usr/bin/env python3
"""Record the files the device-profile staging wrote into an image root.

    tools/stage-manifest.py --root ROOT

openwrt/build-rootfs.sh calls this right after devices/e5/stage.py.  The staging
rewrites part of the screen tree on purpose and the E5 profile prunes the
bundled calculator and the LuCI SMS app (devices/t551m/ui-cleanup.py), so a plain
source-to-image comparison cannot describe the result.  The release audit
(tools/ci-release.py) then checks these files against this record and everything
else against its source.
"""
import argparse
import hashlib
import json
import runpy
from pathlib import Path

# the trees the device profile and the info screen stagers write
PREFIXES = (
    'usr/share/e5-infoscreen/',
    'usr/libexec/e5-infoscreen/',
    'usr/libexec/unisoc-modem/',
    'usr/libexec/e5-',
    'usr/share/luci/',
    'usr/share/rpcd/',
    'www/',
    'opt/e5/',
    'etc/e5-infoscreen/',
    'etc/init.d/',
    'etc/hotplug.d/',
    'etc/modules.d/',
)
RECORD = 'etc/e5/root-manifest.json'


def obsolete():
    # files the E5 profile removes on purpose (devices/t551m/ui-cleanup.py);
    # the record names them so the audit sees a deliberate removal, not a
    # file someone forgot to install
    top = Path(__file__).resolve().parents[1]
    return sorted(runpy.run_path(str(top / 'devices/t551m/ui-cleanup.py'))['OBSOLETE'])


def collect(root):
    record = {}
    for prefix in PREFIXES:
        base = root / prefix
        if not base.exists():
            continue
        for path in sorted(base.rglob('*')):
            if path.is_file() and not path.is_symlink():
                record[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    record = collect(root)
    out = root / RECORD
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({'schema': 1, 'files': record, 'removed': obsolete()},
                              indent=2, sort_keys=True) + '\n')
    print(f'staged-file record: {len(record)} files -> {RECORD}')


if __name__ == '__main__':
    main()
