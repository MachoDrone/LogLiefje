#!/usr/bin/env python3
"""LogLiefje AI — Nosana node log analysis pipeline.

Reads mylogs.txt, applies keyword scanning, runs LLM analysis,
discovers new keywords, and produces error-report.txt.

Version: 0.02.3
"""

import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
from collections import defaultdict
from pathlib import Path

from keyword_sync import pull_keywords, push_new_keywords
from prompts import ERROR_ANALYSIS_PROMPT, KEYWORD_DISCOVERY_PROMPT, SYSTEM_PROMPT
from report_formatter import format_report

VERSION = "0.02.7"
LLM_TIMEOUT = 600  # seconds — covers only LLM inference, not model download
INPUT_FILE = "/input/mylogs.txt"
OUTPUT_DIR = "/output"
OUTPUT_FILE = os.path.join(OUTPUT_DIR, "error-report.txt")
REPORT_MARKER = "===LOGLIEFJE_REPORT_START==="
REPORT_END_MARKER = "===LOGLIEFJE_REPORT_END==="
OLLAMA_URL = "http://localhost:11434"
MODEL_NAME_GPU = "qwen2.5:7b"
MODEL_NAME_CPU = "qwen2.5:3b"
MODEL_NAME = MODEL_NAME_GPU  # set after get_inference_mode()
MAX_LOG_LINES_TO_LLM = 500
MAX_UNCLASSIFIED_LINES = 200
KEYWORD_CONFIDENCE_THRESHOLD = 0.7


def get_node_id():
    """Get a node identifier from hostname or log content."""
    try:
        return socket.gethostname()
    except Exception:
        return "unknown"


def get_inference_mode():
    """Determine GPU vs CPU inference.

    Host already checks Nosana job status and VRAM — passes FORCE_CPU=1.
    Container only checks:
    1. FORCE_CPU env var → CPU
    2. nvidia-smi missing → CPU (belt-and-suspenders)
    3. All clear → GPU
    """
    # Step 1: forced CPU override (set by host detection)
    if os.environ.get("FORCE_CPU"):
        eprint("[analyze] Mode: CPU (forced via FORCE_CPU env)")
        return "cpu"

    # Step 2: check nvidia-smi exists and works (belt-and-suspenders)
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            eprint("[analyze] Mode: CPU (nvidia-smi returned non-zero)")
            return "cpu"
        gpu_name = result.stdout.strip().split("\n")[0].strip()
    except FileNotFoundError:
        eprint("[analyze] Mode: CPU (nvidia-smi not found)")
        return "cpu"
    except subprocess.TimeoutExpired:
        eprint("[analyze] Mode: CPU (nvidia-smi timed out)")
        return "cpu"

    # Step 3: all clear
    eprint(f"[analyze] Mode: GPU ({gpu_name})")
    return "gpu"


def start_ollama(mode):
    """Start ollama server with GPU or CPU mode."""
    env = os.environ.copy()
    if mode == "cpu":
        env["CUDA_VISIBLE_DEVICES"] = ""

    print(f"[analyze] Starting ollama in {mode.upper()} mode...", file=sys.stderr)
    proc = subprocess.Popen(
        ["ollama", "serve"],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    # Wait for ollama to be ready
    for i in range(30):
        try:
            result = subprocess.run(
                ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                 f"{OLLAMA_URL}/api/tags"],
                capture_output=True, text=True, timeout=5,
            )
            if result.stdout.strip() == "200":
                print("[analyze] Ollama is ready", file=sys.stderr)
                return proc
        except Exception:
            pass
        time.sleep(1)

    print("[analyze] WARNING: Ollama may not be fully ready", file=sys.stderr)
    return proc


def query_llm(prompt, system=SYSTEM_PROMPT):
    """Send a prompt to the local LLM via ollama API."""
    payload = json.dumps({
        "model": MODEL_NAME,
        "prompt": prompt,
        "system": system,
        "stream": False,
        "options": {
            "temperature": 0.3,
            "num_predict": 4096,
        },
    })

    try:
        result = subprocess.run(
            ["curl", "-s", "--max-time", "300", "-X", "POST",
             f"{OLLAMA_URL}/api/generate",
             "-H", "Content-Type: application/json",
             "-d", payload],
            capture_output=True, text=True, timeout=310,
        )
        if result.returncode == 0:
            response = json.loads(result.stdout)
            return response.get("response", "")
    except (subprocess.TimeoutExpired, json.JSONDecodeError, KeyError) as e:
        print(f"[analyze] LLM query failed: {e}", file=sys.stderr)

    return ""


def parse_log_sections(log_text):
    """Parse mylogs.txt into sections based on === headers ===.

    Returns list of (section_name, section_lines, start_line_number) tuples.
    """
    sections = []
    current_name = "header"
    current_lines = []
    current_start = 1

    for i, line in enumerate(log_text.split("\n"), 1):
        # Detect section headers like "=== container_name: ==="
        header_match = re.match(r"^=+\s*(.+?)\s*=+$", line)
        if header_match:
            if current_lines:
                sections.append((current_name, current_lines, current_start))
            current_name = header_match.group(1).strip()
            current_lines = []
            current_start = i + 1
        else:
            current_lines.append(line)

    if current_lines:
        sections.append((current_name, current_lines, current_start))

    return sections


def extract_container_state(log_text):
    """Extract container state information from logs.

    Looks for exit codes, restarts, uptime info, OOM events.
    """
    state = []

    # Exit codes
    for match in re.finditer(r"\[STOPPED exit:(\d+).*?ran (\d+d \d+h \d+m).*?stopped (\d+d \d+h \d+m)", log_text):
        state.append(f"Container stopped: exit code {match.group(1)}, ran {match.group(2)}, stopped {match.group(3)} ago")

    # Uptimes
    for match in re.finditer(r"(\d+ days?, \d+ hours?, \d+ minutes?).*?\[(.*?)\]", log_text):
        state.append(f"{match.group(2)}: uptime {match.group(1)}")

    # OOM events
    if re.search(r"OOM|out of memory|exit code 137", log_text, re.IGNORECASE):
        state.append("OOM event detected (exit code 137 or OOM-related messages)")

    return state


def keyword_scan(sections, keywords_data, patterns_data, false_positives_data):
    """Apply known keywords to log sections.

    Returns:
        found_errors: list of dicts with matched errors
        unclassified: list of (line_text, line_number, section_name) for unmatched lines
    """
    keywords = keywords_data.get("keywords", [])
    patterns = patterns_data.get("patterns", [])
    false_pos = {fp["pattern"].lower() for fp in false_positives_data.get("false_positives", [])}

    found_errors = []
    unclassified = []

    # Build keyword lookup
    kw_list = [(kw["pattern"], kw) for kw in keywords]

    for section_name, section_lines, start_line in sections:
        section_text = "\n".join(section_lines)

        # Check multi-line patterns first
        for pat in patterns:
            try:
                matches = list(re.finditer(pat["regex"], section_text, re.IGNORECASE))
                if matches:
                    found_errors.append({
                        "pattern": pat["name"].replace("_", " "),
                        "severity": pat["severity"],
                        "category": pat.get("category", "unknown"),
                        "cause": pat["description"],
                        "action": "",
                        "count": len(matches),
                        "container": section_name,
                        "line_ref": start_line + section_text[:matches[0].start()].count("\n"),
                        "is_novel": False,
                    })
            except re.error:
                pass

        # Check each line against keywords
        for i, line in enumerate(section_lines):
            line_lower = line.lower().strip()
            if not line_lower:
                continue

            # Check false positives first
            is_false_positive = any(fp in line_lower for fp in false_pos)
            if is_false_positive:
                continue

            matched = False
            for pattern, kw in kw_list:
                if pattern.lower() in line_lower:
                    found_errors.append({
                        "pattern": line.strip()[:200],
                        "severity": kw["severity"],
                        "category": kw.get("category", "unknown"),
                        "cause": kw["description"],
                        "action": "",
                        "count": 1,
                        "container": section_name,
                        "line_ref": start_line + i,
                        "is_novel": False,
                    })
                    matched = True
                    break

            if not matched and _looks_like_error(line):
                unclassified.append((line.strip(), start_line + i, section_name))

    # Deduplicate found errors by pattern + container
    deduped = _dedup_errors(found_errors)

    return deduped, unclassified


def _looks_like_error(line):
    """Heuristic: does this line look like it might contain an error?"""
    line_lower = line.lower()
    error_hints = [
        "error", "err!", "fail", "fatal", "panic", "crash",
        "exception", "traceback", "refused", "timeout", "denied",
        "killed", "abort", "segfault", "corrupt", "invalid",
        "cannot", "couldn't", "unable to", "not found",
    ]
    return any(hint in line_lower for hint in error_hints)


def _dedup_errors(errors):
    """Deduplicate errors by (pattern_prefix, container), summing counts."""
    key_map = {}
    for err in errors:
        # Use first 80 chars of pattern + container as dedup key
        key = (err["pattern"][:80].lower(), err.get("container", ""))
        if key in key_map:
            key_map[key]["count"] += err["count"]
        else:
            key_map[key] = err.copy()
    return list(key_map.values())


def run_llm_analysis(found_errors, unclassified, container_state, existing_keywords):
    """Run LLM analysis on the log data.

    Returns (error_interpretations, novel_keywords, healthy_signals, summary).
    """
    # Format known errors for LLM context
    if found_errors:
        known_str = "\n".join(
            f"[{e['severity']}] {e['container']}: {e['pattern'][:150]} (x{e['count']})"
            for e in found_errors[:50]
        )
    else:
        known_str = "(none found)"

    # Format unclassified sections (sample)
    if unclassified:
        sample = unclassified[:MAX_UNCLASSIFIED_LINES]
        unclass_str = "\n".join(
            f"  line {ln}: [{sec}] {text[:200]}"
            for text, ln, sec in sample
        )
    else:
        unclass_str = "(all lines classified)"

    # Format container state
    state_str = "\n".join(container_state) if container_state else "(no state info)"

    # Build and send prompt
    prompt = ERROR_ANALYSIS_PROMPT.format(
        known_errors=known_str,
        unclassified_sections=unclass_str,
        container_state=state_str,
    )

    eprint("[analyze] Querying LLM for error analysis...")
    response = query_llm_with_spinner(prompt)

    if not response:
        eprint("[analyze] LLM returned empty response — using keyword-only results")
        return [], [], [], "LLM analysis unavailable — keyword scan only"

    # Parse JSON from LLM response
    return _parse_llm_response(response, existing_keywords)


def _parse_llm_response(response, existing_keywords):
    """Parse the LLM's JSON response, handling markdown code blocks."""
    # Try to extract JSON from markdown code blocks
    json_match = re.search(r"```(?:json)?\s*(\{[\s\S]*?\})\s*```", response)
    if json_match:
        json_str = json_match.group(1)
    else:
        # Try to find raw JSON
        json_match = re.search(r"\{[\s\S]*\}", response)
        if json_match:
            json_str = json_match.group(0)
        else:
            eprint("[analyze] Could not extract JSON from LLM response")
            return [], [], [], "LLM response unparseable"

    try:
        data = json.loads(json_str)
    except json.JSONDecodeError as e:
        eprint(f"[analyze] JSON parse error: {e}")
        return [], [], [], "LLM response unparseable"

    interpretations = data.get("error_interpretations", [])
    novel = data.get("novel_keywords", [])
    healthy = data.get("healthy_signals", [])
    summary = data.get("summary", "Analysis complete")

    # Filter novel keywords by confidence threshold and existing patterns
    existing_patterns = {kw["pattern"].lower() for kw in existing_keywords}
    filtered_novel = [
        kw for kw in novel
        if kw.get("confidence", 0) >= KEYWORD_CONFIDENCE_THRESHOLD
        and kw.get("pattern", "").lower() not in existing_patterns
    ]

    return interpretations, filtered_novel, healthy, summary


def run_keyword_discovery(unclassified, existing_keywords):
    """Run a second LLM pass focused on discovering new keywords."""
    if not unclassified:
        return []

    sample = unclassified[:MAX_UNCLASSIFIED_LINES]
    unmatched_str = "\n".join(f"  {text[:200]}" for text, _, _ in sample)
    existing_str = ", ".join(kw["pattern"] for kw in existing_keywords[:100])

    prompt = KEYWORD_DISCOVERY_PROMPT.format(
        unmatched_lines=unmatched_str,
        existing_patterns=existing_str,
    )

    eprint("[analyze] Querying LLM for keyword discovery...")
    response = query_llm_with_spinner(prompt)

    if not response:
        return []

    # Parse response
    json_match = re.search(r"```(?:json)?\s*(\{[\s\S]*?\})\s*```", response)
    if json_match:
        json_str = json_match.group(1)
    else:
        json_match = re.search(r"\{[\s\S]*\}", response)
        if not json_match:
            return []
        json_str = json_match.group(0)

    try:
        data = json.loads(json_str)
    except json.JSONDecodeError:
        return []

    existing_patterns = {kw["pattern"].lower() for kw in existing_keywords}
    return [
        kw for kw in data.get("novel_keywords", [])
        if kw.get("confidence", 0) >= KEYWORD_CONFIDENCE_THRESHOLD
        and kw.get("pattern", "").lower() not in existing_patterns
    ]


def build_error_list(keyword_errors, llm_interpretations, novel_keywords):
    """Merge keyword scan results with LLM interpretations into final error list."""
    errors = []

    # Add keyword-matched errors, enriched with LLM interpretations
    interp_map = {}
    for interp in llm_interpretations:
        pat = interp.get("pattern", "").lower()[:80]
        interp_map[pat] = interp

    for err in keyword_errors:
        key = err["pattern"].lower()[:80]
        if key in interp_map:
            llm = interp_map[key]
            err["cause"] = llm.get("cause", err.get("cause", ""))
            err["action"] = llm.get("action", "")
        errors.append(err)

    # Add novel errors from LLM (not already in keyword results)
    existing_patterns = {e["pattern"].lower()[:80] for e in errors}
    for interp in llm_interpretations:
        if interp.get("is_novel") and interp.get("pattern", "").lower()[:80] not in existing_patterns:
            errors.append({
                "pattern": interp.get("pattern", ""),
                "severity": interp.get("severity", "WARN"),
                "category": interp.get("category", "unknown"),
                "cause": interp.get("cause", ""),
                "action": interp.get("action", ""),
                "count": interp.get("count", 1),
                "container": "",
                "line_ref": "",
                "is_novel": True,
            })

    # Add novel keywords as NEW entries
    for kw in novel_keywords:
        pat = kw.get("pattern", "").lower()[:80]
        if pat not in existing_patterns:
            errors.append({
                "pattern": kw.get("pattern", ""),
                "severity": kw.get("severity", "WARN"),
                "category": kw.get("category", "unknown"),
                "cause": kw.get("description", ""),
                "action": "New pattern discovered by AI — monitor frequency",
                "count": 1,
                "container": "",
                "line_ref": "",
                "is_novel": True,
            })

    # Sort by severity
    sev_order = {"FATAL": 0, "ERROR": 1, "WARN": 2, "STATE": 3, "INFO": 4, "NEW": 5}
    errors.sort(key=lambda e: sev_order.get(e.get("severity", "INFO"), 4))

    return errors


def prepare_keywords_for_push(novel_keywords):
    """Format novel keywords for pushing to the keyword repo."""
    today = time.strftime("%Y-%m-%d")
    return [
        {
            "pattern": kw["pattern"],
            "severity": kw.get("severity", "WARN"),
            "category": kw.get("category", "unknown"),
            "description": kw.get("description", "AI-discovered pattern"),
            "source": "ai",
            "discovered": today,
            "confidence": kw.get("confidence", 0.7),
            "occurrences": 1,
        }
        for kw in novel_keywords
    ]


def eprint(*args, **kwargs):
    """Print to stderr (diagnostic output)."""
    print(*args, file=sys.stderr, **kwargs)


def _spinner(stop_event):
    """Display a spinning indicator on stderr while waiting."""
    chars = '|/-\\'
    i = 0
    while not stop_event.is_set():
        sys.stderr.write(f'\r  {chars[i % len(chars)]}')
        sys.stderr.flush()
        stop_event.wait(0.3)
        i += 1
    sys.stderr.write('\r   \r')
    sys.stderr.flush()


def query_llm_with_spinner(prompt, system=SYSTEM_PROMPT):
    """Wrap query_llm with a spinner for visual feedback."""
    stop = threading.Event()
    t = threading.Thread(target=_spinner, args=(stop,), daemon=True)
    t.start()
    try:
        return query_llm(prompt, system)
    finally:
        stop.set()
        t.join(timeout=2)


def main():
    """Main analysis pipeline."""
    eprint(f"[LogLiefje AI v{VERSION}]")

    # 1. Read input
    if not os.path.exists(INPUT_FILE):
        eprint(f"[analyze] ERROR: {INPUT_FILE} not found")
        sys.exit(1)

    with open(INPUT_FILE) as f:
        log_text = f.read()
    eprint(f"[analyze] Read {len(log_text)} bytes from {INPUT_FILE}")

    # 2. Pull keywords
    eprint("[analyze] Pulling keywords from repository...")
    keywords_data, patterns_data, false_positives_data = pull_keywords()
    keywords_loaded = len(keywords_data.get("keywords", []))
    eprint(f"[analyze] Loaded {keywords_loaded} keywords")

    # 3. Parse log sections
    sections = parse_log_sections(log_text)
    eprint(f"[analyze] Parsed {len(sections)} log sections")

    # 4. Extract container state
    container_state = extract_container_state(log_text)

    # 5. Keyword scan
    eprint("[analyze] Running keyword scan...")
    found_errors, unclassified = keyword_scan(
        sections, keywords_data, patterns_data, false_positives_data
    )
    eprint(f"[analyze] Keyword scan: {len(found_errors)} errors, {len(unclassified)} unclassified lines")

    # 6. Determine inference mode, select model, start LLM
    mode = get_inference_mode()
    global MODEL_NAME
    MODEL_NAME = MODEL_NAME_CPU if mode == "cpu" else MODEL_NAME_GPU
    eprint(f"[analyze] Using model: {MODEL_NAME}")
    if mode == "cpu":
        eprint("[analyze] CPU mode (3b) — please wait...")
    ollama_proc = start_ollama(mode)

    def _llm_timeout_handler(signum, frame):
        raise TimeoutError("LLM inference exceeded time limit")

    try:
        # Start LLM timeout (covers only inference, not model download/startup)
        signal.signal(signal.SIGALRM, _llm_timeout_handler)
        signal.alarm(LLM_TIMEOUT)
        eprint(f"[analyze] LLM timeout: {LLM_TIMEOUT}s starts now")

        # 7. LLM analysis
        existing_kws = keywords_data.get("keywords", [])
        interpretations, novel_kws_1, healthy_signals, summary = run_llm_analysis(
            found_errors, unclassified, container_state, existing_kws
        )

        # 8. Keyword discovery pass
        novel_kws_2 = run_keyword_discovery(unclassified, existing_kws)

        signal.alarm(0)  # Cancel timeout — LLM work finished

        # Merge novel keywords from both passes
        seen = set()
        all_novel = []
        for kw in novel_kws_1 + novel_kws_2:
            pat = kw.get("pattern", "").lower()
            if pat not in seen:
                seen.add(pat)
                all_novel.append(kw)

        eprint(f"[analyze] LLM analysis complete: {len(interpretations)} interpretations, {len(all_novel)} novel keywords")

    except TimeoutError:
        signal.alarm(0)
        eprint(f"[analyze] LLM timed out after {LLM_TIMEOUT}s — using keyword-only results")
        interpretations, novel_kws_1, healthy_signals = [], [], []
        summary = "LLM timed out — keyword scan only"
        all_novel = []

    finally:
        # Stop ollama
        if ollama_proc:
            ollama_proc.terminate()
            try:
                ollama_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                ollama_proc.kill()

    # 9. Build final error list
    errors = build_error_list(found_errors, interpretations, all_novel)

    # 10. Push new keywords
    if all_novel:
        push_kws = prepare_keywords_for_push(all_novel)
        node_id = get_node_id()
        push_new_keywords(push_kws, node_id=node_id)

    # 11. Generate report
    node_id = get_node_id()
    report = format_report(
        errors=errors,
        novel_keywords=all_novel,
        healthy_signals=healthy_signals if healthy_signals else _default_healthy_signals(log_text),
        summary=summary,
        node_id=node_id,
        model_name=MODEL_NAME,
        inference_mode=mode,
        keywords_loaded=keywords_loaded,
        keywords_new=len(all_novel),
    )

    # 12. Write output (file stays inside container, vanishes with --rm)
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    with open(OUTPUT_FILE, "w") as f:
        f.write(report)

    print(f"[analyze] Report written to {OUTPUT_FILE}", file=sys.stderr)
    print(f"[analyze] Done — {len(errors)} errors, {len(all_novel)} new keywords", file=sys.stderr)

    # 13. Print report to stdout (captured by LogLiefje-ai.sh)
    print(REPORT_MARKER)
    print(report)
    print(REPORT_END_MARKER)


def _default_healthy_signals(log_text):
    """Extract basic healthy signals from log text when LLM doesn't provide them."""
    signals = []

    # Check for uptime info
    uptime_match = re.search(r"(\d+) days?, (\d+) hours?.*?nosana.node", log_text)
    if uptime_match:
        signals.append(f"nosana-node uptime: {uptime_match.group(1)}d {uptime_match.group(2)}h")

    # Check for successful connections
    if "login to server success" in log_text.lower():
        signals.append("frpc tunnel connected successfully")

    # Check GPU detection
    if "Driver:" in log_text:
        signals.append("NVIDIA GPU detected and responsive")

    if not signals:
        signals.append("Log collection completed successfully")

    return signals


if __name__ == "__main__":
    main()
