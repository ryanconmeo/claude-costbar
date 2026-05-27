#!/usr/bin/env bash
input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id // "unknown"')

# UserPromptSubmit payload does not include cost; read the last cost the statusline
# observed (written to PREV_COST_FILE on every statusline call).  This is the
# session total at the end of the previous turn — the correct baseline for both
# the turn-delta display and the post-turn snapshot.
current_cost=0
[ -f "/tmp/claude_prev_cost_${session_id}" ] && current_cost=$(cat "/tmp/claude_prev_cost_${session_id}")

# Compute last-turn cost delta (hook payload end - hook payload start)
prev_msg_start=0
[ -f "/tmp/claude_msg_start_cost_${session_id}" ] && prev_msg_start=$(cat "/tmp/claude_msg_start_cost_${session_id}")
final_delta=$(awk "BEGIN { printf \"%.10f\", $current_cost - $prev_msg_start }")
echo "$final_delta" > "/tmp/claude_last_turn_delta_${session_id}"

# Compute last-turn output token delta from session accumulator
ses_out_acc=0
[ -f "/tmp/claude_ses_out_acc_${session_id}" ] && ses_out_acc=$(cat "/tmp/claude_ses_out_acc_${session_id}")
prev_out_start=0
[ -f "/tmp/claude_msg_start_out_tok_${session_id}" ] && prev_out_start=$(cat "/tmp/claude_msg_start_out_tok_${session_id}")
turn_out=$(( ses_out_acc - prev_out_start ))
[ "$turn_out" -lt 0 ] && turn_out=0
echo "$turn_out" > "/tmp/claude_last_turn_max_out_${session_id}"

# Snapshot baselines for the current turn
echo "$current_cost" > "/tmp/claude_msg_start_cost_${session_id}"
echo "$ses_out_acc" > "/tmp/claude_msg_start_out_tok_${session_id}"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "/tmp/claude_turn_start_ts_${session_id}"

touch "/tmp/claude_running_${session_id}"

start_file="/tmp/claude_session_start_${session_id}"
[ ! -f "$start_file" ] && date +%Y-%m-%d > "$start_file"
