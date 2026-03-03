"""LLM prompt templates for LogLiefje AI error analysis."""

SYSTEM_PROMPT = """\
You are LogLiefje AI, an expert Nosana node log analyst. Your job is to:
1. Interpret known errors and explain their impact
2. Discover NEW error patterns not in the keyword database
3. Suggest causes and actionable fixes for operators
4. Identify healthy signals that confirm normal operation

Context: Nosana runs GPU compute jobs on a decentralized network. Each node runs:
- nosana-node: the main node process (Rust binary)
- frpc-*: reverse proxy tunnels for job connectivity
- Job containers: GPU workloads (lmdeploy, ollama, etc.)

The node interacts with Solana blockchain for job assignments and payments.

Be concise. Operators are not developers — use plain language for actions.
Do NOT invent errors that aren't in the logs. Only report what you see."""

ERROR_ANALYSIS_PROMPT = """\
Analyze these Nosana node logs for errors and issues.

== KNOWN ERRORS FOUND BY KEYWORD SCAN ==
{known_errors}

== UNCLASSIFIED LOG SECTIONS (may contain novel errors) ==
{unclassified_sections}

== CONTAINER STATE ==
{container_state}

Instructions:
1. For each known error: explain its impact and suggest a fix
2. Look for NEW error patterns in the unclassified sections that are NOT in the known keywords
3. Group related errors (e.g., multiple network errors = connectivity issue)
4. Note any concerning patterns (restart loops, escalating errors, resource exhaustion)
5. Identify healthy signals (stable uptimes, successful operations)

Respond in this exact JSON format:
{{
  "error_interpretations": [
    {{
      "pattern": "the error text or pattern",
      "severity": "FATAL|ERROR|WARN|INFO",
      "category": "network|solana|gpu|resource|crash|container|frpc|parsing|nosana|tls|permissions|process|hardware|stability",
      "cause": "brief root cause explanation",
      "action": "what the operator should do",
      "count": 0,
      "is_novel": false
    }}
  ],
  "novel_keywords": [
    {{
      "pattern": "new pattern to add to keyword database",
      "severity": "FATAL|ERROR|WARN|INFO",
      "category": "category",
      "description": "what this pattern means",
      "confidence": 0.0
    }}
  ],
  "healthy_signals": [
    "signal description"
  ],
  "summary": "one-line overall health assessment"
}}

IMPORTANT:
- Only suggest novel_keywords for patterns you actually found in the logs
- Set confidence 0.7-1.0 based on how certain you are this is a real error pattern
- Do NOT include patterns already in the known keywords list
- Keep patterns specific enough to avoid false positives
- Do NOT include specific IDs, hashes, wallet addresses, Solana pubkeys, or transaction signatures in novel patterns
- Use the shortest unique substring that reliably matches the error class
- If a novel keyword is a specific instance of a general pattern, only report the general one"""

KEYWORD_DISCOVERY_PROMPT = """\
Review these log lines that were NOT matched by any known error keyword.
Identify any that represent actual errors, warnings, or concerning patterns.

== UNMATCHED LOG LINES ==
{unmatched_lines}

== EXISTING KEYWORDS (do not duplicate) ==
{existing_patterns}

For each new error pattern you find, respond in this JSON format:
{{
  "novel_keywords": [
    {{
      "pattern": "the shortest unique string that identifies this error",
      "severity": "FATAL|ERROR|WARN|INFO",
      "category": "category",
      "description": "what this pattern means",
      "confidence": 0.0
    }}
  ]
}}

Rules:
- Only include patterns that represent REAL errors (not info messages, not success messages)
- The pattern should be the shortest unique substring that reliably matches the error
- Strip specific IDs, hashes, wallet addresses, Solana pubkeys, and transaction signatures from patterns
- Confidence: 0.9+ for obvious errors, 0.7-0.9 for likely errors, skip below 0.7
- Do NOT include patterns that match normal operation or success messages
- If no new patterns found, return {{"novel_keywords": []}}"""
