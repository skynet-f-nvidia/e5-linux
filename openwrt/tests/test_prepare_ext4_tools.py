import hashlib
import importlib.util
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / 'prepare-ext4-tools.py'
spec = importlib.util.spec_from_file_location('prepare_ext4_tools', SCRIPT)
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


def elf(label):
    data = bytearray(b'\x7fELF\x02\x01' + bytes(14))
    data[18:20] = (183).to_bytes(2, 'little')
    return bytes(data) + label.encode()


class ImagePathTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'root'
        self.root.mkdir()
        (self.root / 'usr/bin').mkdir(parents=True)
        try:
            (self.root / 'probe').symlink_to('usr', target_is_directory=True)
        except (OSError, NotImplementedError) as exc:
            self.skipTest('symlinks unavailable: ' + str(exc))

    def link(self, name, target, directory=False):
        (self.root / name).symlink_to(target, target_is_directory=directory)

    def test_absolute_and_relative_chains_include_directory_links(self):
        real = self.root / 'usr/bin/util-linux-flock'
        real.write_bytes(b'flock')
        self.link('usr/bin/flock', '/aliases/next')
        self.link('aliases', 'usr/bin', directory=True)
        self.link('usr/bin/next', '../bin/util-linux-flock')
        self.assertEqual(prepare.image_path(self.root, 'usr/bin/flock'), real)
        self.assertEqual(prepare.image_path(self.root, 'probe/bin/flock'), real)

    def test_escape_cycle_and_missing_are_errors(self):
        self.link('usr/bin/escape', '../../../outside')
        self.link('usr/bin/absolute-escape', '/../../outside')
        self.link('usr/bin/cycle-a', 'cycle-b')
        self.link('usr/bin/cycle-b', 'cycle-a')
        self.link('usr/bin/dangling', '/missing/file')
        for name in ('escape', 'absolute-escape', 'cycle-a'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                prepare.image_path(self.root, 'usr/bin/' + name)
        for name in ('dangling', 'absent'):
            with self.subTest(name=name), self.assertRaises(FileNotFoundError):
                prepare.image_path(self.root, 'usr/bin/' + name)

    def test_build_preserves_requested_names_and_traces_linked_dependencies(self):
        for name in ('usr/sbin/e2fsck', 'usr/sbin/resize2fs',
                     'lib/ld-musl-aarch64.so.1', 'usr/bin/util-linux-flock',
                     'usr/lib/libactual.so'):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(elf(name))
        self.link('usr/bin/flock', '/usr/bin/util-linux-flock')
        self.link('lib/libflock.so', '/usr/lib/libactual.so')
        calls = []

        def readelf(command, **kwargs):
            source = Path(command[-1])
            calls.append(source.relative_to(self.root).as_posix())
            return ' 0x1 (NEEDED) Shared library: [libflock.so]\n' if source.name == 'util-linux-flock' else ''

        output = Path(self.tmp.name) / 'bundle.tar'
        with mock.patch.object(prepare.subprocess, 'check_output', side_effect=readelf):
            prepare.build(self.root, output, include_lock=True)
        with tarfile.open(output) as archive:
            names = archive.getnames()
            flock = archive.extractfile('usr/bin/flock').read()
            dependency = archive.extractfile('lib/libflock.so').read()
            manifest = json.load(archive.extractfile('manifest.json'))
            self.assertTrue(archive.getmember('usr/bin/flock').isfile())
        self.assertNotIn('usr/bin/util-linux-flock', names)
        self.assertNotIn('usr/lib/libactual.so', names)
        self.assertEqual(flock, elf('usr/bin/util-linux-flock'))
        self.assertEqual(dependency, elf('usr/lib/libactual.so'))
        self.assertEqual(manifest['sha256']['usr/bin/flock'], hashlib.sha256(flock).hexdigest())
        self.assertIn('usr/bin/util-linux-flock', calls)
        self.assertIn('usr/lib/libactual.so', calls)

    def test_missing_alternative_uses_package_binary_but_dangling_link_fails(self):
        for name in ('usr/sbin/e2fsck', 'usr/sbin/resize2fs',
                     'lib/ld-musl-aarch64.so.1', 'usr/bin/util-linux-flock'):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(elf(name))
        output = Path(self.tmp.name) / 'bundle.tar'
        with mock.patch.object(prepare.subprocess, 'check_output', return_value=''):
            prepare.build(self.root, output, include_lock=True)
            with tarfile.open(output) as archive:
                self.assertEqual(archive.extractfile('usr/bin/flock').read(),
                                 elf('usr/bin/util-linux-flock'))
            self.link('usr/bin/flock', '/missing/flock')
            with self.assertRaises(FileNotFoundError):
                prepare.build(self.root, output, include_lock=True)


if __name__ == '__main__':
    unittest.main()
