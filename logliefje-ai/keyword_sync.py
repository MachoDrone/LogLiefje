"""Git-based keyword synchronization for LogLiefje AI."""

import json
import os
import random
import subprocess
import time
from pathlib import Path

KEYWORD_REPO = "https://github.com/MachoDrone/logliefje-keywords.git"
KEYWORD_DIR = "/tmp/logliefje-keywords"
MAX_PUSH_RETRIES = 3


def _run_git(args, cwd=KEYWORD_DIR, timeout=30):
    """Run a git command and return (success, stdout)."""
    try:
        result = subprocess.run(
            ["git"] + args,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return result.returncode == 0, result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return False, str(e)


def _get_github_token():
    """Get GitHub token from environment (obscured same as LogLiefje.sh approach)."""
    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        # Try reading from obscured env var parts
        parts = [
            os.environ.get("_GT_A", ""),
            os.environ.get("_GT_B", ""),
            os.environ.get("_GT_C", ""),
        ]
        token = "".join(parts)
    return token


def pull_keywords():
    """Clone or pull the keyword repo. Returns (keywords, patterns, false_positives) dicts."""
    keyword_path = Path(KEYWORD_DIR)

    if keyword_path.exists() and (keyword_path / ".git").exists():
        # Pull latest
        ok, _ = _run_git(["pull", "--rebase", "--quiet"])
        if not ok:
            # Reset and try again
            _run_git(["reset", "--hard", "origin/main"])
            _run_git(["pull", "--rebase", "--quiet"])
    else:
        # Clone fresh
        keyword_path.parent.mkdir(parents=True, exist_ok=True)
        if keyword_path.exists():
            subprocess.run(["rm", "-rf", str(keyword_path)], timeout=10)

        token = _get_github_token()
        if token:
            repo_url = KEYWORD_REPO.replace(
                "https://", f"https://x-access-token:{token}@"
            )
        else:
            repo_url = KEYWORD_REPO

        ok, out = _run_git(
            ["clone", "--depth", "1", repo_url, str(keyword_path)],
            cwd="/tmp",
        )
        if not ok:
            print(f"[keyword_sync] Clone failed: {out}")
            return _empty_data()

    return _load_files()


def _load_files():
    """Load JSON files from the keyword directory."""
    keyword_path = Path(KEYWORD_DIR)

    keywords = _load_json(keyword_path / "keywords.json", {"version": 1, "keywords": []})
    patterns = _load_json(keyword_path / "patterns.json", {"version": 1, "patterns": []})
    false_positives = _load_json(
        keyword_path / "false-positives.json", {"version": 1, "false_positives": []}
    )

    return keywords, patterns, false_positives


def _load_json(path, default):
    """Load a JSON file with a fallback default."""
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"[keyword_sync] Failed to load {path}: {e}")
        return default


def _empty_data():
    """Return empty keyword data structures."""
    return (
        {"version": 1, "keywords": []},
        {"version": 1, "patterns": []},
        {"version": 1, "false_positives": []},
    )


def push_new_keywords(new_keywords, node_id="unknown"):
    """Push newly discovered keywords back to the repo.

    Args:
        new_keywords: list of keyword dicts to add
        node_id: identifier for this node (for commit message)

    Returns:
        True if push succeeded, False otherwise
    """
    if not new_keywords:
        return True

    token = _get_github_token()
    if not token:
        print("[keyword_sync] No GitHub token — skipping push")
        return False

    keyword_path = Path(KEYWORD_DIR)
    keywords_file = keyword_path / "keywords.json"

    # Configure git identity
    _run_git(["config", "user.email", "logliefje-ai@nosana.io"])
    _run_git(["config", "user.name", "LogLiefje AI"])

    # Ensure remote uses authenticated URL
    auth_url = KEYWORD_REPO.replace(
        "https://", f"https://x-access-token:{token}@"
    )
    _run_git(["remote", "set-url", "origin", auth_url])

    # Random jitter (0-60s) to reduce push collisions from many nodes
    jitter = random.uniform(0, 60)
    print(f"[keyword_sync] Waiting {jitter:.0f}s jitter before push...")
    time.sleep(jitter)

    for attempt in range(1, MAX_PUSH_RETRIES + 1):
        # Pull latest before modifying
        _run_git(["pull", "--rebase", "--quiet"])

        # Load current keywords
        try:
            with open(keywords_file) as f:
                data = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            data = {"version": 1, "updated": "", "keywords": []}

        # Deduplicate: only add keywords with patterns not already present
        existing_patterns = {kw["pattern"].lower() for kw in data.get("keywords", [])}
        added = []
        for kw in new_keywords:
            if kw["pattern"].lower() not in existing_patterns:
                added.append(kw)
                existing_patterns.add(kw["pattern"].lower())

        if not added:
            print("[keyword_sync] All keywords already exist — nothing to push")
            return True

        data["keywords"].extend(added)
        data["updated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

        with open(keywords_file, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")

        # Commit
        _run_git(["add", "keywords.json"])
        msg = f"AI: add {len(added)} new keyword(s) from [{node_id}]"
        _run_git(["commit", "-m", msg])

        # Push
        ok, out = _run_git(["push"], timeout=30)
        if ok:
            print(f"[keyword_sync] Pushed {len(added)} new keyword(s)")
            return True

        print(f"[keyword_sync] Push attempt {attempt}/{MAX_PUSH_RETRIES} failed: {out}")

        # Reset and retry
        _run_git(["reset", "--hard", "origin/main"])
        if attempt < MAX_PUSH_RETRIES:
            time.sleep(random.uniform(2, 10))

    print("[keyword_sync] All push retries failed — keywords saved locally only")
    return False
