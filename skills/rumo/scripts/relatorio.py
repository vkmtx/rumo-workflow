"""relatorio — the one machine-readable line every build ends with (#98).

`RELATÓRIO: ` + compact JSON, keys in this order: estado, issue, pr, merged, motivo, pergunta.
It sits after PENDING and before the final `NEXT:` line, so a launcher reads a build's outcome
without parsing prose. Estados: progress · waiting · ready · blocked · failed · dropped.

  relatorio.py emit --estado E [--issue N] [--pr URL] [--merged] [--motivo M] [--pergunta TEXT]
      prints the line; exit 2 with the errors on stderr when the fields are invalid.
  relatorio.py parse
      reads stdin, takes the LAST line starting `RELATÓRIO: `, prints its JSON, exit 0;
      no such line, or an invalid one, exit 1.

Stdlib only, Python 3.9-compatible.
"""
import argparse
import json
import re
import sys

PREFIX = 'RELATÓRIO: '
ESTADOS = ('progress', 'waiting', 'ready', 'blocked', 'failed', 'dropped')
KEYS = ('estado', 'issue', 'pr', 'merged', 'motivo', 'pergunta')
NEEDS_MOTIVO = ('blocked', 'failed')
PR_RE = re.compile(r'https://github\.com/[^/\s]+/[^/\s]+/pull/[0-9]+')
MOTIVO_RE = re.compile(r'[a-z0-9-]+')
PERGUNTA_MAX = 500


def validate(d):
    """Return the list of errors for a Relatório (report) dict (empty when valid)."""
    if not isinstance(d, dict):
        return ['not an object']
    errs = []
    for k in KEYS:
        if k not in d:
            errs.append('missing key %s' % k)
    for k in d:
        if k not in KEYS:
            errs.append('unknown key %s' % k)
    if errs:
        return errs
    estado, issue, pr, merged, motivo, pergunta = (d[k] for k in KEYS)
    if estado not in ESTADOS:
        errs.append('estado must be one of %s' % ', '.join(ESTADOS))
    if issue is not None and (not isinstance(issue, int) or isinstance(issue, bool) or issue <= 0):
        errs.append('issue must be an integer > 0 or null')
    if pr is not None and not (isinstance(pr, str) and PR_RE.fullmatch(pr)):
        errs.append('pr must be https://github.com/<owner>/<repo>/pull/<n> or null')
    if not isinstance(merged, bool):
        errs.append('merged must be a boolean')
    elif merged and pr is None:
        errs.append('merged true needs a pr')
    if motivo is not None and not (isinstance(motivo, str) and MOTIVO_RE.fullmatch(motivo)):
        errs.append('motivo must match [a-z0-9-]+ or be null')
    if estado in NEEDS_MOTIVO and motivo is None:
        errs.append('estado %s needs a motivo' % estado)
    if pergunta is not None:
        if not isinstance(pergunta, str) or not pergunta.strip():
            errs.append('pergunta must be a non-empty string or null')
        elif len(pergunta) > PERGUNTA_MAX or re.search(r'[\r\n\x0b\x0c\x85\u2028\u2029]', pergunta):
            errs.append('pergunta must be a single line of at most %d chars' % PERGUNTA_MAX)
    if estado == 'waiting' and pergunta is None:
        errs.append('estado waiting needs a pergunta')
    return errs


def line(d):
    return PREFIX + json.dumps({k: d[k] for k in KEYS}, ensure_ascii=False, separators=(',', ':'))


def _emit(a):
    d = {'estado': a.estado, 'issue': a.issue, 'pr': a.pr, 'merged': a.merged,
         'motivo': a.motivo, 'pergunta': a.pergunta}
    errs = validate(d)
    if errs:
        for e in errs:
            sys.stderr.write('relatorio: %s\n' % e)
        return 2
    sys.stdout.write(line(d) + '\n')
    return 0


def _parse(_a):
    last = None
    for raw in sys.stdin.read().splitlines():
        if raw.startswith(PREFIX):
            last = raw[len(PREFIX):]
    if last is None:
        return 1
    try:
        d = json.loads(last)
    except ValueError:
        return 1
    if validate(d):
        return 1
    sys.stdout.write(json.dumps(d, ensure_ascii=False, separators=(',', ':')) + '\n')
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog='relatorio.py')
    sub = p.add_subparsers(dest='cmd', required=True)
    e = sub.add_parser('emit')
    e.add_argument('--estado', required=True)
    e.add_argument('--issue', type=int)
    e.add_argument('--pr')
    e.add_argument('--merged', action='store_true')
    e.add_argument('--motivo')
    e.add_argument('--pergunta')
    e.set_defaults(fn=_emit)
    q = sub.add_parser('parse')
    q.set_defaults(fn=_parse)
    a = p.parse_args(argv)
    return a.fn(a)


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stdin.reconfigure(encoding='utf-8', errors='replace')  # a stray byte in a log never hides the line
    sys.exit(main(sys.argv[1:]))
