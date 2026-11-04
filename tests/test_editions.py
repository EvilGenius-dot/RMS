"""Full-only upgrades use real installer download/rollback transactions in a sandbox."""
import subprocess
import tempfile
from pathlib import Path
import unittest
import test_install as transaction
from test_install import HARNESS, SHELLS, INSTALLER, elf


class EditionTests(unittest.TestCase):
    setup_case = transaction.InstallTests.setup_case
    assert_original = transaction.InstallTests.assert_original
    def test_full_installs_with_same_service_path_on_every_architecture(self):
        for arch, payload in [('x64', elf()), ('arm', elf(40, 1)), ('arm64', elf(183, 2))]:
            for shell in SHELLS:
                with self.subTest(arch=arch, shell=shell), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    env = self.setup_case(root, payload=payload, arch=arch)
                    harness = HARNESS.replace('    event download\n', '    printf \'%s\\n\' "$1" > "$TEST_ROOT/url"\n    event download\n')
                    result = subprocess.run([shell, '-c', harness], env=env, input='1\n', text=True, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual((root/'install dir/rms').read_bytes(), payload)
                    self.assertIn('完整版', result.stdout)
                    self.assertTrue((root/'url').read_text().strip().endswith('/rms'))

    def test_installer_has_no_edition_prompt_or_lite_download(self):
        source = INSTALLER.read_text()
        self.assertNotIn('select_edition', source)
        self.assertNotIn('rms-lite', source)
        self.assertNotIn('请选择 RMS 版本', source)

    def test_full_upgrade_failure_restores_previous_binary(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);env=self.setup_case(root,mode='start_fail')
                harness=HARNESS
                result=subprocess.run([shell,'-c',harness],env=env,input='1\n',text=True,capture_output=True,timeout=10)
                self.assertNotEqual(result.returncode,0)
                self.assert_original(root)
                self.assertTrue((root/'running').exists())


if __name__=='__main__':unittest.main()
