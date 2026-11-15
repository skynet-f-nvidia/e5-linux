"""Exercise updater authentication without SSH or private key access."""
import os
from pathlib import Path
import runpy
import sys
import unittest
from unittest.mock import MagicMock, patch

UPDATER = Path(__file__).resolve().parents[1] / 'e5-update.py'
main = runpy.run_path(str(UPDATER))['main']


class StopBeforeDeviceCommands(Exception):
    pass


class UpdateAuthentication(unittest.TestCase):
    def run_updater(self, extra_args=(), env=None, gui=None):
        client = MagicMock()
        paramiko = MagicMock()
        paramiko.SSHClient.return_value = client
        args = ['e5-update.py', '--package', 'unused-package', '--host', 'device.invalid',
                '--raw-size', '1', '--raw-sha256', 'unused', *extra_args]
        with patch.dict(sys.modules, {'paramiko': paramiko}), \
             patch.object(sys, 'argv', args), \
             patch.dict(os.environ, env or {}, clear=True), \
             patch.object(Path, 'exists', return_value=False), \
             patch.dict(main.__globals__, {'GUI': gui, 'execute': MagicMock(side_effect=StopBeforeDeviceCommands)}):
            with self.assertRaises(StopBeforeDeviceCommands):
                main()
        client.close.assert_called_once_with()
        return client

    def test_cli_password_authentication_and_keepalive(self):
        client = self.run_updater(env={'E5_TELNET_PASS': 'test-password'})
        client.connect.assert_called_once_with(
            'device.invalid', username='root', **{'password': 'test-password'},
            look_for_keys=False, allow_agent=False, timeout=30, banner_timeout=60, auth_timeout=60)
        client.get_transport.return_value.set_keepalive.assert_called_once_with(15)

    def test_cli_identity_file_authentication_without_password_and_keepalive(self):
        identity = r'C:\example folder\id_test'
        client = self.run_updater(extra_args=['--identity-file', identity])
        client.connect.assert_called_once_with(
            'device.invalid', username='root', key_filename=identity,
            look_for_keys=False, allow_agent=False, timeout=30, banner_timeout=60, auth_timeout=60)
        client.get_transport.return_value.set_keepalive.assert_called_once_with(15)

    def test_gui_keeps_its_own_connection_path_even_with_identity_option(self):
        gui = MagicMock()
        setattr(gui, 'password', 'gui-test-password')
        client = self.run_updater(extra_args=['--identity-file', 'unused-key'], gui=gui)
        gui.connect_ssh.assert_called_once_with(client, 'device.invalid', 'gui-test-password')
        gui.validate_ssh.assert_called_once_with(client)
        client.connect.assert_not_called()
        client.get_transport.assert_not_called()


if __name__ == '__main__':
    unittest.main()
