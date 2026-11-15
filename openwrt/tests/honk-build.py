#!/usr/bin/env python3
"""Exercise the rootfs builder's pinned honk staging with real release archives."""
import hashlib
import os
from pathlib import Path
import tempfile
import unittest

TOP = Path(__file__).resolve().parents[2]
BUILDER = (TOP / 'openwrt/build-rootfs.sh').read_text(encoding='utf-8')
ASSET = os.environ.get('E5_HONK_TEST_ASSET')
SOURCE = os.environ.get('E5_HONK_TEST_SOURCE')


@unittest.skipUnless(ASSET and SOURCE, 'set E5_HONK_TEST_ASSET and E5_HONK_TEST_SOURCE')
class HonkStaging(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for file, digest in ((ASSET, '5e4c0359950e0f19fac53e31ef9ffbe9f0aafca92331c3fa81e5b56212950a6e'),
                             (SOURCE, '6573520ef94805de8a2f95bf0f449392c8c46f4340f9e69ee64553ef8a85e137')):
            self.assertEqual(hashlib.sha256(Path(file).read_bytes()).hexdigest(), digest)
        start = BUILDER.index('python3 - <<PY\nfrom pathlib import Path\nimport tarfile')
        self.stage = BUILDER[start:].split('\nPY\n', 1)[0].split('\n', 1)[1]
        self.stage = self.stage.replace('/build/root', self.root.as_posix())
        self.stage = self.stage.replace('/in/honk-core.tar.gz', Path(ASSET).as_posix())
        self.stage = self.stage.replace('/in/honk-source.tar.gz', Path(SOURCE).as_posix())

    def test_official_components_stage_without_package_database(self):
        exec(self.stage, {})
        binary = (self.root / 'usr/bin/honk-core').read_bytes()
        self.assertEqual(binary[:4], b'\x7fELF')
        self.assertEqual(int.from_bytes(binary[18:20], 'little'), 183)  # AArch64
        for path in ('etc/init.d/honk', 'etc/config/honk', 'etc/honk/config.dae',
                     'www/luci-static/resources/view/honk/main.js',
                     'www/luci-static/resources/daeuniverse/service.js',
                     'usr/share/luci/menu.d/luci-app-honk.json',
                     'usr/share/rpcd/acl.d/luci-app-honk.json',
                     'usr/libexec/daeuniverse-pkg', 'usr/share/licenses/honk/LICENSE'):
            self.assertTrue((self.root / path).is_file(), path)
        self.assertFalse((self.root / 'lib/apk/db/installed').exists())
        self.assertFalse((self.root / 'usr/bin/dae').exists())
        with self.assertRaisesRegex(ValueError, 'destination already exists'):
            exec(self.stage, {})


if __name__ == '__main__':
    unittest.main(verbosity=2)
