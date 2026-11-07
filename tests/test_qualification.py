"""Exercise the shipped report parser without running the collector or a live node."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


MAIN = Path(__file__).resolve().parents[1] / "LogLiefje.sh"
SOURCE = Path(os.environ.get("QUALIFICATION_SOURCE", MAIN)).read_text()
FUNCTION = SOURCE.split("# BEGIN QUALIFICATION REPORT\n", 1)[1].split(
    "# END QUALIFICATION REPORT", 1
)[0]
STAMP = "2026-11-06T19:00:00Z"


def lines(content, stamp=STAMP):
    return "".join(f"{stamp} stdout F {line}\n" for line in content.splitlines())


def report(content, cutoff=""):
    with tempfile.TemporaryDirectory() as folder:
        log = Path(folder) / "node.log"
        log.write_text(content)
        result = subprocess.run(
            ["bash", "-c", FUNCTION + '\n_qualification_report "$1" "$2"', "test", log, cutoff],
            text=True, capture_output=True, check=True,
        )
    if result.stderr:
        raise AssertionError(result.stderr)
    return result.stdout


class QualificationTests(unittest.TestCase):
    def test_native_feedback(self):
        body = lines("""LATEST MEASUREMENTS
•  disk_gb 1732
•  network.download_mbps 110
•  network.upload_mbps 51.96
•  network.download_mbps_fast 110
•  network.upload_mbps_fast 48
•  network.download_mbps_ookla 104.2
•  network.upload_mbps_ookla 51.96
•  network.download_mbps_libre 0
•  network.upload_mbps_libre null
•  gpu.devices[0].name NVIDIA GeForce RTX 5070
TARGET MARKET

NVIDIA 5070 Community
✔ package_version 1.1.84
rule: package_version is not null
✖ group:network
rule: average(download_mbps) ≥ 100 AND average(upload_mbps) ≥ 50
Optional thresholds
(do not block market access)
✔ download_mbps_fast 110
rule: download_mbps_fast ≥ 0
✖ sample_optional 30
rule: sample_optional ≤ 10
Node currently meets 5 of 6 market requirements for NVIDIA 5070 Community — 1 still need improvement
Node does not qualify for a market yet. Next eligible retest at 2026-11-06T19:11:00.100Z, retrying in ~11 minutes.""")
        result = report(body)
        self.assertEqual(result.count("| target=NVIDIA 5070 Community"), 1)
        self.assertIn("primary=110/51.96 fast=110/48 ookla=104.2/51.96 libre=0/null", result)
        self.assertIn("required passed=5/6", result)
        self.assertIn("required failed=group:network (average(download_mbps) >= 100 AND average(upload_mbps) >= 50)", result)
        self.assertIn("optional passed=download_mbps_fast (reported 110) (download_mbps_fast >= 0)", result)
        self.assertIn("optional failed=sample_optional (reported 30) (sample_optional <= 10)", result)
        self.assertNotIn("reported average(", result)
        self.assertIn("admission=no market | next eligible=2026-11-06T19:11:00.100Z", result)

    def test_legacy_and_modern_are_independent_and_not_limited_to_log_ends(self):
        first_key = "2" * 44
        last_key = "3" * 44
        middle = f"""Grid recommended {first_key} for this node
TARGET MARKET
4090-Reserved
Node currently meets all 2 market requirements for 4090-Reserved
Node does not qualify for a market yet. Next eligible retest at 2026-11-07T01:00:00Z.
Grid recommended {last_key} for this node"""
        data = lines("unrelated\n" * 5100) + lines(middle) + lines("unrelated\n" * 5100)
        data += lines("Node currently meets all 5 market requirements for ember-drift NVIDIA 4090")
        result = report(data)
        self.assertEqual(result.splitlines()[:4], [
            "First observed target: 4090-Reserved",
            "Last observed target: ember-drift NVIDIA 4090",
            f"First legacy recommendation: {first_key}",
            f"Last legacy recommendation: {last_key}",
        ])
        self.assertIn("required passed=2/2 | admission=no market", result)
        self.assertNotIn("admission=granted", result)
        other = report(lines(f"Grid recommended {first_key}"))
        self.assertIn("First observed target: not observed\n", other)

    def test_retries_show_observation_times_not_invented_sample_ids(self):
        block = """LATEST MEASUREMENTS
 network.download_mbps 495.7
 network.upload_mbps 38.57"""
        data = lines(block + "\nNode does not qualify for a market yet. Next eligible retest at 2026-11-06T19:11:00Z.")
        data += lines(block + "\nTARGET MARKET\nember-drift NVIDIA 4090\nNode currently meets all 5 market requirements for ember-drift NVIDIA 4090",
                      "2026-11-06T19:11:02Z")
        data += lines("QUEUED In market Mkta at position 1/2\n[OK] Node has claimed job JobAAA\nJob JobAAA started successfully", "2026-11-06T19:11:10Z")
        data += lines("QUEUED In market Mktb at position 2/2\nJob JobBBB started successfully", "2026-11-06T20:05:00Z")
        result = report(data)
        rows = [r.strip() for r in result.splitlines() if " | " in r]
        self.assertEqual(len(rows), 7)
        self.assertTrue(rows[0].startswith(STAMP + " | Mbps down/up: primary=495.7/38.57"))
        self.assertIn("admission=no market", rows[0])
        self.assertIn("ember-drift NVIDIA 4090 | Mbps down/up: primary=495.7/38.57", rows[1])
        self.assertIn("queued in market=Mkta at position 1/2", rows[2])
        self.assertIn("job claimed=JobAAA", rows[3])
        self.assertIn("job started=JobAAA", rows[4])
        self.assertIn("queued in market=Mktb at position 2/2", rows[5])
        self.assertIn("job started=JobBBB", rows[6])
        self.assertNotIn("benchmark ID=", result)

    def test_printed_metadata_and_explicit_grant(self):
        data = lines("""Benchmark ID: aa-1
LATEST MEASUREMENTS
Measurement timestamp: 2026-11-06T18:59:50.030Z
network.upload_mbps_ookla 51.2
TARGET MARKET
5070 Community
[FAIL] group:network
rule: average(download_mbps) >= 100
Evaluated averages: average(download_mbps)=93.1 average(upload_mbps)=52.01
Node currently meets 5 of 6 market requirements for 5070 Community - 1 still need improvement""")
        grant = lines("Some thresholds are still below the target market requirements, but access was granted. Continuing.",
                      "2026-11-06T19:00:04Z")
        data += grant + lines("QUEUED In market Mkt at position 1/2", "2026-11-06T19:00:06Z")
        result = report(data)
        self.assertIn("benchmark ID=aa-1 | measurement time=2026-11-06T18:59:50.030Z", result)
        self.assertIn("ookla=?/51.2", result)
        self.assertIn("reported average(download_mbps)=93.1 | reported average(upload_mbps)=52.01", result)
        rows = [row.strip() for row in result.splitlines() if " | " in row]
        self.assertEqual(len(rows), 3)
        self.assertIn("admission=granted | decision observed=2026-11-06T19:00:04Z", rows[0])
        self.assertEqual(rows[1], "2026-11-06T19:00:04Z | explicit access=granted")
        self.assertEqual(rows[2], "2026-11-06T19:00:06Z | queued in market=Mkt at position 1/2")
        cutoff_rows = [row.strip() for row in report(data, "2026-11-06T19:00:04Z").splitlines() if " | " in row]
        self.assertEqual(cutoff_rows, rows[1:])

    def test_incomplete_request_and_restart_do_not_borrow_evidence(self):
        data = lines("""LATEST MEASUREMENTS
network.download_mbps 120
Node shutdown successfully
Requesting market
Could not fetch latest measurements: connection timed out
TARGET MARKET
[FAIL] group:network
rule: average(download_mbps) >= 100
========== ERROR ==========
Error Name: NodeNotQualifiedError
Message: Node does not meet the minimum requirements for any market. Next eligible retest at 2026-11-07T01:00:47.600Z. For details see host.
Node shutdown successfully""")
        result = report(data)
        rows = [r for r in result.splitlines() if " | " in r]
        self.assertEqual(len(rows), 2)
        self.assertIn("primary=120/?", rows[0])
        self.assertNotIn("admission=", rows[0])
        self.assertIn("required failed=group:network", rows[1])
        self.assertNotIn("primary=", rows[1])
        self.assertNotIn("target=", rows[1])
        self.assertIn("admission=no market (NodeNotQualifiedError) | next eligible=2026-11-07T01:00:47.600Z", rows[1])
        self.assertIn("No qualification events observed", report(lines("unrelated")))

    def test_utc_cutoff_and_complete_target_history(self):
        body = lines("TARGET MARKET\nOld target", "2026-11-06T01:00:00.100+08:00")
        body += lines("TARGET MARKET\nBoundary target", "2026-11-07T02:00:00.000+08:00")
        body += lines("TARGET MARKET\nNew target", "2026-11-06T13:00:01.000-05:00")
        result = report(body, "2026-11-06T18:00:00")
        self.assertIn("First observed target: Old target", result)
        self.assertNotIn("| target=Old target", result)
        self.assertIn("2026-11-06T18:00:00Z | target=Boundary target", result)
        self.assertIn("2026-11-06T18:00:01Z | target=New target", result)
        self.assertIn("1 older observation outside the UTC selection", result)
        result = report(lines("TARGET MARKET\nStill visible", "2026-11-06T19:01:23"), "2026-11-06T19:00:00Z")
        self.assertIn("2026-11-06T19:01:23 (zone unknown) | target=Still visible", result)
        result = report("".join(lines(f"TARGET MARKET\nMarket {i:03}") for i in range(53)))
        self.assertEqual(result.count("| target=Market "), 53)
        self.assertIn("| target=Market 002\n", result)
        self.assertIn("| target=Market 003\n", result)
        self.assertIn("| target=Market 052\n", result)

    def test_wallet_restart_and_partial_stderr(self):
        data = lines("LATEST MEASUREMENTS\nnetwork.upload_mbps 44\nWallet: newWallet")
        data += "2026-11-06T20:00:01.020+01:00 stderr F Error Name: NodeNotQualifiedError\n"
        data += "2026-11-06T20:00:01.030+01:00 stderr F Message: Node does not meet the minimum requirements for any market. Next eligible retest at 2026-11-07T01:00:00Z.\n"
        data += lines("[FAIL] Could not join market", "2026-11-06T20:00:03Z")
        result = report(data)
        rows = [r for r in result.splitlines() if " | " in r]
        self.assertEqual(len(rows), 3)
        self.assertIn("primary=?/44", rows[0])
        self.assertNotIn("admission=", rows[0])
        self.assertIn("2026-11-06T19:00:01Z | admission=no market (NodeNotQualifiedError)", rows[1])
        self.assertIn("2026-11-06T20:00:03Z | queue entry=failed", rows[2])

    def test_distinct_decisions_and_cutoff_boundary(self):
        earlier = lines("LATEST MEASUREMENTS\nnetwork.download_mbps 48\nTARGET MARKET\nNVIDIA 5070 Community")
        retry = lines("Node does not qualify for a market yet. Next eligible retest at 2026-11-06T19:11:00Z.",
                      "2026-11-06T19:00:02Z")
        later = lines("Error Name: NodeNotQualifiedError\nMessage: Node does not meet the minimum requirements for any market.",
                      "2026-11-06T19:12:02Z")
        grant = lines("Some thresholds are still below the target market requirements, but access was granted. Continuing.",
                      "2026-11-07T12:00:00Z")
        result = report(earlier + retry + later + grant)
        rows = [r for r in result.splitlines() if " | " in r]
        self.assertEqual(len(rows), 3)
        self.assertIn("primary=48/? | admission=no market | decision observed=2026-11-06T19:00:02Z", rows[0])
        self.assertIn("19:12:02Z | admission=no market (NodeNotQualifiedError)", rows[1])
        self.assertNotIn("next eligible=", rows[1])
        self.assertIn("12:00:00Z | explicit access=granted", rows[2])
        window = report(earlier + retry, "2026-11-06T19:00:01Z")
        self.assertIn("19:00:02Z | admission=no market | next eligible=", window)
        self.assertNotIn("primary=48/", window)


if __name__ == "__main__":
    unittest.main()
