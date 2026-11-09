# Changelog

## v0.00.92 — 2026-11-09

- Compare the matched node's shared-network addresses with direct A and AAAA answers from inside its API proxy. Report the proxy's hosts-file entry for the route alias alongside its existing name lookup and HTTP wallet check.

## v0.00.91 — 2026-11-07

- Capture API proxy logs and check DNS from inside the matching FRPC and Nosana containers, including when the collector is launched as a single downloaded script.
- Compare local and public API responses in one timestamped snapshot before the bandwidth test. Each check reports its own result or reason it was unavailable.
- Add per-node qualification timelines and observed target markets. Preserve comparison operators and report explicit retests, access and queue/job events alongside the latest measurements.

## v0.00.72 — 2026-02-26
- **Added:** `--test` flag to route uploads to the test Slack channel instead of production. Usage: `bash LogLiefje.sh --test`

## v0.00.71 — 2026-02-26
- **Fixed:** Slack inline preview broken by binary/control bytes in uploaded `.txt` file. Added a final `perl` sanitization pass on `mylog.txt` before upload that strips all non-text bytes (NUL, ESC, control chars, DEL, invalid byte sequences) while preserving tab, newline, printable ASCII, and valid UTF-8.

## v0.00.70 — 2026-02-26
- **Fixed:** Slack `snippet_too_large` error on large log files (>1MB). Removed `snippet_type=text` from `files.getUploadURLExternal`; the `.txt` filename extension already provides inline text preview.
- **Fixed:** Litterbox intermittent HTTP 000 timeout on large uploads. Bumped `--max-time` from 30s to 120s.

## v0.00.69
- Baseline version (prior history not tracked in this changelog).
