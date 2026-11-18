"""mandato — the host-written, signed record of what an approval grants a lane (#98).

A **Mandato** (mandate) is the immutable record of what an acceptance grants: Política (policy) version,
scope (`repo`, `issue`), `forca` (strength), who asked (`pediu`), who approved (`aprovou`), `fonte`
(source) and `alcance` (reach: `pr` | `merge`),
bound to one worktree and one branch. The host (an external orchestrator) writes it to `<git-dir>/rumo-mandato.json` —
the worktree's own git dir: never committed, outside the working tree — and signs it with HMAC-SHA256
under the key file named by $RUMO_MANDATO_KEY (default ~/.config/rumo/mandato.key).

Read by pr-base-guard.sh and installed beside it in ~/.claude/hooks/. The hooks read authority from
the Mandato, never from prompt text; a hook that finds a Mandato file but cannot import this module
fails closed. No Mandato keeps the old `AUTHORIZED:` behaviour.

Threat model: the agent runs as the same OS user as the host, so the key is not truly secret. The
Mandato stops the habitual paths — an edited scope, a Mandato copied from another worktree/branch, a
hand-written one — not a deliberate agent reading the key with an interpreter.

check() order: presence → regular file → JSON object → fields → key → signature → worktree → branch.
The signature is verified before the binding, so an unsigned file never reaches the binding checks.

CLI:  python3 -I mandato.py check [<dir>]              → exit 0 valid · 3 absent · 1 refused
      python3 -I mandato.py sign --key <keyfile> <json> → the JSON with `assinatura` filled (exit 2 on
                                                          usage or a bad/missing field)

Stdlib only, Python 3.9-compatible.
"""
import datetime
import hashlib
import hmac
import json
import os
import re
import stat
import subprocess
import sys

FILE = 'rumo-mandato.json'
KEY_ENV = 'RUMO_MANDATO_KEY'
DEFAULT_KEY = os.path.join('~', '.config', 'rumo', 'mandato.key')
FORCAS = ('explicito', 'inferido')
FONTES = ('github', 'zulip')
ALCANCES = ('pr', 'merge')
MAX_BYTES = 65536

_REPO = re.compile(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+')
_HEX64 = re.compile(r'[0-9a-f]{64}')


def _is_int(x):
    return isinstance(x, int) and not isinstance(x, bool)


def _nonempty(x):
    return isinstance(x, str) and x.strip() != ''


def _iso(x):
    if not _nonempty(x):
        return False
    s = x[:-1] + '+00:00' if x.endswith('Z') else x
    try:
        datetime.datetime.fromisoformat(s)
    except ValueError:
        return False
    return True


def _branch(x):
    """A branch name as `git branch --show-current` prints it: no surrounding or inner whitespace, no control
    char — anything else could never equal the checked-out branch, so `sign` refuses it up front."""
    return _nonempty(x) and x == x.strip() and not re.search(r'[\s\x00-\x1f\x7f]', x)


# Field → validator, in check order.
REQUIRED = (
    ('v', lambda x: _is_int(x) and x == 1),
    ('politica', _nonempty),
    ('repo', lambda x: isinstance(x, str) and bool(_REPO.fullmatch(x))),
    ('issue', lambda x: _is_int(x) and x > 0),
    ('forca', lambda x: x in FORCAS if isinstance(x, str) else False),
    ('pediu', _nonempty),
    ('aprovou', _nonempty),
    ('fonte', lambda x: x in FONTES if isinstance(x, str) else False),
    ('alcance', lambda x: x in ALCANCES if isinstance(x, str) else False),
    ('worktree', lambda x: _nonempty(x) and os.path.isabs(x)),
    ('branch', _branch),
    ('emitido', _iso),
    ('assinatura', lambda x: isinstance(x, str) and bool(_HEX64.fullmatch(x))),
)


def canonical(m):
    """The signed bytes: every field but `assinatura`, sorted keys, compact, UTF-8."""
    return json.dumps({k: v for k, v in m.items() if k != 'assinatura'}, sort_keys=True,
                      separators=(',', ':'), ensure_ascii=False).encode('utf-8')


def sign(m, key):
    """HMAC-SHA256 of canonical(m) under `key` (bytes), as 64 lowercase hex chars."""
    return hmac.new(key, canonical(m), hashlib.sha256).hexdigest()


def _git(cwd, *args):
    """stdout of `git -C cwd <args>` stripped, None on any failure."""
    try:
        r = subprocess.run(['git', '-C', cwd] + list(args), capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def path(cwd):
    """`<absolute git dir>/rumo-mandato.json` for the worktree holding `cwd`, None outside git."""
    gd = _git(cwd, 'rev-parse', '--absolute-git-dir')
    return os.path.join(gd, FILE) if gd else None


def key_path():
    return os.path.expanduser(os.environ.get(KEY_ENV) or DEFAULT_KEY)


def read_key(p=None):
    """Key file bytes stripped, None when unreadable or empty."""
    try:
        with open(p or key_path(), 'rb') as f:
            k = f.read().strip()
    except OSError:
        return None
    return k or None


def bad_field(m):
    """Name of the first missing or invalid field, '' when all are fine."""
    for name, ok in REQUIRED:
        if name not in m or not ok(m[name]):
            return name
    return ''


def _no_dupes(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise ValueError('duplicate key %r' % k)
        d[k] = v
    return d


def _read(p):
    """File text, refusing symlinks and non-regular files (O_NOFOLLOW + fstat, no TOCTOU)."""
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
    try:
        fd = os.open(p, flags)
    except OSError as e:
        if os.path.islink(p):
            raise _Refused('symlink')
        raise e
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise _Refused('not-a-file')
        data = os.read(fd, MAX_BYTES + 1)
    finally:
        os.close(fd)
    if len(data) > MAX_BYTES:
        raise _Refused('malformed')
    return data


class _Refused(Exception):
    pass


def check(cwd):
    """(status, mandato, reason): ('absent', None, '') · ('valid', m, '') · ('refused', None, reason),
    reason ∈ symlink · not-a-file (a directory, FIFO, device at the path) · malformed · field <name> · no-key ·
    signature · worktree · branch · error."""
    p = path(cwd)
    if not p or not os.path.lexists(p):
        return ('absent', None, '')
    try:
        if os.path.islink(p):
            return ('refused', None, 'symlink')
        data = _read(p)
        try:
            m = json.loads(data.decode('utf-8'), object_pairs_hook=_no_dupes)
        except ValueError:
            return ('refused', None, 'malformed')
        if not isinstance(m, dict):
            return ('refused', None, 'malformed')
        bad = bad_field(m)
        if bad:
            return ('refused', None, 'field ' + bad)
        key = read_key()
        if not key:
            return ('refused', None, 'no-key')
        if not hmac.compare_digest(sign(m, key), m['assinatura']):
            return ('refused', None, 'signature')
        top = _git(cwd, 'rev-parse', '--show-toplevel')
        if not top or os.path.realpath(m['worktree']) != os.path.realpath(top):
            return ('refused', None, 'worktree')
        if m['branch'] != _git(cwd, 'branch', '--show-current'):
            return ('refused', None, 'branch')
        return ('valid', m, '')
    except _Refused as e:
        return ('refused', None, str(e))
    except Exception:  # noqa: BLE001 — a file is present: fail closed
        return ('refused', None, 'error')


USAGE = 'usage: mandato.py check [<dir>] | mandato.py sign --key <keyfile> <json-file>'


def main(argv):
    if argv[:1] == ['check'] and len(argv) <= 2:
        st, m, reason = check(argv[1] if len(argv) == 2 else os.getcwd())
        if st == 'valid':
            print('MANDATO valid alcance=%s issue=%d' % (m['alcance'], m['issue']))
            return 0
        if st == 'absent':
            print('MANDATO absent')
            return 3
        print('MANDATO refused %s' % reason)
        return 1
    if len(argv) == 4 and argv[0] == 'sign' and argv[1] == '--key':
        key = read_key(argv[2])
        if not key:
            print('mandato: key file unreadable or empty: %s' % argv[2], file=sys.stderr)
            return 2
        try:
            with open(argv[3], encoding='utf-8') as f:
                m = json.load(f, object_pairs_hook=_no_dupes)
        except (OSError, ValueError) as e:
            print('mandato: cannot read %s: %s' % (argv[3], e), file=sys.stderr)
            return 2
        if not isinstance(m, dict):
            print('mandato: not a JSON object', file=sys.stderr)
            return 2
        m.pop('assinatura', None)
        m['assinatura'] = '0' * 64  # placeholder so bad_field() checks every other field
        bad = bad_field(m)
        if bad:
            print('mandato: field %s missing or invalid' % bad, file=sys.stderr)
            return 2
        m['assinatura'] = sign(m, key)
        print(json.dumps(m, ensure_ascii=False, indent=2))
        return 0
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
