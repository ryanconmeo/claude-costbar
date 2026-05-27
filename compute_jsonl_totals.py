#!/usr/bin/env python3
"""
Update ~/.claude/cache/session_totals.json from Claude Code JSONL transcripts.

Usage:
  compute_jsonl_totals.py                                   # backfill all uncached sessions
  compute_jsonl_totals.py SESSION_ID --actual-cost COST     # add/update one session
  compute_jsonl_totals.py SESSION_ID --actual-cost COST --backfill  # both
"""
import json, math, sys
from pathlib import Path

CLAUDE_DIR = Path.home() / '.claude'
CACHE_FILE = CLAUDE_DIR / 'cache' / 'session_totals.json'
PROJECTS_DIR = CLAUDE_DIR / 'projects'

# USD per token, by model
RATES = {
    'claude-opus-4-7':           dict(input_tokens=15.00/1e6, output_tokens=75.00/1e6,  cache_read_input_tokens=1.50/1e6,  cache_creation_input_tokens=18.75/1e6),
    'claude-sonnet-4-6':         dict(input_tokens= 3.00/1e6, output_tokens=15.00/1e6,  cache_read_input_tokens=0.30/1e6,  cache_creation_input_tokens= 3.75/1e6),
    'claude-haiku-4-5-20251001': dict(input_tokens= 0.80/1e6, output_tokens= 4.00/1e6,  cache_read_input_tokens=0.08/1e6,  cache_creation_input_tokens= 1.00/1e6),
}
RATE_PREFIXES = [
    ('claude-opus',   RATES['claude-opus-4-7']),
    ('claude-sonnet', RATES['claude-sonnet-4-6']),
    ('claude-haiku',  RATES['claude-haiku-4-5-20251001']),
]

def get_rates(model):
    r = RATES.get(model)
    if r:
        return r
    for prefix, rates in RATE_PREFIXES:
        if model.startswith(prefix):
            return rates
    return RATES['claude-sonnet-4-6']

def load_cache():
    if CACHE_FILE.exists():
        try:
            return json.loads(CACHE_FILE.read_text())
        except Exception:
            pass
    return {'sessions': {}}

def save_cache(cache):
    CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
    sessions = cache.get('sessions', {})
    dates = [s['date'] for s in sessions.values() if s.get('date')]
    cache['first_date'] = min(dates) if dates else None
    ratios = [s['cost'] / s['turns'] for s in sessions.values()
              if s.get('cost', 0) > 0 and s.get('turns', 0) > 0]
    if len(ratios) >= 2:
        mean = sum(ratios) / len(ratios)
        sd = math.sqrt(sum((r - mean) ** 2 for r in ratios) / len(ratios))
        cache['turn_cost_mean'] = round(mean, 8)
        cache['turn_cost_sd']   = round(sd, 8)
    tmp = CACHE_FILE.with_suffix('.tmp')
    tmp.write_text(json.dumps(cache, separators=(',', ':')))
    tmp.rename(CACHE_FILE)

def process_jsonl(path):
    """Compute {cost, output_tok, turns, date} from a session JSONL file."""
    cost = 0.0
    output_tok = 0
    turns = 0
    date_str = None
    try:
        with open(path, 'rb') as f:
            for raw in f:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    msg = json.loads(raw)
                except Exception:
                    continue
                if date_str is None:
                    ts = msg.get('timestamp', '')
                    if ts:
                        date_str = ts[:10]
                msg_type = msg.get('type')
                if msg_type == 'user' and not msg.get('isSidechain') and not msg.get('isMeta'):
                    turns += 1
                if msg_type != 'assistant':
                    continue
                message = msg.get('message', {})
                usage = message.get('usage')
                if not usage:
                    continue
                rates = get_rates(message.get('model', ''))
                for k, rate in rates.items():
                    cost += usage.get(k, 0) * rate
                output_tok += usage.get('output_tokens', 0)
    except Exception:
        pass
    return {'cost': round(cost, 8), 'output_tok': output_tok, 'turns': turns, 'date': date_str}

def is_session_uuid(s):
    return len(s) == 36 and s.count('-') == 4

def main():
    args = sys.argv[1:]
    backfill = '--backfill' in args
    args = [a for a in args if a != '--backfill']

    target = None
    actual_cost = None
    if args and not args[0].startswith('--'):
        target = args[0]
        args = args[1:]
    if '--actual-cost' in args:
        idx = args.index('--actual-cost')
        if idx + 1 < len(args):
            try:
                actual_cost = float(args[idx + 1])
            except ValueError:
                pass

    cache = load_cache()
    sessions = cache.setdefault('sessions', {})
    updated = False

    # Process JSONL files not yet in cache
    if target or backfill or not sessions:
        for jsonl in PROJECTS_DIR.rglob('*.jsonl'):
            sid = jsonl.stem
            if not is_session_uuid(sid) or sid in sessions:
                continue
            if target and not backfill and sid != target:
                continue
            result = process_jsonl(jsonl)
            if result['date']:
                sessions[sid] = result
                updated = True

    # Backfill turns for cached sessions that predate turn tracking
    for jsonl in PROJECTS_DIR.rglob('*.jsonl'):
        sid = jsonl.stem
        if not is_session_uuid(sid):
            continue
        if sid not in sessions or 'turns' in sessions[sid]:
            continue
        result = process_jsonl(jsonl)
        sessions[sid]['turns'] = result['turns']
        updated = True

    # Stamp actual cost from Claude Code (more accurate than token-based estimate)
    if actual_cost is not None and target and target in sessions:
        sessions[target]['cost'] = round(actual_cost, 8)
        updated = True

    if updated:
        save_cache(cache)

if __name__ == '__main__':
    main()
