"""Error report formatter for LogLiefje AI."""

import time
from collections import defaultdict


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
    """Format the final error report.

    Args:
        errors: list of error dicts with severity, pattern, cause, action, count, container
        novel_keywords: list of newly discovered keyword dicts
        healthy_signals: list of healthy signal strings
        summary: one-line health assessment
        node_id: hostname or identifier
        model_name: LLM model used
        inference_mode: "gpu" or "cpu"
        keywords_loaded: number of keywords loaded from repo
        keywords_new: number of new keywords discovered

    Returns:
        Formatted report string
    """
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
        c = err.get("container", "")
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
                container = err.get("container", "unknown")
                count = err.get("count", 1)
                count_str = f"  ({count}x)" if count > 1 else ""

                tag = sev
                if err.get("is_novel"):
                    tag = "NEW"

                lines.append(f"[{tag}] {container}{count_str}")
                lines.append(f"  {err.get('pattern', 'unknown error')}")
                if err.get("cause"):
                    lines.append(f"  CAUSE: {err['cause']}")
                if err.get("action"):
                    lines.append(f"  ACTION: {err['action']}")
                if err.get("line_ref"):
                    lines.append(f"  -> Context at mylogs.txt line ~{err['line_ref']}")
                if err.get("is_novel") and err.get("pattern"):
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

    # Novel keyword summary
    if novel_keywords:
        lines.append(f"=== NEW PATTERNS DISCOVERED ({len(novel_keywords)}) ===")
        for kw in novel_keywords:
            conf = kw.get("confidence", 0)
            lines.append(f"  + \"{kw.get('pattern', '')}\" [{kw.get('severity', 'INFO')}] (confidence: {conf:.0%})")
            lines.append(f"    {kw.get('description', '')}")
        lines.append("")

    lines.append("=" * 60)
    lines.append("  END REPORT")
    lines.append("=" * 60)

    return "\n".join(lines)
