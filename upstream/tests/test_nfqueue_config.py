#!/usr/bin/env python3
"""Check the built-in nftables NFQUEUE configuration contract."""
import runpy
from pathlib import Path
import tempfile
import unittest

UPSTREAM = Path(__file__).resolve().parents[1]
FRAGMENT = UPSTREAM / 'e5-mainline.config'
CHECK = runpy.run_path(str(UPSTREAM / 'check-container-support.py'))['config_check']
REQUIRED = ('NET', 'INET', 'IPV6', 'NETFILTER', 'NF_TABLES', 'NF_TABLES_INET',
            'NETFILTER_NETLINK_QUEUE', 'NFT_QUEUE')


class NFQueueConfig(unittest.TestCase):
    def test_fragment_enables_required_features_once(self):
        lines = FRAGMENT.read_text().splitlines()
        for key in REQUIRED:
            with self.subTest(key=key):
                assignments = [line for line in lines if line.startswith('CONFIG_' + key + '=')]
                self.assertEqual(assignments, ['CONFIG_' + key + '=y'])

    def test_built_config_rejects_missing_or_modular_queue(self):
        text = FRAGMENT.read_text()
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / 'config'
            config.write_text(text)
            CHECK(config)
            for key in ('NETFILTER_NETLINK_QUEUE', 'NFT_QUEUE'):
                for value in ('n', 'm'):
                    with self.subTest(key=key, value=value):
                        config.write_text(text.replace('CONFIG_' + key + '=y',
                                                       'CONFIG_' + key + '=' + value))
                        with self.assertRaisesRegex(ValueError, 'CONFIG_' + key + '=y'):
                            CHECK(config)


if __name__ == '__main__':
    unittest.main()
