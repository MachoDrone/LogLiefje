#!/usr/bin/python3
"""Service responses for the release smoke test. Do not log request headers."""
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
sandbox = Path(os.environ["FIXTURE_DIR"])


def observed(event, **values):
    with (sandbox / "events.jsonl").open("a") as stream:
        print(json.dumps(dict(event=event, **values)), file=stream)


def form(key):
    return next(arg[len(key) + 1:] for arg in args if arg.startswith(key + "="))


if "https://litterbox.catbox.moe/resources/internals/api.php" in args:
    report = Path(form("fileToUpload")[1:])
    observed("litterbox", size=report.stat().st_size)
    if os.environ.get("FIXTURE_UPLOAD_FAILURE") == "litterbox":
        print("fixture unavailable\n503")
    else:
        print("https://litter.catbox.moe/fixture.txt\n200")
elif "https://slack.com/api/files.getUploadURLExternal" in args:
    observed("request_upload", size=int(form("length")))
    print(json.dumps({"upload_url": "https://fixture.invalid/upload", "file_id": "F001"}))
elif "https://fixture.invalid/upload" in args:
    preview = Path(form("file")[1:].split(";")[0])
    observed("slack_bytes", size=preview.stat().st_size)
    print("OK")
elif "https://slack.com/api/files.completeUploadExternal" in args:
    payload = json.loads(args[args.index("--data") + 1])
    observed("slack_complete", channel=payload["channel_id"])
    print(json.dumps({"ok": True, "files": [{"permalink": "https://fixture.invalid/F001"}]}))
elif any(arg.startswith("https://speed.cloudflare.com/") for arg in args):
    with (sandbox / "probe-attempts").open("a") as stream:
        print("bandwidth", file=stream)
    print("12345678")
elif "https://api.mainnet-beta.solana.com" in args:
    if "time_total" in " ".join(arg for arg in args if arg.startswith("%{")):
        print("0.012")
    else:
        print("{}")
else:
    observed("unexpected_curl")
    sys.exit(2)
