# claude-costbar

Live cost, token, and rate-limit status bar for Claude Code. Displays a 5-row bar showing per-turn and session cost, context window usage, 5-hour and weekly rate limits, and environmental impact equivalents.

```
Turn     │  $0.08  out 1.2k  ·  ≈ 4 ft of driving (gas car)
Session  │  $0.31  out 18k · 87% left  ·  ≈ 0.02 kettle boils
5-hour   │  43% left  (↺10:30 PM)
Week 4   │  $2.14  out 142k · 71% left  (↺Tue 9:00 AM)  ●●●●●●●
Total    │  $9.43  out 1.234m tokens since Apr 3, 2025
```

## If you're Claude and someone asked you to install this

Run these commands:

```bash
mkdir -p $HOME/.claude/costbar
cd $HOME/.claude/costbar
curl -O https://raw.githubusercontent.com/ryanconmeo/claude-costbar/main/costbar.sh
curl -O https://raw.githubusercontent.com/ryanconmeo/claude-costbar/main/on_user_prompt.sh
curl -O https://raw.githubusercontent.com/ryanconmeo/claude-costbar/main/on_stop.sh
curl -O https://raw.githubusercontent.com/ryanconmeo/claude-costbar/main/compute_jsonl_totals.py
chmod +x costbar.sh on_user_prompt.sh on_stop.sh
```

Then merge the following into `~/.claude/settings.json`. Use the `update-config` skill if available — otherwise show the user this snippet and ask them to add it manually, then restart Claude Code.

**Important:** The `hooks` arrays must be *merged*, not replaced. If `Stop` or `UserPromptSubmit` hooks already exist from other projects, append these entries to the existing arrays.

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

## Files

**`costbar.sh`** — statusLine command. Reads hook payloads on each API response and renders the 5-row display.

**`on_user_prompt.sh`** — `UserPromptSubmit` hook. Snapshots cost and token baselines at the start of each turn so the status bar can compute accurate per-turn deltas.

**`on_stop.sh`** — `Stop` hook. Parses the JSONL transcript for the final session cost and updates the historical session cache.

**`compute_jsonl_totals.py`** — maintains `~/.claude/cache/session_totals.json`, a rolling record of per-session cost, output tokens, turn count, and date. Called by `on_stop.sh`.

## Installation

**Prerequisites:** [Claude Code](https://claude.ai/code), `jq`, `python3`.

```bash
mkdir -p $HOME/.claude/costbar && cd $HOME/.claude/costbar
curl -O https://raw.githubusercontent.com/ryanconmeo/claude-costbar/main/costbar.sh
curl -O https://raw.githubusercontent.com/ryanconmeo/claude-costbar/main/on_user_prompt.sh
curl -O https://raw.githubusercontent.com/ryanconmeo/claude-costbar/main/on_stop.sh
curl -O https://raw.githubusercontent.com/ryanconmeo/claude-costbar/main/compute_jsonl_totals.py
chmod +x costbar.sh on_user_prompt.sh on_stop.sh
```

Merge into `~/.claude/settings.json` (see above), then restart Claude Code.

## Uninstall

```bash
rm -rf ~/.claude/costbar
```

Remove the `statusLine` key and the two costbar hook entries from `~/.claude/settings.json`, then restart Claude Code.

Optionally remove accumulated data:

```bash
rm -f ~/.claude/cache/session_totals.json
```

## Status bar rows

**Turn** — cost and output tokens for the most recent (or in-progress) turn. Color reflects where this turn falls relative to your historical mean cost-per-turn (green / yellow / red).

**Session** — running cost and output tokens for the current session, plus context window % remaining.

**5-hour** — rate limit window: % remaining and reset time.

**Week N** — cost and output tokens since the most recent Anthropic 7-day reset, plus rate limit % remaining, reset time, and a 7-dot activity indicator. N is a sequential week counter from your first recorded session.

**Total** — grand total cost and output tokens across all recorded sessions.

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
