"""inbox — every Claude Code session that is waiting on the owner, as one list.

  inbox.py [--days N] [--root DIR] [--json]

Scans <root>/*/*.jsonl (root default ~/.claude/projects; top-level session files only, never
subagents/) modified in the last N days (default 3). Each session is read from the end and
classified by the FIRST rule that matches:
  question    the last assistant entry has an AskUserQuestion tool_use with no later tool_result
  waiting / blocked / failed
              the last assistant text has a `RELATÓRIO: ` line (relatorio.py) with that estado
  error       the last entry is an assistant entry with isApiErrorMessage, or text `API Error…`
  keep-open   the last assistant text ends with a `NEXT: keep-open …` line
Anything else (ready/progress/dropped, NEXT: clear, a user message after the last assistant
text) is not listed. One row per session, oldest first:
  <age> <state> <project> <session id[:8]> <#issue or -> — <pergunta or motivo, ≤160 chars>
then `inbox: <n> waiting (<k> <state>, …)`. --json prints the rows as a JSON list instead.
Only user/assistant entries count as "entries"; unparseable lines are skipped. Exit 0 (2 on bad args).

Stdlib only, Python 3.9-compatible. Run as `python3 -I`.
"""
import argparse
import datetime
import glob
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import relatorio  # noqa: E402

STATES = ('question', 'waiting', 'blocked', 'failed', 'error', 'keep-open')
MAX_TEXT = 160


def one_line(s, limit=MAX_TEXT):
    s = ' '.join(str(s).split())
    return s if len(s) <= limit else s[:limit - 1] + '…'


def parse_ts(s):
    """ISO 8601 -> aware datetime (UTC when no offset); None when unparseable."""
    if not isinstance(s, str):
        return None
    s = s.strip()
    if s.endswith(('Z', 'z')):
        s = s[:-1] + '+00:00'
    m = re.match(r'^(.*?T\d\d:\d\d:\d\d)(\.\d+)?(.*)$', s)
    if m:  # 3.9's fromisoformat only takes 3 or 6 fractional digits
        frac = (m.group(2) or '')[1:7].ljust(6, '0')
        s = m.group(1) + ('.' + frac if m.group(2) else '') + m.group(3)
    try:
        d = datetime.datetime.fromisoformat(s)
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=datetime.timezone.utc)


def fmt_age(seconds):
    m = max(int(seconds // 60), 0)
    h, m = divmod(m, 60)
    d, h = divmod(h, 24)
    if d:
        return '%dd%02dh' % (d, h)
    if h:
        return '%dh%02dm' % (h, m)
    return '%dm' % m


def load(path):
    out = []
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            for raw in f:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    e = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(e, dict) and e.get('type') in ('user', 'assistant') \
                        and isinstance(e.get('message'), dict):
                    out.append(e)
    except OSError:
        pass
    return out


def blocks(e):
    c = e['message'].get('content')
    if isinstance(c, str):
        return [{'type': 'text', 'text': c}]
    return [b for b in c if isinstance(b, dict)] if isinstance(c, list) else []


def texts(e):
    return [b.get('text') for b in blocks(e) if b.get('type') == 'text' and isinstance(b.get('text'), str)]


def relatorio_of(text):
    last = None
    for ln in text.splitlines():
        if ln.startswith(relatorio.PREFIX):
            last = ln[len(relatorio.PREFIX):]
    if last is None:
        return None
    try:
        d = json.loads(last)
    except ValueError:
        return None
    return None if relatorio.validate(d) else d


def classify(entries):
    """Return (state, issue, text) or None."""
    last = entries[-1]
    last_asst = next((i for i in range(len(entries) - 1, -1, -1) if entries[i]['type'] == 'assistant'), None)
    if last_asst is None:
        return None
    # 1 question: an AskUserQuestion in the last assistant entry nobody answered.
    for b in blocks(entries[last_asst]):
        if b.get('type') == 'tool_use' and b.get('name') == 'AskUserQuestion':
            answered = any(x.get('type') == 'tool_result' and x.get('tool_use_id') == b.get('id')
                           for e in entries[last_asst + 1:] for x in blocks(e))
            if not answered:
                qs = (b.get('input') or {}).get('questions')
                q = qs[0].get('question') if isinstance(qs, list) and qs and isinstance(qs[0], dict) else None
                return 'question', None, one_line(q or 'AskUserQuestion')
    # The last assistant entry that carries text; a user entry after it means answered/working.
    ti = next((i for i in range(len(entries) - 1, -1, -1) if entries[i]['type'] == 'assistant' and texts(entries[i])), None)
    text = texts(entries[ti])[-1] if ti is not None else ''
    answered_after = ti is not None and any(e['type'] == 'user' for e in entries[ti + 1:])
    # 2 Relatório (report)
    if ti is not None and not answered_after:
        r = relatorio_of(text)
        if r and r['estado'] in ('waiting', 'blocked', 'failed'):
            parts = [r['motivo'], r['pergunta']] if r['estado'] != 'waiting' else [r['pergunta']]
            return r['estado'], r['issue'], one_line(': '.join(p for p in parts if p) or r['estado'])
    # 3 error: the very last entry
    if last['type'] == 'assistant':
        t = ' '.join(texts(last))
        if last.get('isApiErrorMessage') is True or t.startswith('API Error'):
            return 'error', None, one_line(t or 'API Error')
    # 4 keep-open
    if ti is not None and not answered_after:
        lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
        if lines and lines[-1].startswith('NEXT: keep-open'):
            tail = lines[-1]
            return 'keep-open', None, one_line(tail.split('until ', 1)[1] if 'until ' in tail else tail)
    return None


def issue_hint(entries):
    for e in reversed(entries):
        m = re.search(r'(?:^|/)(\d+)-', e.get('gitBranch') or '')
        if m:
            return int(m.group(1))
        m = re.match(r'^(\d+)-', os.path.basename(e.get('cwd') or ''))
        if m:
            return int(m.group(1))
    return None


def scan(root, days, now):
    rows = []
    for path in glob.glob(os.path.join(glob.escape(root), '*', '*.jsonl')):
        try:
            if now - os.path.getmtime(path) > days * 86400:
                continue
        except OSError:
            continue
        entries = load(path)
        if not entries:
            continue
        res = classify(entries)
        if res is None:
            continue
        state, issue, text = res
        when = next((t for t in (parse_ts(e.get('timestamp')) for e in reversed(entries)) if t), None)
        age = now - when.timestamp() if when else now - os.path.getmtime(path)
        project = re.sub(r'^-Users-[^-]+-', '', os.path.basename(os.path.dirname(path)))
        rows.append({'age': fmt_age(age), 'age_seconds': int(age), 'state': state, 'project': project,
                     'session': os.path.basename(path)[:-len('.jsonl')][:8],
                     'issue': issue if issue is not None else issue_hint(entries), 'pergunta': text})
    rows.sort(key=lambda r: (-r['age_seconds'], r['project'], r['session']))
    return rows


def main(argv):
    p = argparse.ArgumentParser(prog='inbox.py', description='Claude Code sessions waiting on the owner.')
    p.add_argument('--days', type=float, default=3)
    p.add_argument('--root', default=os.path.join(os.path.expanduser('~'), '.claude', 'projects'))
    p.add_argument('--json', action='store_true')
    a = p.parse_args(argv)
    rows = scan(a.root, a.days, time.time())
    if a.json:
        sys.stdout.write(json.dumps(rows, ensure_ascii=False) + '\n')
        return 0
    for r in rows:
        sys.stdout.write('%s %s %s %s %s — %s\n' % (
            r['age'], r['state'], r['project'], r['session'],
            '#%d' % r['issue'] if r['issue'] is not None else '-', r['pergunta']))
    counts = ', '.join('%d %s' % (sum(1 for r in rows if r['state'] == s), s)
                       for s in STATES if any(r['state'] == s for r in rows))
    sys.stdout.write('inbox: %d waiting%s\n' % (len(rows), ' (%s)' % counts if rows else ''))
    return 0


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    sys.exit(main(sys.argv[1:]))
