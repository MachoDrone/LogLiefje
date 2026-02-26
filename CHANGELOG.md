# Changelog

## v0.00.70 — 2026-02-26
- **Fixed:** Slack `snippet_too_large` error on large log files (>1MB). Removed `snippet_type=text` from `files.getUploadURLExternal`; the `.txt` filename extension already provides inline text preview.
- **Fixed:** Litterbox intermittent HTTP 000 timeout on large uploads. Bumped `--max-time` from 30s to 120s.

## v0.00.69
- Baseline version (prior history not tracked in this changelog).
