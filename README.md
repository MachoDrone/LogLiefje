# LogLiefje

Collect host, GPU, container, and Nosana diagnostics on the affected Ubuntu host. Run this in Bash from a directory where the collector can write `mylog.txt`:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/MachoDrone/LogLiefje/refs/heads/main/LogLiefje.sh)
```

The standard command collects and uploads the report. Append `--no-upload` to keep the report local or `--test` to route the Slack upload to the test channel. The default node-log excerpt includes startup and the last 48 hours. Append `--100` to include older retained history, subject to the report size limit.

On a Docker host running Nosana inside Podman, v0.00.91 takes a timestamped snapshot from the node and its matching API proxy before the host bandwidth test. Read the DNS and API results for each container alongside the retained FRPC log. A skipped check gives the reason. The per-node qualification timeline shows the decision and speeds printed by the node at each observation. The same measurement can appear in several evaluations.
