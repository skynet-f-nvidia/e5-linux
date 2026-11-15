#!/usr/bin/env python3
"""Exercise the bundle image guard without building a firmware image."""
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'make-flash-bundle.sh'
GUARD = SCRIPT.read_text(encoding='utf-8').split('python3 - "$image_source" <<\'PY\'\n', 1)[1].split('\nPY\n', 1)[0]
CONFIG = 'etc/config/attendedsysupgrade'
SAFE = b"config client 'client'\n\toption login_check_for_upgrades '0'\n"


def archive(path, entries):
    with tarfile.open(path, 'w:gz') as tar:
        for name, data, kind, mode in entries:
            info = tarfile.TarInfo(name)
            info.type = kind
            info.mode = mode
            if kind == tarfile.REGTYPE:
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
            else:
                info.linkname = 'target'
                tar.addfile(info)


def entry(name, data=b'', kind=tarfile.REGTYPE, mode=0o644):
    return name, data, kind, mode


class ImageGuard(unittest.TestCase):
    def check_source(self, path, expected):
        result = subprocess.run([sys.executable, '-c', GUARD, str(path)], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, expected, result.stderr)

    def check_archive(self, entries, expected):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'root.tar.gz'
            archive(path, [entry('./sbin/init'), *entries])
            self.check_source(path, expected)

    def test_config_and_absence_are_allowed(self):
        self.check_archive([], True)
        for name in (CONFIG, './' + CONFIG):
            with self.subTest(name=name):
                self.check_archive([entry(name, SAFE)], True)
        self.check_archive([entry(CONFIG, b"# comment\nconfig client client # comment\n option server 'https://example.invalid'\n option login_check_for_upgrades 0 # comment\nconfig other 'other'\n option setting 'value'\n")], True)

    def test_unsafe_or_ambiguous_config_is_rejected(self):
        cases = [
            b"config client client\n option login_check_for_upgrades 1\n",
            b"config client client\n option login_check_for_upgrades 0\n option login_check_for_upgrades 1\n",
            SAFE + SAFE,
            b"config other client\n option login_check_for_upgrades 0\n",
            b"config client other\n option login_check_for_upgrades 0\n",
            b"config client client\n list login_check_for_upgrades 0\n",
            b"config client client\n option login_check_for_upgrades '0\n",
            SAFE + b"bad directive\n",
            SAFE + b"\xff",
        ]
        for data in cases:
            with self.subTest(data=data):
                self.check_archive([entry(CONFIG, data)], False)
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.DIRTYPE):
            with self.subTest(kind=kind):
                self.check_archive([entry(CONFIG, kind=kind)], False)
        self.check_archive([entry(CONFIG, SAFE, mode=0o755)], False)
        self.check_archive([entry(CONFIG, SAFE), entry('./' + CONFIG, SAFE)], False)

    def test_components_and_device_files_remain_forbidden(self):
        paths = ['usr/bin/attendedsysupgrade', 'usr/share/luci/menu.d/luci-app-attendedsysupgrade.json',
                 'usr/share/rpcd/acl.d/luci-app-attendedsysupgrade.json',
                 CONFIG + '.bak', CONFIG + '/component', 'prefix/' + CONFIG,
                 'lib/firmware/wcnmodem.bin', 'lib/firmware/gnssmodem', 'lib/firmware/l_agdsp',
                 'lib/firmware/wifi_board', 'lib/firmware/sprd/board', 'opt/e5/android/file',
                 'etc/e5/install.conf', 'mnt/vendor/file']
        for path in paths:
            with self.subTest(path=path):
                self.check_archive([entry(CONFIG, SAFE), entry(path)], False)

    def test_extracted_image_tree_uses_same_guard(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root/'sbin').mkdir()
            (root/'sbin/init').write_text('init')
            config = root/CONFIG
            config.parent.mkdir(parents=True)
            config.write_bytes(SAFE)
            self.check_source(root, True)
            config.write_text("config client client\n option login_check_for_upgrades 1\n")
            self.check_source(root, False)
            config.write_bytes(SAFE)
            component = root/'usr/bin/attendedsysupgrade'
            component.parent.mkdir(parents=True)
            component.write_text('component')
            self.check_source(root, False)
            component.unlink()
            device = root/'lib/firmware/sprd/board'
            device.parent.mkdir(parents=True)
            device.write_text('device')
            self.check_source(root, False)

    def test_missing_init_fails_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.check_source(root, False)
            path = root / 'root.tar.gz'
            archive(path, [entry(CONFIG, SAFE)])
            self.check_source(path, False)


if __name__ == '__main__':
    unittest.main()
