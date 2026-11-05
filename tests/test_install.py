"""Run installer transactions in isolated directories, without touching services.

Usage: python3 -m unittest discover -s tests -v
Uses sh, bash and dash when available. RMS processes and system changes are mocked;
downloads, backups, renames, traps and ELF checks use actual files.
"""
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import tempfile
import time
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "install.sh"
SHELLS = [shutil.which(name) for name in ("sh", "bash", "dash")]
SHELLS = [path for path in SHELLS if path]
HARNESS = r'''
. "$TEST_ROOT/library.sh"
PATH_RMS="$TEST_ROOT/install dir"
PATH_BIN="$PATH_RMS/rms"
PATH_BIN_BAK="$PATH_RMS/rms.bak"
PATH_NOHUP="$PATH_RMS/nohup.out"
PATH_ERR="$PATH_RMS/err.log"
TARGET_ROUTE=https://example.invalid
case "$TEST_ARCH" in
    arm) TARGET_ROUTE_EXEC="$ROUTE_EXEC_2" ;;
    arm64) TARGET_ROUTE_EXEC="$ROUTE_EXEC_3" ;;
    *) TARGET_ROUTE_EXEC="$ROUTE_EXEC_1" ;;
esac
event() { printf '%s\n' "$1" >> "$TEST_ROOT/events"; }
check_process() { [ -f "$TEST_ROOT/running" ]; }
check_downloader() { [ "$TEST_MODE" != no_downloader ]; }
disable_firewall() { event firewall; }
change_limit() { event limits; }
sleep() { :; }
download_file() {
    event download
    if check_process rms; then event download-running; else event download-stopped; fi
    command cp "$TEST_ROOT/download" "$2" || return 1
    case "$TEST_MODE" in
        download_fail) return 1 ;;
        download_wait) event waiting; while :; do command sleep 0.05; done ;;
    esac
}
cp() {
    event backup
    if check_process rms; then event backup-running; fi
    [ "$TEST_MODE" != backup_fail ] || return 1
    command cp "$@"
}
chmod() {
    case "$TEST_MODE:$*" in chmod_fail:*.rms-install/rms) return 1 ;; esac
    command chmod "$@"
}
mv() {
    case "$2" in
        */.rms-install/previous)
            event save-backup
            [ "$TEST_MODE" != save_backup_fail ] || return 1 ;;
        */.rms-install/rms)
            event replace
            [ "$TEST_MODE" != replace_fail ] || return 1 ;;
        */rms.bak)
            event restore
            [ "$TEST_MODE" != restore_fail ] || return 1 ;;
    esac
    command mv "$@"
}
stop() {
    event stop
    [ "$TEST_MODE" != stop_fail ] || return 1
    [ "$TEST_MODE" != stop_still_running ] || return 0
    if [ "$TEST_MODE" = recovery_stop_fail ] && [ -f "$TEST_ROOT/started" ]; then
        return 1
    fi
    command rm -f "$TEST_ROOT/running"
    [ "$TEST_MODE" != stop_partial_fail ] || return 1
}
start() {
    if cmp -s "$PATH_BIN" "$TEST_ROOT/old"; then
        event start-old
        [ "$TEST_MODE" != old_start_fail ] || return 1
    else
        event start-new
        touch "$TEST_ROOT/started"
        case "$TEST_MODE" in
            start_fail|restore_fail|old_start_fail) return 1 ;;
            immediate_crash) return 0 ;;
            recovery_stop_fail) touch "$TEST_ROOT/running"; return 1 ;;
            start_wait) event waiting; while :; do command sleep 0.05; done ;;
        esac
    fi
    touch "$TEST_ROOT/running"
}
install_app
'''


def elf(machine=62, elf_class=2):
    header = bytearray(64)
    header[:7] = b"\x7fELF" + bytes([elf_class, 1, 1])
    struct.pack_into("<HHI", header, 16, 2, machine, 1)
    return bytes(header) + b"new executable fixture" * 128


class InstallTests(unittest.TestCase):
    def setup_case(self, root, mode="ok", payload=None, installed=True,
                   running=True, arch="x64"):
        library = INSTALLER.read_text()
        assert library.endswith('main "$@"\n')
        (root / "library.sh").write_text(library.removesuffix('main "$@"\n'))
        install = root / "install dir"
        install.mkdir()
        (root / "old").write_bytes(b"old executable fixture")
        if installed:
            shutil.copy(root / "old", install / "rms")
            (install / "rms").chmod(0o755)
        if running:
            (root / "running").touch()
        (root / "download").write_bytes(elf() if payload is None else payload)
        (root / "events").touch()
        return dict(os.environ, TEST_ROOT=str(root), TEST_MODE=mode, TEST_ARCH=arch)

    def run_case(self, mode="ok", payload=None, installed=True, running=True,
                 arch="x64", answer="1\n", prepare=None, verify=None):
        for shell in SHELLS:
            with self.subTest(shell=shell, mode=mode), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                env = self.setup_case(root, mode, payload, installed, running, arch)
                if prepare:
                    prepare(root)
                if (root / "bin").is_dir():
                    env["PATH"] = str(root / "bin") + os.pathsep + env["PATH"]
                if (root / "isolated-bin").is_dir():
                    env["PATH"] = str(root / "isolated-bin")
                env["REAL_HEXDUMP"] = shutil.which("hexdump") or ""
                result = subprocess.run([shell, "-c", HARNESS], env=env,
                                        input=answer, text=True, capture_output=True, timeout=10)
                events = (root / "events").read_text().splitlines()
                verify(root, result, events)
                if mode != "locked":
                    self.assertFalse((root / "install dir/.rms-install").exists())

    def assert_original(self, root):
        self.assertEqual((root / "install dir/rms").read_bytes(), (root / "old").read_bytes())

    def test_running_update_order_and_backup(self):
        def verify(root, result, events):
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(events, ["download", "download-running", "backup", "backup-running",
                                      "save-backup", "firewall", "limits", "stop", "replace", "start-new"])
            self.assertEqual((root / "install dir/rms").read_bytes(), elf())
            self.assertEqual((root / "install dir/rms.bak").read_bytes(), (root / "old").read_bytes())
            self.assertEqual((root / "install dir/rms").stat().st_mode & 0o777, 0o755)
            self.assertTrue((root / "running").exists())
            self.assertEqual((root / "install dir/local.conf").read_text(), "keep configuration")
        self.run_case(prepare=lambda r: (r / "install dir/local.conf").write_text("keep configuration"),
                      verify=verify)

    def test_supported_architectures(self):
        for arch, payload in [("arm", elf(40, 1)), ("arm64", elf(183, 2))]:
            with self.subTest(arch=arch):
                self.run_case(arch=arch, payload=payload,
                              verify=lambda r, p, e: self.assertEqual(p.returncode, 0, p.stdout))

    @unittest.skipUnless(shutil.which("hexdump"), "requires hexdump")
    def test_silent_od_falls_back_to_hexdump_without_weakening_validation(self):
        def prepare(root):
            binaries = root / "bin"
            binaries.mkdir()
            (binaries / "od").write_text("#!/bin/sh\nexit 0\n")
            (binaries / "hexdump").write_text(
                '#!/bin/sh\nprintf "called\\n" >> "$TEST_ROOT/hexdump-calls"\n'
                'exec "$REAL_HEXDUMP" "$@"\n')
            for path in binaries.iterdir():
                path.chmod(0o755)

        def valid(root, result, events):
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((root / "hexdump-calls").exists())
            self.assertEqual((root / "install dir/rms").read_bytes(), elf(183, 2))

        def invalid(root, result, events):
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((root / "hexdump-calls").exists())
            self.assertNotIn("backup", events)
            self.assertNotIn("stop", events)
            self.assert_original(root)

        self.run_case(arch="arm64", payload=elf(183, 2), prepare=prepare, verify=valid)
        for payload in (elf(62, 2), elf(183, 2)[:20], b"<html>not an ELF</html>"):
            with self.subTest(payload=payload[:20]):
                self.run_case(arch="arm64", payload=payload, prepare=prepare, verify=invalid)

    def test_failed_readers_do_not_replace_running_installation(self):
        def prepare(root):
            binaries = root / "bin"
            binaries.mkdir()
            (binaries / "od").write_text("#!/bin/sh\nexit 0\n")
            (binaries / "hexdump").write_text("#!/bin/sh\nexit 1\n")
            for path in binaries.iterdir():
                path.chmod(0o755)

        def verify(root, result, events):
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("backup", events)
            self.assertNotIn("stop", events)
            self.assert_original(root)

        self.run_case(arch="arm64", payload=elf(183, 2), prepare=prepare, verify=verify)

    @unittest.skipUnless(shutil.which("hexdump"), "requires hexdump")
    def test_hexdump_alone_is_sufficient(self):
        def prepare(root):
            binaries = root / "isolated-bin"
            binaries.mkdir()
            for name in ("id", "uname", "mkdir", "chmod", "touch", "rm", "mv", "cp",
                         "cat", "grep", "sed", "sleep", "ps", "awk", "tr", "cmp", "hexdump"):
                target = shutil.which(name)
                if target:
                    (binaries / name).symlink_to(target)

        def verify(root, result, events):
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((root / "install dir/rms").read_bytes(), elf(183, 2))

        self.run_case(arch="arm64", payload=elf(183, 2), prepare=prepare, verify=verify)

    def test_preparation_failures_never_stop_old_service(self):
        def verify(root, result, events):
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("stop", events)
            self.assertNotIn("replace", events)
            self.assertTrue((root / "running").exists())
            self.assert_original(root)
        for mode in ["download_fail", "backup_fail", "save_backup_fail", "chmod_fail", "no_downloader"]:
            self.run_case(mode=mode, verify=verify)

    def test_invalid_downloads_never_stop_old_service(self):
        def verify(root, result, events):
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("stop", events)
            self.assertNotIn("backup", events)
            self.assertTrue((root / "running").exists())
            self.assert_original(root)
        for payload in [b"", b"<html>download error</html>",
                        b"version https://git-lfs.github.com/spec/v1\n", elf()[:20],
                        elf(183, 2), elf(62, 1)]:
            with self.subTest(payload=payload[:20]):
                self.run_case(payload=payload, verify=verify)

    def test_cancel_leaves_service_untouched(self):
        def verify(root, result, events):
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(events, [])
            self.assertTrue((root / "running").exists())
            self.assert_original(root)
        for answer in ["2\n", "invalid\n", ""]:
            self.run_case(answer=answer, verify=verify)

    def test_stop_failure_never_replaces(self):
        def verify(root, result, events):
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("replace", events)
            self.assertTrue((root / "running").exists())
            self.assert_original(root)
        for mode in ["stop_fail", "stop_still_running", "stop_partial_fail"]:
            self.run_case(mode=mode, verify=verify)

    def test_replacement_and_start_failures_restore_running_old_version(self):
        def verify(root, result, events):
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("restore", events)
            self.assertEqual(events[-1], "start-old")
            self.assertTrue((root / "running").exists())
            self.assert_original(root)
        for mode in ["replace_fail", "start_fail", "immediate_crash"]:
            self.run_case(mode=mode, verify=verify)

    def test_recovery_errors_report_failure_and_keep_backup(self):
        def verify(root, result, events):
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("start-old", events)
            self.assertEqual((root / "install dir/rms.bak").read_bytes(), (root / "old").read_bytes())
        for mode in ["restore_fail", "recovery_stop_fail"]:
            self.run_case(mode=mode, verify=verify)

    def test_old_start_failure_is_not_success(self):
        def verify(root, result, events):
            self.assertNotEqual(result.returncode, 0)
            self.assert_original(root)
            self.assertIn("旧程序重新启动失败", result.stdout)
        self.run_case(mode="old_start_fail", verify=verify)

    def test_fresh_install(self):
        def verify(root, result, events):
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertNotIn("backup", events)
            self.assertEqual(events[-1], "start-new")
            self.assertTrue((root / "running").exists())
        self.run_case(installed=False, running=False, verify=verify)

    def test_fresh_install_failure_does_not_restore_stale_backup(self):
        def verify(root, result, events):
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("restore", events)
            self.assertNotIn("start-old", events)
            self.assertFalse((root / "running").exists())
            self.assertEqual((root / "install dir/rms.bak").read_text(), "stale backup")
        self.run_case(mode="start_fail", installed=False, running=False,
                      prepare=lambda r: (r / "install dir/rms.bak").write_text("stale backup"),
                      verify=verify)

    def test_stopped_install_failure_restores_without_starting_old_version(self):
        def verify(root, result, events):
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("start-old", events)
            self.assertFalse((root / "running").exists())
            self.assert_original(root)
        self.run_case(mode="start_fail", running=False, verify=verify)

    def test_running_service_without_backup_binary_is_not_stopped(self):
        def verify(root, result, events):
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("stop", events)
            self.assertTrue((root / "running").exists())
        self.run_case(installed=False, verify=verify)

    def test_concurrent_install_cannot_touch_other_staging_directory(self):
        def prepare(root):
            stage = root / "install dir/.rms-install"
            stage.mkdir()
            (stage / "rms").write_text("another task")
        def verify(root, result, events):
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(events, [])
            self.assertEqual((root / "install dir/.rms-install/rms").read_text(), "another task")
        self.run_case(mode="locked", prepare=prepare, verify=verify)

    def test_directory_at_binary_or_backup_path_rejected(self):
        for name in ("rms", "rms.bak"):
            def prepare(root):
                path = root / "install dir" / name
                if path.exists():
                    path.unlink()
                path.mkdir()
            def verify(root, result, events):
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("stop", events)
            self.run_case(prepare=prepare, verify=verify)

    def test_termination_cleans_download_or_restores_after_stop(self):
        for shell in SHELLS:
            cases = [(mode, sig) for mode in ("download_wait", "start_wait")
                     for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)]
            for mode, sig in cases:
                with self.subTest(shell=shell, mode=mode, signal=sig), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    env = self.setup_case(root, mode=mode)
                    process = subprocess.Popen([shell, "-c", HARNESS], env=env, stdin=subprocess.PIPE,
                                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                               text=True, start_new_session=True)
                    try:
                        process.stdin.write("1\n")
                        process.stdin.flush()
                        deadline = time.monotonic() + 5
                        while "waiting" not in (root / "events").read_text():
                            self.assertIsNone(process.poll())
                            self.assertLess(time.monotonic(), deadline)
                            time.sleep(0.01)
                        os.killpg(process.pid, sig)
                        process.communicate(timeout=5)
                        self.assertNotEqual(process.returncode, 0)
                        self.assert_original(root)
                        self.assertTrue((root / "running").exists())
                        self.assertFalse((root / "install dir/.rms-install").exists())
                        if mode == "download_wait":
                            self.assertNotIn("stop", (root / "events").read_text().splitlines())
                    finally:
                        if process.poll() is None:
                            os.killpg(process.pid, signal.SIGKILL)
                        process.communicate()


if __name__ == "__main__":
    unittest.main()
