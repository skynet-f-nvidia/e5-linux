#!/usr/bin/env python3
"""Run the image updater's config migration against disposable directories."""
from pathlib import Path
import os
import subprocess
import tarfile
import tempfile

top = Path(__file__).resolve().parents[2]
source = (top / 'openwrt/device-install-image.sh').read_text()
start = source.index('keep_config() {')
function = source[start:source.index('\n}\n', start) + 3]
with tempfile.TemporaryDirectory() as directory:
    base = Path(directory)
    for bundled in (True, False):
        old, new = base / ('old-' + str(bundled)), base / ('new-' + str(bundled))
        def put(root, name, text):
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        phone = 'etc/e5-infoscreen/plugins/phone/'
        for name, text in {
            'etc/config/network': 'user network', 'etc/shadow': 'user password',
            'etc/e5/contacts.json': 'user contacts', 'etc/e5/image-version': 'old',
            'etc/e5/sim-radio': '0 1\n', 'etc/e5/release.json': 'old release',
            'etc/e5-infoscreen/plugins/other/user.json': 'other app data',
            phone + 'phone.js': 'old phone', phone + 'manifest.json': 'old manifest',
            'etc/e5-sounds/notification.wav': 'own ringtone bytes',
            'etc/e5-cpu-voltage.json': '{"offset":3125}',
            'etc/bluetooth/main.conf': '[General]\nName=User Bluetooth\n',
            'etc/unisoc-modem/apn-profiles.json': 'own per-SIM APN profiles',
            'etc/tailscale/tailscaled.state': 'tailscale node state',
            'etc/honk/config.dae': 'honk routing config',
            'etc/honk/data/state/honk.db': 'honk state',
            'root/.ssh/authorized_keys': 'ssh-ed25519 userkey',
        }.items():
            put(old, name, text)
        # honk records boot enablement in an rc.d link, outside /etc/honk.
        put(old, 'etc/init.d/honk', 'old init')
        put(new, 'etc/init.d/honk', 'new init')
        (new / 'etc/rc.d').mkdir(parents=True, exist_ok=True)
        enabled = old / 'etc/rc.d/S99honk'
        enabled.parent.mkdir(parents=True, exist_ok=True)
        symlink = False
        if bundled:
            try:
                enabled.symlink_to('../init.d/honk')
                symlink = True
            except OSError:  # Windows without symlink privileges
                enabled.write_text('enabled')
        for name in ('image-version', 'image-form', 'build-time', 'release.json'):
            put(new, 'etc/e5/' + name, 'new ' + name)
        if bundled:
            put(new, phone + 'phone.js', 'new phone')
            put(new, phone + 'manifest.json', 'new manifest')
        script = function.replace('/tmp/e5-img.', str(base / 'e5-img.'))
        subprocess.run(['sh', '-ec', script + '\nkeep_config "$1" "$2"',
                        'test', str(old), str(new)], check=True)
        assert (new / (phone + 'phone.js')).read_text() == ('new phone' if bundled else 'old phone')
        assert (new / 'etc/e5/contacts.json').read_text() == 'user contacts'
        assert (new / 'etc/e5/sim-radio').read_text() == '0 1\n'
        assert (new / 'etc/config/network').read_text() == 'user network'
        assert (new / 'etc/shadow').read_text() == 'user password'
        assert (new / 'etc/e5-infoscreen/plugins/other/user.json').read_text() == 'other app data'
        assert (new / 'etc/e5-sounds/notification.wav').read_text() == 'own ringtone bytes'
        assert (new / 'etc/e5-cpu-voltage.json').read_text() == '{"offset":3125}'
        assert (new / 'etc/bluetooth/main.conf').read_text() == '[General]\nName=User Bluetooth\n'
        assert (new / 'etc/unisoc-modem/apn-profiles.json').read_text() == 'own per-SIM APN profiles'
        assert (new / 'etc/tailscale/tailscaled.state').read_text() == 'tailscale node state'
        assert (new / 'etc/honk/config.dae').read_text() == 'honk routing config'
        assert (new / 'etc/honk/data/state/honk.db').read_text() == 'honk state'
        restored = new / 'etc/rc.d/S99honk'
        assert restored.exists() == bundled
        if bundled and symlink:
            assert restored.is_symlink() and str(restored.readlink()) == '../init.d/honk'
        elif bundled:
            assert restored.read_text() == 'enabled'
        assert (new / 'root/.ssh/authorized_keys').read_text() == 'ssh-ed25519 userkey'
        assert (new / 'etc/e5/image-version').read_text() == 'new image-version'
        assert (new / 'etc/e5/release.json').read_text() == 'new release.json'
        assert not list(base.glob('e5-img.phone.*'))
# The SD updater builds a tar archive instead of calling keep_config.
if os.name != 'nt':
    stage = (top / 'openwrt/device-stage-part-update.sh').read_text()
    collect = stage[stage.index('settings='):stage.index('tar -cf /.e5-update/settings.tar')]
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for name in ('etc/init.d/honk', 'etc/honk/config.dae', 'etc/tailscale/tailscaled.state'):
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture')
        link = root / 'etc/rc.d/S99honk'
        link.parent.mkdir(parents=True)
        link.symlink_to('../init.d/honk')
        result = subprocess.run(['sh', '-ec', collect + '\nprintf "%s" "$settings"'],
                                cwd=root, text=True, capture_output=True, check=True)
        names = result.stdout.split()
        assert 'etc/rc.d/S99honk' in names
        archive = root / 'settings.tar'
        with tarfile.open(archive, 'w') as tar:
            for name in names:
                tar.add(root / name, arcname=name)
        with tarfile.open(archive) as tar:
            member = tar.getmember('etc/rc.d/S99honk')
            assert member.issym() and member.linkname == '../init.d/honk'
            assert tar.getmember('etc/tailscale/tailscaled.state').isfile()
print('PASS: configuration, Tailscale state and honk boot status are preserved')
