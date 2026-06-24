# Status-line composition — design context (for later)

> **Status: design note, not yet implemented.** No costbar code has changed for this.
> This captures a design worked out alongside task-station so it's ready when costbar
> is picked back up (and eventually turned into its own Claude Code plugin).

## The problem

Claude Code exposes exactly **one** `statusLine.command`. Multiple tools want to show
something there (costbar's cost rows, a current-task segment, git branch, k8s context …),
but only one program can own the line. There is no native multi-segment composition, so a
convention is needed — and it must not force everyone to depend on costbar.

## The convention (two roles, one contract)

A small, vendor-neutral standard. **task-station is the reference implementation** — see
its `docs/STATUSLINE.md` and `lib/statusline-host.sh` in
<https://github.com/ryanconmeo/task-station> (shipped in task-station 1.13.0). The full
spec lives there; the essentials:

- **Provider** — an executable in `${CLAUDE_CONFIG_DIR:-~/.claude}/statusline.d/`, run in
  lexical (`NN-name`) order. It receives the **statusLine JSON on stdin** (the same shape
  Claude Code pipes to `statusLine.command`: `session_id`, `cwd`, `model`, `cost`,
  `context_window`, `rate_limits`, …) plus an optional env `CLAUDE_STATUSLINE_WIDTH`
  (visible columns, for truncation). It prints **one line** to stdout. **Empty output or a
  non-zero exit ⇒ skipped** (a broken provider never breaks the bar). A provider is itself
  a valid `statusLine.command`.
- **Host** — owns `statusLine.command`. Reads the JSON, runs every `statusline.d/*` with
  that JSON on stdin + `CLAUDE_STATUSLINE_WIDTH`, collects the non-empty lines, joins them
  with `CLAUDE_STATUSLINE_SEP` (default `  │  `), and may add its own content. A host
  writes a **marker** into its command — `# claude-statusline-host:<name>` — so other
  installers can detect that a conformant host already owns the bar.
- **The compose routine is ~30 lines and is *embedded* by each host** — there is no shared
  "conductor" package to install. (task-station embeds it in `lib/statusline-host.sh`;
  costbar will embed its own copy.) This is deliberate: zero install-time dependency
  between plugins.

### Non-destructive install rule (every host installer follows this)

```
if statusLine.command is UNSET            -> install self as host (write marker)
elif it carries a host marker             -> do NOT take over; just ensure my provider is in statusline.d/
else (an unknown / hand-rolled command)   -> do NOT clobber; register my provider + tell the user how to compose
```

Detection is **marker-based, not name-based** — costbar never hard-codes "task-station"
and task-station never hard-codes "costbar". They only ever ask "is a conformant host
already here?"

## Where costbar sits: a HOST, not *the* conductor

costbar should be **one host among potentially several**, never a mandatory conductor the
ecosystem depends on. When costbar is installed it's the richest bar, so it naturally wins
host precedence and owns `statusLine.command`; other tools (task-station, …) detect
costbar's marker and register as *providers* only. When costbar is **not** installed,
task-station's own opt-in host (or a neutral mux) owns the bar instead. Nothing requires
costbar.

### costbar is already ~90% there

- It already **consumes the contract**: `input=$(cat)` then `jq` for `session_id`, `cost`,
  `model`, `context_window`, `rate_limits` — i.e. it already speaks the statusLine
  stdin-JSON.
- It already **owns only its own turf** (model badge + cost rows) and treats appended
  content as opaque.
- It already has a generic, assumption-free append slot: `COSTBAR_HEADER_CMD`
  (`costbar.sh` ~line 506-511), and it's already **error-isolated** (`2>/dev/null` + empty
  check) — exactly the spec's "empty/non-zero ⇒ skip".

### What costbar needs to become a conformant host (the actual work, for later)

1. **Generalize the header slot from one command to full `statusline.d/` composition.**
   Today it runs a single `COSTBAR_HEADER_CMD`. Instead, embed the compose routine: run
   every executable in `${CLAUDE_CONFIG_DIR:-~/.claude}/statusline.d/` (lexical order),
   pipe `$input` to each on stdin, export `CLAUDE_STATUSLINE_WIDTH`, collect non-empty
   stdout, join with `CLAUDE_STATUSLINE_SEP`, append after the model badge. Keep
   `COSTBAR_HEADER_CMD` as a back-compat single-slot option (or deprecate it).
   - Reference implementation to mirror: task-station `lib/statusline-host.sh` (~30 lines).
2. **Feed providers the standard contract.** The current slot passes only
   `COSTBAR_SESSION_ID` / `COSTBAR_HEADER_BUDGET` as env and does **not** pipe stdin. Pipe
   the statusLine JSON (`$input`) to each provider on stdin and export
   `CLAUDE_STATUSLINE_WIDTH` (keep `COSTBAR_SESSION_ID`/`COSTBAR_HEADER_BUDGET` as
   back-compat aliases). This is roughly the `costbar.sh` line ~510 change:
   ```bash
   # before: extra=$(bash -c "$COSTBAR_HEADER_CMD" 2>/dev/null)
   # after (single-slot back-compat path):
   extra=$(printf '%s' "$input" | CLAUDE_STATUSLINE_WIDTH="$COSTBAR_HEADER_BUDGET" bash -c "$COSTBAR_HEADER_CMD" 2>/dev/null)
   ```
   …and a new loop over `statusline.d/*` for the general case.
3. **Write the host marker** `# claude-statusline-host:costbar` into the `statusLine.command`
   costbar installs (in its README snippet today; in its plugin installer later), so
   task-station and others see costbar owns the bar and register as providers instead of
   clobbering it.

## When costbar becomes a plugin

- Ship costbar as a **host plugin**. Its installer follows the **non-destructive install
  rule** above: install itself as host (with marker) when it should own the bar; if a
  marked host is already present, don't take over; if an unknown command owns
  `statusLine.command`, don't clobber — advise the user.
- Mirror task-station's reversible, backup-first settings.json installer
  (`lib/setup.py` `install_statusline()` / `remove_statusline()` in the task-station repo)
  rather than the manual README merge it uses now.
- costbar's cost block is multi-row, so costbar stays a **host** (it renders the bar);
  it does not need to also be a one-line provider.

## Coexistence with task-station (already shipped)

task-station 1.13.0 ships `config --statusline on` (opt-in, default off): it registers a
segment provider in `statusline.d/` and installs its own self-sufficient host **only when
nothing else owns the bar** — and it **never clobbers a foreign `statusLine`** (verified
against a costbar-style command). So once costbar writes its host marker and composes
`statusline.d/`, the two pair automatically: costbar owns the bar, task-station's task
segment shows up inside it — with zero coupling in either direction.

## Pointers

- Spec + reference host: task-station `docs/STATUSLINE.md`, `lib/statusline-host.sh`.
- Reference non-destructive installer: task-station `lib/setup.py`
  (`install_statusline` / `remove_statusline` / `register_provider`).
- costbar slot to generalize: `costbar.sh` ~line 497-512 (`COSTBAR_HEADER_CMD`).
- Eventual upstream ask: propose native plugin segment composition to Claude Code (plugins
  declare a segment provider in `plugin.json`); until then this `statusline.d/` convention
  is the de-facto standard.
