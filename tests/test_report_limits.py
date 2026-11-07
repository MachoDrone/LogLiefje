import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "LogLiefje.sh").read_text()


def collector_function(name):
    start = SOURCE.index(f"{name}() {{\n")
    end = SOURCE.index("\n}\n", start) + 3
    return SOURCE[start:end]


class ReportTests(unittest.TestCase):
    def test_size_limit_preserves_ends_and_labels_any_omission(self):
        original = b"begin report\n" + b"fixture data\n" * 300 + b"end report\n"
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory, "report")
            for limit in (len(original) + 1, len(original), 512):
                with self.subTest(limit=limit):
                    report.write_bytes(original)
                    subprocess.run(
                        ["bash", "-c", collector_function("_limit_report_bytes")
                         + '\n_limit_report_bytes "$1" "$2" "$3"',
                         "test", str(report), str(limit), str(Path(directory, "limited"))],
                        check=True,
                    )
                    result = report.read_bytes()
                    if limit >= len(original):
                        self.assertEqual(result, original)
                    else:
                        self.assertEqual(len(result), limit)
                        self.assertIn(b"byte limit reached", result)
                        self.assertTrue(result.startswith(b"begin report\n"))
                        self.assertTrue(result.endswith(b"end report\n"))

    def test_dns_failure_is_visible_even_if_immediate(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            for name, body in {
                "getent": 'case "$2" in nosana.com) echo "192.0.2.21 STREAM host" ;; *) exit 2 ;; esac',
                "resolvectl": 'echo "Link 2 (example): 192.0.2.53"',
            }.items():
                script = fixture / name
                script.write_text("#!/bin/sh\n" + body + "\n")
                script.chmod(0o755)
            environment = dict(os.environ, PATH=directory + ":" + os.environ["PATH"])
            run = subprocess.run(
                ["bash", "-c", collector_function("_host_dns_report") + "\n_host_dns_report"],
                env=environment, text=True, capture_output=True, check=True,
            )
            self.assertIn("Link 2 (example): 192.0.2.53", run.stdout)
            self.assertIn("Host DNS nosana.com: OK 192.0.2.21", run.stdout)
            self.assertIn("Host DNS nosana.io: FAILED (exit 2,", run.stdout)

    def test_cleaned_timestamps_and_stderr(self):
        code = "\n".join(collector_function(n) for n in ("_clean_docker_log", "_dedup_consecutive"))
        run = subprocess.run(["bash", "-c", code + "\n_clean_docker_log | _dedup_consecutive"],
                             input=("2026-11-07T03:40:21.12-05:00 stderr F NodeNotQualifiedError\n"
                                    "2026-11-07T08:41:01.12Z stdout F Second message\n"
                                    "2026-11-07T16:43:00.12+08:00 stdout F Third message\n"),
                             text=True, capture_output=True, check=True)
        self.assertEqual([line.strip() for line in run.stdout.splitlines()],
                         ["2026-11-07T08:40:21Z NodeNotQualifiedError",
                          "2026-11-07T08:41:01Z Second message",
                          "2026-11-07T08:43:00Z Third message"])
