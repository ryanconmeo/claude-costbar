#!/usr/bin/env bash

GREEN=$'\033[38;2;180;220;110m'
YELLOW=$'\033[38;2;240;190;80m'
RED=$'\033[38;2;230;120;80m'
GREEN_L=$'\033[38;2;130;160;80m'
YELLOW_L=$'\033[38;2;175;138;58m'
RED_L=$'\033[38;2;168;88;58m'
TOK=$'\033[38;2;90;135;175m'
DIM=$'\033[2m'
RESET=$'\033[0m'

input=$(cat)

session_id=$(echo "$input" | jq -r '.session_id // "unknown"')
current=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')

PREV_COST_FILE="/tmp/claude_prev_cost_${session_id}"
PREV_TOK_FILE="/tmp/claude_prev_tok_${session_id}"

# Update prev files (used by Stop hook and UserPromptSubmit hook)
prev=0; [ -f "$PREV_COST_FILE" ] && prev=$(cat "$PREV_COST_FILE")
echo "$current" > "$PREV_COST_FILE"

# Per-message delta
msg_start=0; [ -f "/tmp/claude_msg_start_cost_${session_id}" ] && msg_start=$(cat "/tmp/claude_msg_start_cost_${session_id}")
msg_delta=$(awk "BEGIN { printf \"%.10f\", $current - $msg_start }")

# Context window and rate limits
ctx_rem=$(echo "$input"   | jq -r '.context_window.remaining_percentage // empty')
week_used=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
hour_used=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
resets_at_raw=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
five_hour_resets_at_raw=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')

CACHE_DIR="$HOME/.claude/cache"
mkdir -p "$CACHE_DIR"

# Persist known-good values; fall back to cache when input is empty (e.g. on startup)
if [ -z "$ctx_rem" ]; then ctx_rem=100; fi
if [ -n "$week_used" ]; then echo "$week_used" > "$CACHE_DIR/week_used"; else week_used=$(cat "$CACHE_DIR/week_used" 2>/dev/null); fi
if [ -n "$hour_used" ]; then echo "$hour_used" > "$CACHE_DIR/hour_used"; else hour_used=$(cat "$CACHE_DIR/hour_used" 2>/dev/null); fi
if [ -n "$resets_at_raw" ]; then echo "$resets_at_raw" > "$CACHE_DIR/resets_at"; fi
if [ -n "$five_hour_resets_at_raw" ]; then echo "$five_hour_resets_at_raw" > "$CACHE_DIR/five_hour_resets_at"; fi

req_out_tok=$(echo "$input" | jq -r '(.context_window.current_usage.output_tokens // .context_window.total_output_tokens) // 0')

# Fix: accumulate session output tokens on every statusline call by detecting
# when req_out_tok changes — this captures every API call within a turn, not
# just the last one (the old approach missed intermediate tool-call responses).
last_out_tok=0
[ -f "/tmp/claude_last_out_tok_${session_id}" ] && last_out_tok=$(cat "/tmp/claude_last_out_tok_${session_id}")
ses_out_acc=0
[ -f "/tmp/claude_ses_out_acc_${session_id}" ] && ses_out_acc=$(cat "/tmp/claude_ses_out_acc_${session_id}")
if [ "$req_out_tok" -gt 0 ] && [ "$req_out_tok" != "$last_out_tok" ]; then
  ses_out_acc=$(( ses_out_acc + req_out_tok ))
  echo "$ses_out_acc" > "/tmp/claude_ses_out_acc_${session_id}"
  echo "$req_out_tok" > "/tmp/claude_last_out_tok_${session_id}"
fi
ses_out_tok=$ses_out_acc
echo "$ses_out_tok" > "$PREV_TOK_FILE"

# ── Date / week computations (used throughout) ───────────
today_dow=$(date +%w)                                # 0=Sun…6=Sat
cur_week_sunday=$(date -v-${today_dow}d +%Y-%m-%d)  # current week's Sunday
cur_sunday=$(date -j -f "%Y-%m-%d %H:%M:%S" "$cur_week_sunday 00:00:00" +%s 2>/dev/null)  # midnight epoch, for week counter

# Weekly cost boundary: Anthropic's actual 7-day reset time, not calendar Sunday.
# If the reset is not at local midnight, sessions on the reset date are ambiguous
# (could be pre- or post-reset). Advance by 1 day to exclude them entirely rather
# than pulling old-week sessions into the current week's total.
_resets_epoch="${resets_at_raw:-$(cat "$CACHE_DIR/resets_at" 2>/dev/null)}"
if [ -n "$_resets_epoch" ]; then
  _week_start=$(( _resets_epoch - 604800 ))
  _week_start_date=$(date -r "$_week_start" +%Y-%m-%d)
  if [ "$(date -r "$_week_start" +%H%M%S)" != "000000" ]; then
    week_start_date=$(date -j -v+1d -f "%Y-%m-%d" "$_week_start_date" +%Y-%m-%d)
  else
    week_start_date=$_week_start_date
  fi
else
  week_start_date=$cur_week_sunday
fi

# Publish this session's live state so parallel sessions can see it
LIVE_DIR="/tmp/claude_live"
mkdir -p "$LIVE_DIR"
echo "$current $ses_out_tok $(date +%Y-%m-%d)" > "$LIVE_DIR/${session_id}"

# ── Historical totals from JSONL-based cache ──────────────
CACHE_FILE="$CACHE_DIR/session_totals.json"

log_grand=0; log_grand_tok=0; log_weekly=0; log_weekly_tok=0; first_date=""
if [ -f "$CACHE_FILE" ]; then
  read -r log_grand log_grand_tok log_weekly log_weekly_tok first_date <<< $(jq -r \
    --arg sid "$session_id" --arg ws "$week_start_date" '
    [.sessions | to_entries[] | select(.key != $sid) | .value] as $s |
    [($s | map(.cost) | add // 0),
     ($s | map(.output_tok) | add // 0),
     ($s | map(select(.date >= $ws) | .cost) | add // 0),
     ($s | map(select(.date >= $ws) | .output_tok) | add // 0),
     (.first_date // "")] | join(" ")
  ' "$CACHE_FILE" 2>/dev/null)
fi

# Parallel live sessions (other Claude Code windows still running)
read -r live_grand live_grand_tok live_weekly live_weekly_tok <<< $(
  for f in "$LIVE_DIR"/*; do
    [ -f "$f" ] || continue
    fsid=$(basename "$f")
    [ "$fsid" = "$session_id" ] && continue
    # Remove stale live files for sessions now completed (present in cache)
    [ -f "$CACHE_FILE" ] && jq -e --arg s "$fsid" '.sessions | has($s)' "$CACHE_FILE" >/dev/null 2>&1 && { rm -f "$f"; continue; }
    read -r fcost ftok fdate < "$f" 2>/dev/null || continue
    echo "$fcost $ftok $fdate"
  done | awk -v ws="$week_start_date" '
  NF >= 3 {
    grand_cost += $1; grand_tok += $2
    if ($3 >= ws) { week_cost += $1; week_tok += $2 }
  }
  END { printf "%.10f %d %.10f %d", grand_cost+0, grand_tok+0, week_cost+0, week_tok+0 }')

# Include current session in weekly only if it started this week
session_start=""
[ -f "/tmp/claude_session_start_${session_id}" ] && session_start=$(cat "/tmp/claude_session_start_${session_id}")
if [ -z "$session_start" ] || ! [[ "$session_start" < "$week_start_date" ]]; then
  cur_weekly_cost=$current; cur_weekly_tok=$ses_out_tok
else
  cur_weekly_cost=0; cur_weekly_tok=0
fi

grand=$(awk "BEGIN { printf \"%.10f\", ${log_grand:-0} + ${live_grand:-0} + $current }")
grand_tok=$(awk "BEGIN { printf \"%d\", ${log_grand_tok:-0} + ${live_grand_tok:-0} + $ses_out_tok }")
weekly=$(awk "BEGIN { printf \"%.10f\", ${log_weekly:-0} + ${live_weekly:-0} + ${cur_weekly_cost:-0} }")
weekly_tok=$(awk "BEGIN { printf \"%d\", ${log_weekly_tok:-0} + ${live_weekly_tok:-0} + ${cur_weekly_tok:-0} }")

# Dynamic thresholds: μ and μ+σ of per-session costs from cache, fallback to fixed
thresh_lo="0.01"
thresh_hi="0.05"
if [ -f "$CACHE_FILE" ]; then
  stats=$(jq -r '
    [.sessions[].cost] |
    if length >= 3 then
      (add / length) as $mean |
      ((map(. * .) | add / length) - ($mean * $mean)) |
      if . < 0 then 0 else . end | sqrt as $sd |
      "\($mean) \($sd)"
    else empty end
  ' "$CACHE_FILE" 2>/dev/null)
  if [ -n "$stats" ]; then
    thresh_lo=$(echo "$stats" | awk '{print $1}')
    thresh_hi=$(awk "BEGIN { printf \"%.6f\", $(echo "$stats" | awk '{print $1}') + $(echo "$stats" | awk '{print $2}') }")
  fi
fi

# Weekly thresholds: μ and μ+σ of completed weekly costs, fallback to fixed
week_thresh_lo="50.00"
week_thresh_hi="150.00"
if [ -f "$CACHE_FILE" ] && [ -n "$_resets_epoch" ]; then
  week_stats=$(python3 - "$CACHE_FILE" "$_resets_epoch" <<'PYEOF'
import json, sys, math
from datetime import datetime, timedelta
data = json.load(open(sys.argv[1]))
resets_at = int(sys.argv[2])
sessions = data.get('sessions', {})
def ws(epoch):
    dt = datetime.fromtimestamp(epoch - 604800)
    d = dt.date() + timedelta(days=1) if dt.strftime('%H%M%S') != '000000' else dt.date()
    return d.strftime('%Y-%m-%d')
cur_ws = ws(resets_at)
all_dates = [s['date'] for s in sessions.values() if s.get('date')]
if not all_dates:
    print("0 0"); sys.exit()
min_date = min(all_dates)
costs = []
r = resets_at
while True:
    w_start = ws(r - 604800)
    w_end   = ws(r)
    if w_start != cur_ws:
        total = sum(s['cost'] for s in sessions.values()
                    if w_start <= s.get('date','') < w_end and s['cost'] > 0)
        if total > 0:
            costs.append(total)
    if w_start <= min_date:
        break
    r -= 604800
if len(costs) < 2:
    print("0 0")
else:
    mean = sum(costs) / len(costs)
    sd = math.sqrt(sum((c - mean)**2 for c in costs) / len(costs))
    print(f"{mean:.6f} {sd:.6f}")
PYEOF
  )
  if [ -n "$week_stats" ] && [ "$week_stats" != "0 0" ]; then
    week_thresh_lo=$(echo "$week_stats" | awk '{print $1}')
    week_thresh_hi=$(awk "BEGIN { printf \"%.6f\", $(echo "$week_stats" | awk '{print $1}') + $(echo "$week_stats" | awk '{print $2}') }")
  fi
fi

# Turn thresholds: μ and μ+σ of cost-per-turn from cache, fallback to fixed
turn_thresh_lo="0.04"
turn_thresh_hi="0.07"
if [ -f "$CACHE_FILE" ]; then
  turn_stats=$(jq -r '
    if (.turn_cost_mean // 0) > 0 then "\(.turn_cost_mean) \(.turn_cost_sd // 0)"
    else empty end
  ' "$CACHE_FILE" 2>/dev/null)
  if [ -n "$turn_stats" ]; then
    turn_thresh_lo=$(echo "$turn_stats" | awk '{print $1}')
    turn_thresh_hi=$(awk "BEGIN { printf \"%.8f\", $(echo "$turn_stats" | awk '{print $1}') + $(echo "$turn_stats" | awk '{print $2}') }")
  fi
fi

cost_color() {
  awk "BEGIN { exit !($1 >= $thresh_hi) }" && { printf '%s' "$RED";    return; }
  awk "BEGIN { exit !($1 >= $thresh_lo) }" && { printf '%s' "$YELLOW"; return; }
  printf '%s' "$GREEN"
}

cost_label_color() {
  awk "BEGIN { exit !($1 >= $thresh_hi) }" && { printf '%s' "$RED_L";    return; }
  awk "BEGIN { exit !($1 >= $thresh_lo) }" && { printf '%s' "$YELLOW_L"; return; }
  printf '%s' "$GREEN_L"
}

week_cost_color() {
  awk "BEGIN { exit !($1 >= $week_thresh_hi) }" && { printf '%s' "$RED";    return; }
  awk "BEGIN { exit !($1 >= $week_thresh_lo) }" && { printf '%s' "$YELLOW"; return; }
  printf '%s' "$GREEN"
}

turn_cost_color() {
  awk "BEGIN { exit !($1 >= $turn_thresh_hi) }" && { printf '%s' "$RED";    return; }
  awk "BEGIN { exit !($1 >= $turn_thresh_lo) }" && { printf '%s' "$YELLOW"; return; }
  printf '%s' "$GREEN"
}

rem_color() {
  awk "BEGIN { exit !($1 <= 20) }" && { printf '%s' "$RED";    return; }
  awk "BEGIN { exit !($1 <= 50) }" && { printf '%s' "$YELLOW"; return; }
  printf '%s' "$GREEN"
}

used_color() {
  awk "BEGIN { exit !($1 >= 80) }" && { printf '%s' "$RED";    return; }
  awk "BEGIN { exit !($1 >= 50) }" && { printf '%s' "$YELLOW"; return; }
  printf '%s' "$GREEN"
}

fmt_cost() {
  awk "BEGIN { v=$1; if (v > 0 && v < 0.01) printf \"%.4f\", v; else printf \"%.2f\", v }"
}

fmt_tok() {
  awk "BEGIN { v=$1; if (v >= 1000000) printf \"%.4gm\", v/1000000; else if (v >= 1000) printf \"%.0fk\", v/1000; else printf \"%d\", v }"
}

# Outputs " · ≈ <comparison>" for a given token count; uses global $env_idx.
# Basis: ~0.002 kWh/1k output tokens, US grid ~0.386 kg CO2/kWh, ~1.8 L water/kWh (data center WUE)
eco_suffix() {
  local tok=$1 co2_g kwh water_ml val cmp
  [ "$tok" -le 0 ] && return
  co2_g=$(awk "BEGIN { printf \"%.4f\", $tok * 0.000772 }")
  kwh=$(awk "BEGIN { printf \"%.6f\", $tok * 0.000002 }")
  water_ml=$(awk "BEGIN { printf \"%.4f\", $tok * 0.0036 }")
  cmp=""
  case $env_idx in
    0)  val=$(awk "BEGIN { v=$co2_g/404; if(v>=1000)printf \"%.0fk mi\",v/1000; else if(v>=1)printf \"%.1f mi\",v; else printf \"%.0f ft\",v*5280 }")
        cmp="driving $val (gas car)" ;;
    1)  val=$(awk "BEGIN { v=$co2_g/255; if(v>=1000)printf \"%.0fk mi\",v/1000; else if(v>=1)printf \"%.1f mi\",v; else printf \"%.0f ft\",v*5280 }")
        cmp="flying $val (economy)" ;;
    2)  val=$(awk "BEGIN { v=$co2_g/27; if(v>=1000)printf \"%.1f kg\",v/1000; else if(v>=1)printf \"%.0f g\",v; else printf \"%.1f g\",v }")
        cmp="$val of beef produced" ;;
    3)  val=$(awk "BEGIN { v=$co2_g/280; if(v>=1000)printf \"%.0fk\",v/1000; else if(v>=1)printf \"%.1f\",v; else printf \"%.2f\",v }")
        cmp="$val cups of coffee" ;;
    4)  val=$(awk "BEGIN { v=$co2_g/80; if(v>=1000)printf \"%.0fk\",v/1000; else if(v>=1)printf \"%.1f\",v; else printf \"%.2f\",v }")
        cmp="$val bananas" ;;
    5)  val=$(awk "BEGIN { v=$co2_g/846; if(v>=1000)printf \"%.0fk\",v/1000; else if(v>=1)printf \"%.1f\",v; else printf \"%.2f\",v }")
        cmp="$val avocados" ;;
    6)  val=$(awk "BEGIN { v=$co2_g/2500; if(v>=1000)printf \"%.0fk\",v/1000; else if(v>=1)printf \"%.1f\",v; else printf \"%.2f\",v }")
        cmp="$val cheeseburgers" ;;
    7)  val=$(awk "BEGIN { v=$co2_g/1200; if(v>=1000)printf \"%.0fk\",v/1000; else if(v>=1)printf \"%.1f\",v; else printf \"%.2f\",v }")
        cmp="$val bottles of wine" ;;
    8)  val=$(awk "BEGIN { v=$co2_g/33; if(v>=1000)printf \"%.0fk\",v/1000; else printf \"%.0f\",v }")
        cmp="$val plastic bags produced" ;;
    9)  val=$(awk "BEGIN { v=$co2_g/2.4; if(v>=8760)printf \"%.1f yrs\",v/8760; else if(v>=24)printf \"%.0f days\",v/24; else printf \"%.0f hrs\",v }")
        cmp="1 tree offsetting CO2 for $val" ;;
    10) val=$(awk "BEGIN { v=$co2_g/13; if(v>=1)printf \"%.1f hrs\",v; else printf \"%.0f min\",v*60 }")
        cmp="$val candle burning" ;;
    11) val=$(awk "BEGIN { v=$kwh/0.06; if(v>=1000)printf \"%.0fk hrs\",v/1000; else if(v>=1)printf \"%.1f hrs\",v; else printf \"%.0f min\",v*60 }")
        cmp="$val incandescent bulb" ;;
    12) val=$(awk "BEGIN { v=$kwh/0.01; if(v>=1000)printf \"%.0fk hrs\",v/1000; else if(v>=1)printf \"%.1f hrs\",v; else printf \"%.0f min\",v*60 }")
        cmp="$val LED bulb" ;;
    13) val=$(awk "BEGIN { v=$kwh/0.007; if(v>=1000)printf \"%.0fk\",v/1000; else printf \"%.0f\",v }")
        cmp="$val phone charges" ;;
    14) val=$(awk "BEGIN { v=$kwh/0.0003; if(v>=1000000)printf \"%.1fM\",v/1000000; else if(v>=1000)printf \"%.0fk\",v/1000; else printf \"%.0f\",v }")
        cmp="$val Google searches" ;;
    15) val=$(awk "BEGIN { v=$kwh/0.036*60; if(v>=1440)printf \"%.0f days\",v/1440; else if(v>=60)printf \"%.0f hrs\",v/60; else printf \"%.0f min\",v }")
        cmp="$val of Netflix streaming" ;;
    16) val=$(awk "BEGIN { v=$kwh/0.05*60; if(v>=1440)printf \"%.0f days\",v/1440; else if(v>=60)printf \"%.0f hrs\",v/60; else printf \"%.0f min\",v }")
        cmp="$val laptop running" ;;
    17) val=$(awk "BEGIN { v=$kwh/0.2*60; if(v>=1440)printf \"%.0f days\",v/1440; else if(v>=60)printf \"%.0f hrs\",v/60; else printf \"%.0f min\",v }")
        cmp="$val of PS5 gaming" ;;
    18) val=$(awk "BEGIN { v=$kwh/1.2*3600; if(v>=60)printf \"%.0f min\",v/60; else printf \"%.0f sec\",v }")
        cmp="$val of microwave" ;;
    19) val=$(awk "BEGIN { v=$kwh/0.1; if(v>=1000)printf \"%.0fk\",v/1000; else if(v>=1)printf \"%.1f\",v; else printf \"%.2f\",v }")
        cmp="$val kettle boils" ;;
    20) val=$(awk "BEGIN { v=$kwh/0.5; if(v>=1)printf \"%.1f\",v; else printf \"%.2f\",v }")
        cmp="$val washing machine cycles" ;;
    21) val=$(awk "BEGIN { v=$kwh/1.5; if(v>=1)printf \"%.1f\",v; else printf \"%.2f\",v }")
        cmp="$val dishwasher cycles" ;;
    22) val=$(awk "BEGIN { v=$kwh/1.0*60; if(v>=60)printf \"%.0f hrs\",v/60; else printf \"%.0f min\",v }")
        cmp="$val window AC" ;;
    23) val=$(awk "BEGIN { v=$kwh/0.3; if(v>=1000)printf \"%.0fk mi\",v/1000; else if(v>=1)printf \"%.1f mi\",v; else printf \"%.0f ft\",v*5280 }")
        cmp="$val EV driving" ;;
    24) val=$(awk "BEGIN { v=$kwh/1.25*60; if(v>=1440)printf \"%.0f days\",v/1440; else if(v>=60)printf \"%.0f hrs\",v/60; else printf \"%.0f min\",v }")
        cmp="powering a home for $val" ;;
    25) val=$(awk "BEGIN { v=$water_ml; if(v>=1000000)printf \"%.1f kL\",v/1000000; else if(v>=1000)printf \"%.2f L\",v/1000; else printf \"%.1f mL\",v }")
        cmp="$val water (datacenter cooling)" ;;
    26) val=$(awk "BEGIN { v=$water_ml/250; if(v>=1000)printf \"%.0fk\",v/1000; else if(v>=1)printf \"%.1f\",v; else printf \"%.2f\",v }")
        cmp="$val glasses of drinking water" ;;
    27) val=$(awk "BEGIN { v=$water_ml/8000*60; if(v>=60)printf \"%.0f min\",v/60; else printf \"%.0f sec\",v }")
        cmp="$val of showering" ;;
    28) val=$(awk "BEGIN { v=$water_ml/6000; if(v>=1)printf \"%.1f\",v; else printf \"%.2f\",v }")
        cmp="$val toilet flushes" ;;
    29) val=$(awk "BEGIN { v=$water_ml/5; if(v>=1000)printf \"%.0fk\",v/1000; else if(v>=1)printf \"%.1f\",v; else printf \"%.2f\",v }")
        cmp="$val teaspoons of water" ;;
  esac
  [ -n "$cmp" ] && printf '  \033[2m·\033[0m  \033[38;2;100;170;90m≈ %s\033[0m' "$cmp"
}

label_sep1="  │  "
label_sep2="  ╎  "
sep=" · "
LABEL=$'\033[1m'
LW=7  # fixed label column width — matches longest label "Session"

strip_ansi() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*[mK]//g'; }
term_width=$(tput cols </dev/tty 2>/dev/null); [ -z "$term_width" ] && term_width=$(stty size </dev/tty 2>/dev/null | awk '{print $2}'); : "${term_width:=80}"

right_align() {
  local line="$1"
  local vlen
  vlen=$(strip_ansi "$line" | awk '{print length}')
  local pad=$(( term_width - vlen ))
  [ $pad -gt 0 ] && printf "%${pad}s" ""
  printf '%s' "$line"
}

# Appends eco right-aligned; falls back to inline if terminal is too narrow.
append_eco_right() {
  local base="$1" eco="$2"
  [ -z "$eco" ] && { printf '%s' "$base"; return; }
  local blen elen pad
  blen=$(strip_ansi "$base" | tr -d '\n' | wc -m | tr -d ' ')
  elen=$(strip_ansi "$eco"  | tr -d '\n' | wc -m | tr -d ' ')
  pad=$(( term_width - blen - elen ))
  if [ "$pad" -gt 1 ]; then
    printf '%s%*s%s' "$base" "$pad" "" "$eco"
  else
    printf '%s' "$base"
  fi
}

# ── Week dots — fixed SMTWTFS; gray = active since last reset, white = inactive ─
DOT_WHITE=$'\033[38;2;240;240;240m'
DOT_GRAY=$'\033[38;2;90;90;90m'
DOT_GREEN=$'\033[38;2;100;200;100m'
LABEL_GRAY=$'\033[38;2;170;170;170m'
ENV=$'\033[38;2;100;170;90m'

week_dots=""
resets_at=$(cat "$CACHE_DIR/resets_at" 2>/dev/null)

reset_dow=2  # fallback: Tuesday
[ -n "$resets_at" ] && reset_dow=$(date -r "$resets_at" +%w 2>/dev/null)
# today_dow already computed above

for ((i=0; i<7; i++)); do
  if [ "$today_dow" -ge "$reset_dow" ]; then
    [ "$i" -ge "$reset_dow" ] && [ "$i" -le "$today_dow" ] && active=1 || active=0
  else
    [ "$i" -ge "$reset_dow" ] || [ "$i" -le "$today_dow" ] && active=1 || active=0
  fi
  if [ "$i" -eq "$reset_dow" ]; then
    week_dots+="${DOT_GREEN}●${RESET}"
  elif [ "$active" -eq 1 ]; then
    week_dots+="${DOT_GRAY}●${RESET}"
  else
    week_dots+="${DOT_WHITE}●${RESET}"
  fi
done

# ── Reset time labels ────────────────────────────────────
fmt_reset_time() {
  local ts=$1
  [ -z "$ts" ] && return
  date -r "$ts" +"%I:%M %p" 2>/dev/null | sed 's/^0//'
}
five_hour_resets_at=$(cat "$CACHE_DIR/five_hour_resets_at" 2>/dev/null)
hour_reset=$(fmt_reset_time "$five_hour_resets_at")
week_reset=$([ -n "$resets_at" ] && date -r "$resets_at" +"%a %-I:%M %p" 2>/dev/null)
[ -n "$hour_reset" ] && hour_reset_suffix=" (↺$hour_reset)" || hour_reset_suffix=""
[ -n "$week_reset" ] && week_reset_suffix=" (↺$week_reset)" || week_reset_suffix=""

# ── Build base lines (no eco yet) ────────────────────────
env_idx=$(( $(date +%s) % 30 ))

# Row 1: Turn
if [ -f "/tmp/claude_running_${session_id}" ]; then
  turn_delta=$msg_delta
  turn_start_out=0
  [ -f "/tmp/claude_msg_start_out_tok_${session_id}" ] && turn_start_out=$(cat "/tmp/claude_msg_start_out_tok_${session_id}")
  turn_max_out=$(( ses_out_tok - turn_start_out ))
else
  # Use snapshot written by on_stop.sh — stable, won't drift from post-turn internal calls
  turn_delta=0
  [ -f "/tmp/claude_last_turn_delta_${session_id}" ] && turn_delta=$(cat "/tmp/claude_last_turn_delta_${session_id}")
  turn_max_out=0
  [ -f "/tmp/claude_last_turn_max_out_${session_id}" ] && turn_max_out=$(cat "/tmp/claude_last_turn_max_out_${session_id}")
fi
[ "$turn_max_out" -gt 0 ] && turn_tok_str=" ${TOK}out $(fmt_tok "$turn_max_out")${RESET}" || turn_tok_str=""
c=$(turn_cost_color "$turn_delta")
turn_base="${LABEL}$(printf "%-${LW}s" "Turn")${RESET}${label_sep1}${c}${LABEL}\$$(fmt_cost "$turn_delta")${RESET}${turn_tok_str}"
turn_eco=$(eco_suffix "$turn_max_out")

# Row 2: Session
c=$(cost_color "$current")
ses_base="${LABEL}$(printf "%-${LW}s" "Session")${RESET}${label_sep1}${c}${LABEL}\$$(fmt_cost "$current")${RESET} ${TOK}out $(fmt_tok "$ses_out_tok")${RESET}"
if [ -n "$ctx_rem" ]; then
  c=$(rem_color "$ctx_rem")
  ses_base+="${sep}${c}${LABEL}$(printf '%.0f' "$ctx_rem")% left${RESET}"
fi
ses_eco=$(eco_suffix "$ses_out_tok")

# Row 3: 5-hour (no eco)
five_base="${LABEL}$(printf "%-${LW}s" "5-hour")${RESET}${label_sep1}"
if [ -n "$hour_used" ]; then
  left=$(awk "BEGIN { printf \"%.0f\", 100 - $hour_used }")
  c=$(used_color "$hour_used")
  five_base+="${c}${LABEL}${left}% left${RESET}"
  [ -n "$hour_reset" ] && five_base+=" ${LABEL_GRAY}(↺${hour_reset})${RESET}"
else
  five_base+="${DIM}—${RESET}"
fi

# Row 4: Week
cal_week=1
if [ -n "$first_date" ]; then
  first_dow=$(date -j -f "%Y-%m-%d" "$first_date" +%w 2>/dev/null)
  _first_sun_date=$(date -j -v-${first_dow}d -f "%Y-%m-%d" "$first_date" +%Y-%m-%d 2>/dev/null)
  first_sunday=$(date -j -f "%Y-%m-%d %H:%M:%S" "$_first_sun_date 00:00:00" +%s 2>/dev/null)
  cal_week=$(awk "BEGIN { printf \"%d\", int(($cur_sunday - ${first_sunday:-0}) / 604800) + 1 }")
fi
c=$(week_cost_color "$weekly")
week_base="${LABEL}$(printf "%-${LW}s" "Week ${cal_week}")${RESET}${label_sep1}${c}${LABEL}\$$(fmt_cost "$weekly")${RESET} ${TOK}out $(fmt_tok "$weekly_tok")${RESET}"
if [ -n "$week_used" ]; then
  left=$(awk "BEGIN { printf \"%.0f\", 100 - $week_used }")
  c=$(used_color "$week_used")
  week_base+="${sep}${c}${LABEL}${left}% left${RESET}"
  [ -n "$week_reset" ] && week_base+=" ${LABEL_GRAY}(↺${week_reset})${RESET}"
fi
[ -n "$week_dots" ] && week_base+=" $week_dots"
week_eco=$(eco_suffix "$weekly_tok")

# Row 5: Total
since_label=""
[ -n "$first_date" ] && since_label=" since $(date -j -f "%Y-%m-%d" "$first_date" +"%-b %-d, %Y" 2>/dev/null)"
total_base="${LABEL}$(printf "%-${LW}s" "Total")${RESET}${label_sep1}\$$(fmt_cost "$grand")  ${TOK}out $(fmt_tok "$grand_tok") tokens${RESET}${since_label}"
total_eco=$(eco_suffix "$grand_tok")

# ── Fixed eco column: widest base + 2 ────────────────────
max_blen=0
for _b in "$turn_base" "$ses_base" "$five_base" "$week_base" "$total_base"; do
  _l=$(strip_ansi "$_b" | tr -d '\n' | wc -m | tr -d ' ')
  [ "$_l" -gt "$max_blen" ] && max_blen=$_l
done
eco_col=$(( max_blen + 2 ))

eco_at_col() {
  local base="$1" eco="$2"
  [ -z "$eco" ] && { printf '%s' "$base"; return; }
  local blen pad
  blen=$(strip_ansi "$base" | tr -d '\n' | wc -m | tr -d ' ')
  pad=$(( eco_col - blen ))
  [ "$pad" -lt 1 ] && pad=1
  printf '%s%*s%s' "$base" "$pad" "" "$eco"
}

# ── Assemble output ───────────────────────────────────────
out=$(eco_at_col "$turn_base" "$turn_eco")
out+=$'\n'"$(eco_at_col "$ses_base" "$ses_eco")"
out+=$'\n'"$five_base"
out+=$'\n'"$(eco_at_col "$week_base" "$week_eco")"
out+=$'\n'"$(eco_at_col "$total_base" "$total_eco")"

printf '%s' "$out"
