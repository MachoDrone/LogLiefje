"""Error report formatter for LogLiefje AI."""

import re
import time
from collections import defaultdict


def _format_date_range(timestamps):
    """Format a list of ISO timestamps into a compact date range.

    Returns 'Feb 25 - Mar 3', 'Mar 1', or '' if no timestamps.
    """
    if not timestamps:
        return ""
    # Parse dates from timestamps (format: 2026-02-25T10:30:00 or 2026-02-25 10:30:00)
    dates = set()
    for ts in timestamps:
        m = re.match(r"(\d{4})-(\d{2})-(\d{2})", str(ts))
        if m:
            dates.add((int(m.group(1)), int(m.group(2)), int(m.group(3))))
    if not dates:
        return ""

    months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    sorted_dates = sorted(dates)
    first = sorted_dates[0]
    last = sorted_dates[-1]

    if first == last:
        return f"{months[first[1]]} {first[2]}"
    if first[1] == last[1] and first[0] == last[0]:
        return f"{months[first[1]]} {first[2]} - {last[2]}"
    return f"{months[first[1]]} {first[2]} - {months[last[1]]} {last[2]}"


def _format_line_refs(line_refs):
    """Format line references as a compact list, capped at 5.

    Returns '~203, ~211, ~380, ~533, ~915 (+6 more)' or ''.
    """
    refs = [r for r in line_refs if r]
    if not refs:
        return ""
    refs_sorted = sorted(set(refs))
    shown = refs_sorted[:5]
    parts = ", ".join(f"~{r}" for r in shown)
    if len(refs_sorted) > 5:
        parts += f" (+{len(refs_sorted) - 5} more)"
    return parts


def format_report(
    errors,
    novel_keywords,
    healthy_signals,
    summary,
    node_id="unknown",
    model_name="qwen2.5:7b",
    inference_mode="cpu",
    keywords_loaded=0,
    keywords_new=0,
):
    """Format the final error report."""
    lines = []
    ts = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())

    # Header
    lines.append("=" * 60)
    lines.append("  LOGLIEFJE AI ERROR REPORT")
    lines.append("=" * 60)
    lines.append(f"Generated: {ts}")
    lines.append(f"Node: {node_id} | Model: {model_name} | Mode: {inference_mode.upper()}")
    lines.append(f"Keywords: {keywords_loaded} loaded ({keywords_new} new discovered)")
    lines.append(f"Assessment: {summary}")
    lines.append("")

    # Group errors by severity
    severity_order = ["FATAL", "ERROR", "WARN", "INFO", "STATE", "NEW"]
    errors_by_severity = defaultdict(list)
    for err in errors:
        sev = err.get("severity", "INFO")
        errors_by_severity[sev].append(err)

    # Count unique errors and affected containers
    unique_errors = len(errors)
    containers = set()
    for err in errors:
        c = err.get("container_short", err.get("container", ""))
        if c:
            containers.add(c)

    if errors:
        container_str = f" across {len(containers)} container(s)" if containers else ""
        lines.append(f"=== ERRORS FOUND ({unique_errors} unique{container_str}) ===")
        lines.append("")

        for sev in severity_order:
            if sev not in errors_by_severity:
                continue
            for err in errors_by_severity[sev]:
                tag = sev
                if err.get("is_novel"):
                    tag = "NEW"

                if err.get("is_novel"):
                    # Novel entries: simple [NEW] header
                    lines.append(f"[{tag}]")
                else:
                    # Known errors: [SEV] short_container (Nx, date range)
                    container_short = err.get("container_short", err.get("container", "unknown"))
                    count = err.get("count", 1)
                    date_range = _format_date_range(err.get("timestamps", []))

                    meta_parts = []
                    if count > 1:
                        meta_parts.append(f"{count}x")
                    if date_range:
                        meta_parts.append(date_range)
                    meta_str = f" ({', '.join(meta_parts)})" if meta_parts else ""

                    lines.append(f"[{tag}] {container_short}{meta_str}")

                # Error text (keyword, not full log line)
                lines.append(f"  {err.get('pattern', 'unknown error')}")

                if err.get("cause"):
                    lines.append(f"  CAUSE: {err['cause']}")
                if err.get("action"):
                    lines.append(f"  ACTION: {err['action']}")

                # Line refs (consolidated list)
                ref_str = _format_line_refs(err.get("line_refs", []))
                if ref_str:
                    lines.append(f"  -> Lines: {ref_str}")

                # Novel keyword info with confidence
                if err.get("is_novel") and err.get("pattern"):
                    conf = err.get("confidence", 0)
                    if conf:
                        lines.append(f"  -> New keyword added: \"{err['pattern']}\" (confidence: {conf:.0%})")
                    else:
                        lines.append(f"  -> New keyword added: \"{err['pattern']}\"")

                lines.append("")
    else:
        lines.append("=== NO ERRORS FOUND ===")
        lines.append("")
        lines.append("No known error patterns detected in the logs.")
        lines.append("")

    # Healthy signals
    if healthy_signals:
        lines.append("=== HEALTHY SIGNALS ===")
        for signal in healthy_signals:
            lines.append(f"  - {signal}")
        lines.append("")

    # NEW PATTERNS DISCOVERED section removed — already shown as [NEW] entries above

    lines.append("=" * 60)
    lines.append("  END REPORT")
    lines.append("=" * 60)

    return "\n".join(lines)
