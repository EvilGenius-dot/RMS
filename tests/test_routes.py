"""Route probes use only HEAD, stay bounded, and never block manual selection."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest

from test_install import INSTALLER, SHELLS


@contextmanager
def server(barrier=None):
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_HEAD(self):
            requests.append((self.command, self.path))
            if barrier:
                try:
                    barrier.wait(timeout=2)
                except threading.BrokenBarrierError:
                    self.send_response(503)
                    self.end_headers()
                    return
            if self.path.startswith('/slow'):
                time.sleep(5)
            if self.path.startswith('/redirect'):
                self.send_response(302)
                self.send_header('Location', '/ok/rms')
            else:
                self.send_response(404 if self.path.startswith('/missing') else 200)
            self.end_headers()

        def do_GET(self):
            requests.append((self.command, self.path))
            self.send_response(500)
            self.end_headers()

        def log_message(self, *_):
            pass

    httpd = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=httpd.serve_forever, daemon=True)
    worker.start()
    try:
        yield f'http://127.0.0.1:{httpd.server_port}', requests
    finally:
        httpd.shutdown()
        httpd.server_close()
        worker.join()


class RouteTests(unittest.TestCase):
    def run_script(self, shell, script, answer='\n', **extra):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'library.sh').write_text(INSTALLER.read_text().removesuffix('main "$@"\n'))
            result = subprocess.run(
                [shell, '-c', '. "$TEST_ROOT/library.sh"\n' + script],
                env=dict(os.environ, TEST_ROOT=tmp, TMPDIR=tmp, NO_PROXY='*', no_proxy='*', **extra),
                input=answer, text=True, capture_output=True, timeout=8)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(list(root.glob('rms-route.*')), [])
            return result.stdout

    def test_parallel_head_probes_use_selected_architecture_and_keep_selection(self):
        for shell in SHELLS:
            for answer, route in [('\n', 1), ('2\n', 2), ('3\n', 3)]:
                with self.subTest(shell=shell, answer=answer), server(threading.Barrier(3)) as (base, requests):
                    output = self.run_script(shell, '''
ROUTE_1="$BASE/one"; ROUTE_2="$BASE/two"; ROUTE_3="$BASE/three"
TARGET_ROUTE_EXEC=/aarch64-musl/rms
select_route || exit 1
printf '\nCHOSEN=%s\n' "$TARGET_ROUTE"
''', answer, BASE=base)
                    for label in ['线路1（R2）', '线路2', '线路3']:
                        self.assertRegex(output, label + r' +\d+ ms')
                    self.assertIn(f'CHOSEN={base}/' + ['one', 'two', 'three'][route - 1], output)
                    self.assertCountEqual(requests, [('HEAD', f'/{prefix}/aarch64-musl/rms')
                                                     for prefix in ['one', 'two', 'three']])

    def test_redirect_and_http_error(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), server() as (base, requests):
                output = self.run_script(shell, '''
probe_route_latency "$BASE/redirect/rms"
probe_route_latency "$BASE/missing/rms"
''', BASE=base)
                self.assertRegex(output, r'^\d+ ms\n不可用（HTTP 404）\n$')
                self.assertEqual(requests, [('HEAD', '/redirect/rms'), ('HEAD', '/ok/rms'),
                                            ('HEAD', '/missing/rms')])

    def test_timeout_is_bounded(self):
        with server() as (base, _):
            started = time.monotonic()
            output = self.run_script(SHELLS[0], 'probe_route_latency "$BASE/slow/rms"', BASE=base)
            self.assertEqual(output, '超时\n')
            self.assertLess(time.monotonic() - started, 5.5)

    def test_missing_curl_or_temp_directory_keeps_menu_usable(self):
        for shell in SHELLS:
            for setup, expected in [(
                'command() { if [ "$1" = -v ] && [ "$2" = curl ]; then return 1; fi; builtin command "$@"; }',
                '未检测（缺少 curl）'), ('mktemp() { return 1; }', '未检测')]:
                with self.subTest(shell=shell, setup=setup):
                    output = self.run_script(shell, setup + '\nselect_route || exit 1\nprintf "\\nCHOSEN=%s\\n" "$TARGET_ROUTE"', '3\n')
                    self.assertIn(expected, output)
                    self.assertIn('CHOSEN=https://static2.', output)

    def test_connection_failure_and_invalid_input(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                output = self.run_script(shell, '''
curl() { return 7; }
select_route && exit 1
printf '\nCHOSEN=%s\n' "$TARGET_ROUTE"
''', '4\n')
                self.assertEqual(output.count('连接失败'), 3)
                self.assertIn('错误的线路选择命令', output)
                self.assertTrue(output.endswith('CHOSEN=\n'))


if __name__ == '__main__':
    unittest.main()
