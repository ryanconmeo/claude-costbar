#!/usr/bin/env bash
input=$(cat)
echo "$input" | jq '.' > "/tmp/claude_stop_hook_debug.json" 2>/dev/null
session_id=$(echo "$input" | jq -r '.session_id // "unknown"')
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')

# Compute JSONL-based session total for the historical cache only.
# Turn delta and output tokens are now computed in on_user_prompt.sh using
# hook payload cost, ensuring they stay consistent with the Session display.
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  cost=$(python3 - "$transcript_path" <<'PYEOF'
import json, sys
RATES = {
    'claude-opus-4-7':           dict(input_tokens=15.00/1e6, output_tokens=75.00/1e6,  cache_read_input_tokens=1.50/1e6,  cache_creation_input_tokens=18.75/1e6),
    'claude-sonnet-4-6':         dict(input_tokens= 3.00/1e6, output_tokens=15.00/1e6,  cache_read_input_tokens=0.30/1e6,  cache_creation_input_tokens= 3.75/1e6),
    'claude-haiku-4-5-20251001': dict(input_tokens= 0.80/1e6, output_tokens= 4.00/1e6,  cache_read_input_tokens=0.08/1e6,  cache_creation_input_tokens= 1.00/1e6),
}
RATE_PREFIXES = [('claude-opus', RATES['claude-opus-4-7']), ('claude-sonnet', RATES['claude-sonnet-4-6']), ('claude-haiku', RATES['claude-haiku-4-5-20251001'])]
def get_rates(model):
    if model in RATES: return RATES[model]
    for p, r in RATE_PREFIXES:
        if model.startswith(p): return r
    return RATES['claude-sonnet-4-6']
total = 0.0
with open(sys.argv[1], 'rb') as f:
    for raw in f:
        raw = raw.strip()
        if not raw: continue
        try: msg = json.loads(raw)
        except: continue
        if msg.get('type') != 'assistant': continue
        usage = msg.get('message', {}).get('usage')
        if not usage: continue
        rates = get_rates(msg.get('message', {}).get('model', ''))
        for k, rate in rates.items():
            total += usage.get(k, 0) * rate
print(f'{total:.10f}')
PYEOF
  )
else
  cost=$(cat "/tmp/claude_prev_cost_${session_id}" 2>/dev/null || echo 0)
fi

python3 "$HOME/.claude/costbar/compute_jsonl_totals.py" "$session_id" --actual-cost "$cost"

# Snapshot turn delta so the statusline can show the correct value immediately
# after the turn ends (before the next on_user_prompt.sh runs).
prev_cost=0
[ -f "/tmp/claude_prev_cost_${session_id}" ] && prev_cost=$(cat "/tmp/claude_prev_cost_${session_id}")
msg_start=0
[ -f "/tmp/claude_msg_start_cost_${session_id}" ] && msg_start=$(cat "/tmp/claude_msg_start_cost_${session_id}")
final_delta=$(awk "BEGIN { printf \"%.10f\", $prev_cost - $msg_start }")
echo "$final_delta" > "/tmp/claude_last_turn_delta_${session_id}"

ses_out_acc=0
[ -f "/tmp/claude_ses_out_acc_${session_id}" ] && ses_out_acc=$(cat "/tmp/claude_ses_out_acc_${session_id}")
turn_start_out=0
[ -f "/tmp/claude_msg_start_out_tok_${session_id}" ] && turn_start_out=$(cat "/tmp/claude_msg_start_out_tok_${session_id}")
turn_out=$(( ses_out_acc - turn_start_out ))
[ "$turn_out" -lt 0 ] && turn_out=0
echo "$turn_out" > "/tmp/claude_last_turn_max_out_${session_id}"

rm -f "/tmp/claude_live/${session_id}"
rm -f "/tmp/claude_running_${session_id}"
rm -f "/tmp/claude_prev_out_tok_${session_id}"
rm -f "/tmp/claude_max_out_tok_${session_id}"
rm -f "/tmp/claude_session_start_${session_id}"
rm -f "/tmp/claude_turn_start_ts_${session_id}"
