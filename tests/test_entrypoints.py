"""Offline end-to-end tests for the exact Slack and checkout entry points."""
import datetime as dt
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).with_name("entrypoint_fixtures")
WALLET = "AbC" * 14 + "12"
SLACK_COMMAND = "bash <(wget -qO- https://raw.githubusercontent.com/MachoDrone/LogLiefje/refs/heads/main/LogLiefje.sh)"


class EntrypointTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.sandbox = Path(temporary.name)
        self.bin = self.sandbox / "bin"
        self.bin.mkdir()
        for folder in ("home", "tmp", "input"):
            (self.sandbox / folder).mkdir()
        self.environment = {
            "PATH": str(self.bin), "HOME": str(self.sandbox / "home"),
            "TMPDIR": str(self.sandbox / "tmp"), "FIXTURE_DIR": str(self.sandbox / "input"),
            "FIXTURE_SOURCE": str(ROOT / "LogLiefje.sh"), "FIXTURE_WALLET": WALLET,
            "LC_ALL": "C.UTF-8", "TZ": "UTC", "TERM": "dumb",
        }
        self.commands()
        self.logs()

    def script(self, name, body):
        cmd = self.bin / name
        cmd.write_text("#!/bin/bash\n" + body + "\n")
        cmd.chmod(0o755)

    def commands(self):
        # An allowlist makes a missing fixture executable fail closed. In particular,
        # real curl, wget, DNS, sudo, Docker and Podman are never on the child's PATH.
        for name in ("bash basename bc cut date dirname echo env head jq mktemp mv paste perl python3 "
                     "realpath rm sed sort stat tail tac timeout tr truncate uniq wc xargs").split():
            exe = shutil.which(name)
            if exe:
                (self.bin / name).symlink_to(exe)
        # Map hardware/system-file arguments to fixtures instead of host data.
        for name in ("awk", "cat", "grep", "ls", "od"):
            self.script(name, '''
args=()
for arg in "$@"; do
    case "$arg" in
        /proc/*|/etc/*|/sys/*) arg="$FIXTURE_DIR/system${arg}" ;;
    esac
    args+=("$arg")
done
exec /usr/bin/''' + name + ' "${args[@]}"')
        source = self.sandbox / "input/system"
        for file, content in {
            "proc/cpuinfo": "processor : 0\nmodel name : Test CPU\ncpu MHz : 3000\n",
            "etc/os-release": 'PRETTY_NAME="Fixture Linux"\n',
            "etc/resolv.conf": "nameserver 127.0.0.53\n",
        }.items():
            target = source / file
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)

        # Stub optional hardware probes. Real sudo/modprobe are never invoked.
        for name in ("clear dd df ethtool free hostname ip nproc ping resolvectl "
                     "sensors sleep sudo systemd-detect-virt timedatectl top ufw "
                     "uname uptime who").split():
            self.script(name, "exit 1")
        self.script("hostname", "echo fixture-host")
        self.script("nproc", "echo 1")
        self.script("getent", '[[ "${!#}" == "nosana.io" ]] && exit 2\necho "192.0.2.12 ${!#}"')
        self.script("wget", '''
[[ "$#" == 2 && "$1" == -qO- && "$2" == https://raw.githubusercontent.com/MachoDrone/LogLiefje/refs/heads/main/LogLiefje.sh ]] || exit 2
echo '{"event":"wget_collector"}' >> "$FIXTURE_DIR/events.jsonl"
exec /usr/bin/cat "$FIXTURE_SOURCE"''')
        for local, source_name in (("curl", "fake_curl.py"), ("docker", "fake_docker.sh")):
            cmd = self.bin / local
            shutil.copyfile(FIXTURES / source_name, cmd)
            cmd.chmod(0o755)

    def logs(self, padding=0):
        when = dt.datetime.now(dt.timezone.utc)
        def stamp(age_days):
            return (when - dt.timedelta(days=age_days)).strftime("%Y-%m-%dT%H:%M:%S.100000000+00:00")

        def lines(timestamp, messages):
            return "".join(f"{timestamp} stdout F {message}\n" for message in messages)

        old, recent = stamp(5), stamp(0)
        startup = [f"Wallet: {WALLET}"] + [f"Startup line {i}" for i in range(35)]
        log = lines(old, startup + ["HISTORICAL-ONLY-FIXTURE"])
        if padding:
            log += lines(recent, (f"Progress {i:05d} " + "x" * 275 for i in range(padding)))
        log += lines(recent, [
            "RECENT-FIXTURE", "LATEST MEASUREMENTS", "network.download_mbps 110",
            "network.upload_mbps 52.01", "TARGET MARKET", "NVIDIA 5070 Community",
            "✖ group:network", "rule: average(download_mbps) ≥ 100 AND average(upload_mbps) ≥ 50",
            "Node currently meets 5 of 6 market requirements for NVIDIA 5070 Community — 1 still need improvement",
            "Node does not qualify for a market yet. Next eligible retest at 2030-05-01T01:25:00.000Z, retrying in ~11 minutes.",
        ])
        (self.sandbox / "input/node.log").write_text(log)
        frp = ['FRPC-EARLIEST-RETAINED']
        frp.extend(f"Earlier retained event {i:04d}: " + "x" * 80 for i in range(800))
        config = [ 'serverAddr = "node.k8s.prd.nos.ci"', 'serverPort = 7000', '[[proxies]]',
                f'name = "API-{WALLET}"', 'type = "http"', 'localIp = "nosana-node"', 'localPort = 5001',
                f'customDomains = ["{WALLET}.node.k8s.prd.nos.ci"]' ]
        (self.sandbox / "input/frpc.toml").write_text("\n".join(config))
        frp.extend(config + ["start proxy success FRPC-FIXTURE-EVIDENCE"])
        (self.sandbox / "input/proxy.log").write_text(lines(recent, frp))

    def launch(self, checkout, *flags):
        cwd = self.sandbox / "launch"
        cwd.mkdir()
        if checkout:
            # The checkout entry point and standalone helper are both available.
            for file in ("LogLiefje.sh", "frpc-logs.sh"):
                shutil.copyfile(ROOT / file, cwd / file)
            command = "bash ./LogLiefje.sh"
        else:
            self.assertEqual(list(cwd.iterdir()), [])
            command = SLACK_COMMAND
        result = subprocess.run(["/bin/bash", "-c", " ".join((command, *flags))],
                                env=self.environment, cwd=cwd, input="fixture-user\ntest issue\n\n",
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=60)
        # Keep diagnostics free of possible authorization headers.
        self.assertEqual(result.returncode, 0, "collector did not exit successfully")
        report = (cwd / "mylog.txt").read_bytes()
        self.assertTrue(report.isascii(), "final report should be ASCII")
        self.assertTrue(b"\0" not in report, "binary NUL in report")
        expected = [
            b"log collector v0.00.91",
            b"FRPC-EARLIEST-RETAINED",
            b"FRPC-FIXTURE-EVIDENCE",
            b"RECENT-FIXTURE",
            b"First observed target: NVIDIA 5070 Community",
            b"Qualification timeline",
            b"average(download_mbps) >= 100",
            b"Host DNS nosana.com: OK 192.0.2.12",
            b"Host DNS nosana.io: FAILED (exit 2",
        ]
        probe_attempts = self.sandbox / "input/probe-attempts"
        if (self.bin / "python3").exists():
            self.assertTrue(probe_attempts.is_file(), "Podman 'Up' state should trigger live probes")
            probe_order = probe_attempts.read_text().splitlines()
            first_bandwidth = probe_order.index("bandwidth")
            self.assertEqual(set(probe_order[:first_bandwidth]), {"frpc-local-api", "node"})
            self.assertEqual(set(probe_order[first_bandwidth:]), {"bandwidth"})
        for marker in expected:
            self.assertTrue(marker in report, f"missing report marker {marker!r}")
        self.assertTrue("No such file or directory" not in result.stderr, "missing fixture file or command")
        self.assertTrue("command not found" not in result.stderr, "unexpected external dependency")
        file = self.sandbox / "input/events.jsonl"
        self.events = [json.loads(row) for row in file.read_text().splitlines()] if file.exists() else []
        self.assertNotIn("unexpected_curl", [row["event"] for row in self.events])
        return report, result.stdout

    def deliveries(self):
        return {item["event"]: item for item in self.events}

    def test_single_file_slack_command_default_upload(self):
        report, stdout = self.launch(False)
        deliveries = self.deliveries()
        self.assertIn("wget_collector", deliveries)
        self.assertIn("Both uploads OK", stdout)
        self.assertTrue(b"HISTORICAL-ONLY-FIXTURE" not in report, "48h filter kept old data")
        self.assertTrue(b"test issue" in report, "operator description missing")
        self.assertEqual(deliveries["litterbox"]["size"], len(report))
        self.assertEqual(deliveries["slack_complete"]["channel"], "C09AX202QD7")

    def test_checkout_local_only_full_history(self):
        report, stdout = self.launch(True, "--no-upload", "--100")
        self.assertTrue(b"HISTORICAL-ONLY-FIXTURE" in report, "--100 omitted old data")
        self.assertIn("Log collection complete", stdout)
        self.assertEqual(self.events, [])

    def test_single_file_missing_python_keeps_retained_frpc_logs(self):
        (self.bin / "python3").unlink()
        report, _ = self.launch(False, "--no-upload")
        self.assertTrue(b"python3 missing" in report, "live probe skip reason missing")
        self.assertEqual(self.events, [{"event": "wget_collector"}])

    def test_slack_preview_size_and_test_channel(self):
        self.logs(padding=3300)
        report, stdout = self.launch(False, "--test")
        deliveries = self.deliveries()
        self.assertIn("Both uploads OK", stdout)
        self.assertGreater(len(report), 500000)
        self.assertEqual(len(report), deliveries["litterbox"]["size"])
        self.assertLessEqual(deliveries["slack_bytes"]["size"], 500000)
        self.assertEqual(deliveries["request_upload"]["size"], deliveries["slack_bytes"]["size"])
        self.assertEqual(deliveries["slack_complete"]["channel"], "C093HNDQ422")

    def test_one_upload_failing_keeps_other_upload(self):
        self.environment["FIXTURE_UPLOAD_FAILURE"] = "litterbox"
        _, stdout = self.launch(True)
        self.assertIn("Partial success", stdout)
        self.assertEqual(self.deliveries()["slack_complete"]["channel"], "C09AX202QD7")


if __name__ == "__main__":
    unittest.main()
