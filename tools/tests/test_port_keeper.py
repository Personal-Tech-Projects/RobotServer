import json
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "port_keeper.py"


def wait_for_file(path, process, timeout=2.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        if process.poll() is not None:
            break
        time.sleep(0.01)
    stdout, stderr = process.communicate(timeout=1)
    raise AssertionError(
        f"ready file was not created; rc={process.returncode} "
        f"stdout={stdout!r} stderr={stderr!r}"
    )


class PortKeeperTest(unittest.TestCase):
    def start_keeper(self, port, seconds, ready_file):
        return subprocess.Popen(
            [
                sys.executable,
                str(SCRIPT),
                "--ports",
                str(port),
                "--seconds",
                str(seconds),
                "--ready-file",
                str(ready_file),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def test_bind_failure_exits_nonzero_without_readiness(self):
        blocker = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        blocker.bind(("0.0.0.0", 0))
        port = blocker.getsockname()[1]
        with tempfile.TemporaryDirectory() as directory:
            ready_file = Path(directory) / "ready.json"
            process = self.start_keeper(port, 0.2, ready_file)
            stdout, stderr = process.communicate(timeout=2)
        blocker.close()

        self.assertNotEqual(process.returncode, 0)
        self.assertFalse(ready_file.exists())
        self.assertNotIn("READY", stdout)
        self.assertIn("startup failed", stderr)

    def test_partial_bind_failure_releases_earlier_ports(self):
        first_probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        first_probe.bind(("127.0.0.1", 0))
        first_port = first_probe.getsockname()[1]
        first_probe.close()

        blocker = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        blocker.bind(("0.0.0.0", 0))
        blocked_port = blocker.getsockname()[1]
        with tempfile.TemporaryDirectory() as directory:
            ready_file = Path(directory) / "ready.json"
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--ports",
                    f"{first_port},{blocked_port}",
                    "--seconds",
                    "0.2",
                    "--ready-file",
                    str(ready_file),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            stdout, stderr = process.communicate(timeout=2)
        blocker.close()

        replacement = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            replacement.bind(("0.0.0.0", first_port))
        finally:
            replacement.close()

        self.assertNotEqual(process.returncode, 0)
        self.assertNotIn("READY", stdout)
        self.assertIn("startup failed", stderr)

    def test_success_reports_readiness_drains_and_cleans_up(self):
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()

        with tempfile.TemporaryDirectory() as directory:
            ready_file = Path(directory) / "ready.json"
            process = self.start_keeper(port, 0.4, ready_file)
            wait_for_file(ready_file, process)
            ready = json.loads(ready_file.read_text(encoding="utf-8"))

            sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            for _ in range(20):
                sender.sendto(b"test", ("127.0.0.1", port))
            sender.close()

            stdout, stderr = process.communicate(timeout=2)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(ready["pid"], process.pid)
            self.assertEqual(ready["ports"], [port])
            self.assertIn("READY", stdout)
            self.assertRegex(stdout, r"RELEASED drained=([1-9][0-9]*)")
            self.assertFalse(ready_file.exists())

    def test_deadline_remains_bounded_under_continuous_traffic(self):
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()

        with tempfile.TemporaryDirectory() as directory:
            ready_file = Path(directory) / "ready.json"
            process = self.start_keeper(port, 0.3, ready_file)
            wait_for_file(ready_file, process)

            stop_sender = threading.Event()

            def send_continuously():
                sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                try:
                    while not stop_sender.is_set():
                        sender.sendto(b"load", ("127.0.0.1", port))
                finally:
                    sender.close()

            sender_thread = threading.Thread(target=send_continuously)
            started = time.monotonic()
            sender_thread.start()
            try:
                stdout, stderr = process.communicate(timeout=2)
            finally:
                stop_sender.set()
                sender_thread.join(timeout=1)

            elapsed = time.monotonic() - started
            self.assertEqual(process.returncode, 0, stderr)
            self.assertLess(elapsed, 1.5)
            self.assertIn("RELEASED", stdout)
            self.assertFalse(ready_file.exists())


if __name__ == "__main__":
    unittest.main()
