"""Edition choices use real installer download/rollback transactions in a sandbox."""
import subprocess
import tempfile
from pathlib import Path
import unittest
import test_install as transaction
from test_install import HARNESS, SHELLS, INSTALLER, elf


class EditionTests(unittest.TestCase):
    setup_case = transaction.InstallTests.setup_case
    assert_original = transaction.InstallTests.assert_original
    def test_lite_installs_with_same_service_path_on_every_architecture(self):
        for arch, payload in [('x64', elf()), ('arm', elf(40, 1)), ('arm64', elf(183, 2))]:
            for shell in SHELLS:
                with self.subTest(arch=arch, shell=shell), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    env = self.setup_case(root, payload=payload, arch=arch)
                    harness = HARNESS.replace('    event download\n', '    printf \'%s\\n\' "$1" > "$TEST_ROOT/url"\n    event download\n').replace('install_app\n', 'TARGET_ROUTE_EXEC="${TARGET_ROUTE_EXEC}-lite"\ninstall_app\n')
                    result = subprocess.run([shell, '-c', harness], env=env, input='1\n', text=True, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual((root/'install dir/rms').read_bytes(), payload)
                    self.assertIn('精简版', result.stdout)
                    self.assertTrue((root/'url').read_text().strip().endswith('/rms-lite'))

    def test_choice_is_repeatable_and_invalid_choice_does_not_download(self):
        for shell in SHELLS:
            for answer, suffix, success in [('1\n', '/rms', True), ('\n', '/rms', True), ('2\n', '/rms-lite', True), ('3\n', '', False), ('', '', False)]:
                with self.subTest(shell=shell, answer=answer), tempfile.TemporaryDirectory() as tmp:
                    root=Path(tmp)
                    lib=root/'lib.sh';lib.write_text(INSTALLER.read_text().removesuffix('main "$@"\n'))
                    script='. "$1"; TARGET_ROUTE_EXEC="${ROUTE_EXEC_1}-lite"; select_edition || exit 1; printf "URL=%s\\n" "$TARGET_ROUTE_EXEC"'
                    result=subprocess.run([shell,'-c',script,'test',str(lib)],input=answer,text=True,capture_output=True)
                    self.assertEqual(result.returncode==0,success,result.stdout)
                    if success:self.assertTrue(result.stdout.rstrip().endswith(suffix),result.stdout)

    def test_lite_start_failure_restores_full_binary(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);env=self.setup_case(root,mode='start_fail')
                harness=HARNESS.replace('install_app\n','TARGET_ROUTE_EXEC="${TARGET_ROUTE_EXEC}-lite"\ninstall_app\n')
                result=subprocess.run([shell,'-c',harness],env=env,input='1\n',text=True,capture_output=True,timeout=10)
                self.assertNotEqual(result.returncode,0)
                self.assert_original(root)
                self.assertTrue((root/'running').exists())


if __name__=='__main__':unittest.main()
