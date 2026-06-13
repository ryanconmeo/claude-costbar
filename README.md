# claude-costbar

Live cost, token, and rate-limit status bar for Claude Code. Displays a header line with the current model (always shown) plus a 5-row bar showing per-turn and session cost, context window usage, 5-hour and weekly rate limits, and environmental impact equivalents.

```
⏺ Opus 4.8
Turn     │  $0.08  out 1.2k  ·  ≈ 4 ft of driving (gas car)
Session  │  $0.31  out 18k · 87% left  ·  ≈ 0.02 kettle boils
5-hour   │  43% left  (↺10:30 PM)
Week 4   │  $2.14  out 142k · 71% left  (↺Tue 9:00 AM)  ●●●●●●●
Total    │  $9.43  out 1.234m tokens since Apr 3, 2025
```

The header line carries a violet model badge — deliberately off the cost-row palette so it reads as a separate banner. It always shows the model on its own; an optional pluggable segment (current task, git branch, …) can be appended to it — see [Header line](#header-line).

## If you're Claude and someone asked you to install this

Run these commands:

```bash
git clone https://github.com/ryanconmeo/claude-costbar "$HOME/.claude/costbar"
```

If `~/.claude/` is a git repo, add `costbar/` to its `.gitignore` so the nested repo doesn't interfere. Skip this if `~/.claude/.gitignore` uses an allowlist style (`*` with explicit `!file` entries) — in that case the subdirectory is already ignored.

```bash
if [ -d "$HOME/.claude/.git" ]; then
  grep -qxF 'costbar/' "$HOME/.claude/.gitignore" 2>/dev/null || echo 'costbar/' >> "$HOME/.claude/.gitignore"
fi
```

Then merge the following into `~/.claude/settings.json`. Use the `update-config` skill if available — otherwise show the user this snippet and ask them to add it manually, then restart Claude Code.

**The `hooks` arrays must be merged, not replaced.** If `Stop` or `UserPromptSubmit` hooks already exist from other projects, append these entries to the existing arrays.

```json
"statusLine": {
  "type": "command",
  "command": "bash $HOME/.claude/costbar/costbar.sh"
},
"hooks": {
  "Stop": [{"matcher": "", "hooks": [
    {"type": "command", "command": "bash $HOME/.claude/costbar/on_stop.sh"}
  ]}],
  "UserPromptSubmit": [{"matcher": "", "hooks": [
    {"type": "command", "command": "bash $HOME/.claude/costbar/on_user_prompt.sh"}
  ]}]
}
```

Restart Claude Code after saving.

## Install

**Prerequisites:** [Claude Code](https://claude.ai/code), `git`, `jq`, `python3`.

```bash
git clone https://github.com/ryanconmeo/claude-costbar "$HOME/.claude/costbar"
```

If `~/.claude/` is a git repo with a permissive `.gitignore`, append `costbar/` to it:

```bash
if [ -d "$HOME/.claude/.git" ]; then
  grep -qxF 'costbar/' "$HOME/.claude/.gitignore" 2>/dev/null || echo 'costbar/' >> "$HOME/.claude/.gitignore"
fi
```

Merge the `settings.json` snippet above, then restart Claude Code.

**No git?** Install with curl instead:

```bash
mkdir -p "$HOME/.claude/costbar" && cd "$HOME/.claude/costbar"
curl -O https://raw.githubusercontent.com/ryanconmeo/claude-costbar/main/costbar.sh
curl -O https://raw.githubusercontent.com/ryanconmeo/claude-costbar/main/on_user_prompt.sh
curl -O https://raw.githubusercontent.com/ryanconmeo/claude-costbar/main/on_stop.sh
curl -O https://raw.githubusercontent.com/ryanconmeo/claude-costbar/main/compute_jsonl_totals.py
chmod +x costbar.sh on_user_prompt.sh on_stop.sh
```

## Update

```bash
cd "$HOME/.claude/costbar" && git pull
```

## Uninstall

```bash
rm -rf "$HOME/.claude/costbar"
```

Remove the `statusLine` key and the two costbar hook entries from `~/.claude/settings.json`, then restart Claude Code. Optionally remove accumulated data:

```bash
rm -f ~/.claude/cache/session_totals.json
```

## Header line

The first line always shows the current model (`⏺ Opus 4.8`). costbar owns only the model badge — it knows nothing about whatever gets appended after it.

To append more after the model (current task, git branch, k8s context, …), set the `COSTBAR_HEADER_CMD` environment variable to any shell command. costbar runs it with two variables exported and appends its stdout — which may carry its own ANSI colors — after a ` — ` separator:

| Variable | Meaning |
|----------|---------|
| `COSTBAR_SESSION_ID` | the current session id |
| `COSTBAR_HEADER_BUDGET` | visible columns left on the line, for truncation |

Unset → just the model shows. The command is fully generic; costbar never assumes what it returns. Example wiring (in `~/.claude/settings.json`) that appends a one-line segment from a provider of your choosing:

```json
"statusLine": {
  "type": "command",
  "command": "COSTBAR_HEADER_CMD='my-header-provider --session \"$COSTBAR_SESSION_ID\" --width \"$COSTBAR_HEADER_BUDGET\"' bash $HOME/.claude/costbar/costbar.sh"
}
```

## Files

**`costbar.sh`** — statusLine command. Reads hook payloads on each API response and renders the header line plus the 5-row display.

**`on_user_prompt.sh`** — `UserPromptSubmit` hook. Snapshots cost and token baselines at the start of each turn so the bar can compute accurate per-turn deltas.

**`on_stop.sh`** — `Stop` hook. Parses the JSONL transcript for the final session cost and updates the historical session cache.

**`compute_jsonl_totals.py`** — maintains `~/.claude/cache/session_totals.json`, a rolling record of per-session cost, output tokens, turn count, and date. Called by `on_stop.sh`.

## How cost is computed

| Row | Source |
|-----|--------|
| Turn / Session | `cost.total_cost_usd` from Claude Code hook payload (authoritative) |
| Week / Total | `session_totals.json` (JSONL-reconstructed) + current session payload |

### Hardcoded rates (for historical cache)

| Model | Input | Output | Cache read | Cache write |
|-------|-------|--------|------------|-------------|
| Opus 4.7 | $15/M | $75/M | $1.50/M | $18.75/M |
| Sonnet 4.6 | $3/M | $15/M | $0.30/M | $3.75/M |
| Haiku 4.5 | $0.80/M | $4/M | $0.08/M | $1.00/M |
