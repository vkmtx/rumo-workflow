#!/usr/bin/env python3
"""worktree-guard: PreToolUse (matcher Bash). Guards builders running in Orca worktrees
($HOME/orca/workspaces/<repo>/<slug>); override HOME with WORKTREE_GUARD_HOME (tests).
Worktree scope = cwd under the root, or the command names the root path (abs or ~/orca/workspaces/).
Rules, in precedence order:
 1. env copy (worktree scope): deny = BASE 9833fcc's rule, verbatim (_base_env_copy: cp/ln/rsync/install with a
    SOURCE arg named .env / .env.* except .env.example|.sample|.template, or `cat .env > x` / `>> x`), run on the command
    after _reduce, OR the checks #48 added (_extra_env_copy), which only add denies. Only three removals in _reduce can
    relax BASE: (R1) a heredoc body and its terminator (the opener line stays), only when the command holds no
    backslash-newline and the WHOLE command is one allowlisted shape with one heredoc and nothing after its terminator:
    `cat > PATH <<EOF`, `cat >> PATH <<EOF`, `cat <<EOF > PATH`, `tee [-a] PATH <<EOF`, `git commit … -F - <<EOF`,
    `gh pr|issue create|edit|comment … --body-file - <<EOF`, and `git commit … -m` / `gh … --body` `"$(cat <<'EOF'`
    closed by a `)"` line, each may start `git add ARGS &&`; an unquoted delimiter whose body holds any `$` or a backtick
    is not inert, and the body ends at the first line equal to its delimiter; (R2) `N>/dev/null`, `N>>/dev/null` and
    `N>&1` for N != 1 (every other redirect stays a write: `2>x >&2` is a copy); (R3) one `N>file` / `N>>file` (N one digit, not 1)
    when the whole one-line command is `cat` with plain words holding that only redirect, piped only into grep, head,
    tail or wc with plain words (FD_FILE_READ) and the target is one plain word naming no .env: those readers have no write option. The added checks join continuations,
    drop comments and read every line as a segment: cat with any write (`&>`, `&>>`, `>|`, `1>`, `>& file`), a copy on
    a later line or in a scanned heredoc body, and `xargs … cp {} …` or `rsync --files-from=-` fed a .env name on
    stdin (counted over the whole command, except the test element of the one whole-command shape XARGS_SHAPE:
    `test -f .env` and the like, then flagless `git ls-files` piped to `xargs -I{} cp {} DEST`, with no other
    .env name); #58 adds (a) an unquoted heredoc body with a .env name inside
    a `$(…)`, `${…}` or backtick span, and (b) a heredoc body naming a .env fed to an interpreter, a shell or ssh
    (INTERP as any word of the `<<`'s list element: `python3 - <<EOF`, `sudo bash`, `mise exec -- python3`, `ssh h`;
    every such body when the command holds `()`, `function`, `eval` or `alias`; reads included: fails closed, except (#111) a body that a bare `python3 [-FLAGS] -` reads as its program, quoted or with no `$`/backtick/backslash, whose .env names _py_reads_env proves are data), both run on the command before and after the continuation join, and (c) `cat` reading a .env whose stdout is piped (`|`, `|&`) into `tee FILE`
    (after sudo/env/nohup-style wrappers; /dev/null, /dev/stdout, /dev/stderr are no file) or into a later pipeline
    stage with a write (`cat .env | grep x > y`). Worktrees use their own .env.local on a
    local DB. Owner override: `#env-ok` in the user's latest real message of the transcript (type user,
    role user, not isMeta) -> allow. `#env-ok` counts only as the owner's own typed message: skills never
    put it into a prompt they write for another session (a wave orchestrator copies the .env itself, in
    its own session). A message with any line starting `AUTHORIZED:`, `WAVE BRIEF:` or `LAUNCHED-BY:` (a launch
    prompt, `owner_message.py`) never counts, whole.
 2. migrations (worktree scope): prisma/drizzle/rails/knex/sequelize/alembic/typeorm/npm db:* and
    supabase db push|reset / migration up -> deny when the target DB is not local (URL from the
    command's env assignments; none, or one with no resolvable host: also the worktree's .env files). supabase: deny
    unless --local or a local --db-url. Each family is checked on its own. No URL found -> allow. Only the host is ever
    printed, never credentials. Flag/URL reads that can lead to allow (--local, a local --db-url, a resolved inline URL)
    skip comments; deny-side reads (--linked, every remote --db-url, inline URLs) see the raw text.
 3. test concurrency (all scopes): jest/vitest/<pm> test, or rumo's accept-step.sh, while >= the limit of logical test
    runs are alive -> poll every RUMO_TEST_POLL_S (default 3) s for up to RUMO_TEST_WAIT_S
    (default 50) s, admit as soon as a slot frees, else deny naming their PIDs. --runInBand/-i count too (they only
    skip the worker-cap nudge). The hook's settings timeout must exceed RUMO_TEST_WAIT_S (70 s for the default).
    Limit = RUMO_MAX_TEST_RUNS when set (exact, no memory bonus), else 3 when free memory is >= 30% (`/usr/bin/memory_pressure -Q`
    or the file WORKTREE_GUARD_MEM, same output; macOS only), else 2 (unknown memory = 2); re-read at each admission attempt.
    Process list = `ps -axo pid=,ppid=,stat=,etime=,command=`
    (or file WORKTREE_GUARD_PS, same 5 columns). Logical run = a node/bun process whose script is jest's or
    vitest's entry point; workers, watchers, pm wrappers and shells never count, and a runner under another
    runner (ppid chain) is the same run. Stale runs don't count: STAT has Z/T, or etime exceeds
    RUMO_STALE_TEST_MIN minutes (default 20). Watchers are told apart by whole argument after the script
    (--watch, --watchAll, --api, --ui, --watch=/--watchAll= not false, vitest's -w and watch/dev subcommand; jest's
    -w is --maxWorkers), never by substring. Admission takes a slot under a lock (<home>/.claude/state/worktree-guard-slots.json): a reservation
    lives RUMO_TEST_RESERVE_S (default 15; 0 = off) s or until a runner it had not seen (by pid) shows up in ps, and counts
    toward the limit, so waiters polling in the gap before the admitted run appears cannot all admit.
    A runner whose process tree used under RUMO_IDLE_CPU_PCT% (default 1) CPU for at least RUMO_IDLE_MIN_S
    (default 30) s of this hook's wait counts as hung and not toward the limit; CPU comes from
    `ps -axo pid=,time=` or the file WORKTREE_GUARD_CPU; the deny lists cwd and age per PID.
    In a worktree, jest/vitest without a worker cap -> nudge.
 4. sleep-polling (all scopes, nudge only): a segment starting `sleep N` with N >= 120s (`Nm` = minutes).
Env knobs (tests): WORKTREE_GUARD_HOME, WORKTREE_GUARD_PS, WORKTREE_GUARD_MEM, WORKTREE_GUARD_CPU, WORKTREE_GUARD_CWD,
WORKTREE_GUARD_SCAN_BUDGET_S (seconds of analysis per call, default 15).
Output: deny/nudge as hookSpecificOutput JSON, exit 0. Fail-open: any error -> exit 0 silently, except a scan that
overruns WORKTREE_GUARD_SCAN_BUDGET_S (default 15 s; the test-slot wait is not counted) -> deny."""
import ast, bisect, builtins, collections, fcntl, functools, json, os, re, shlex, signal, subprocess, sys, time, warnings
from urllib.parse import urlparse

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
# Module missing beside the hook -> no override counts (fail closed) and every other rule still runs.
try:
    import owner_message
except Exception:
    owner_message = None

ENV_OK = ('.example', '.sample', '.template')  # suffixes: .env.example, .env.local.example, …
ENV_RE = re.compile(r'^\.env(\..+)?$')
LOCAL_HOSTS = {'localhost', '127.0.0.1', '0.0.0.0', '::1', 'host.docker.internal', 'db', 'postgres'}
# Patterns match the start of an executed command segment (see segments()), never text inside
# an argument — `grep "prisma migrate"` or a commit message is not a migration.
MIGRATE = [re.compile(p) for p in (
    r'prisma\s+(migrate\s+(deploy|dev|reset)|db\s+(push|execute|seed))',
    r'drizzle-kit\s+(push|migrate)',
    r'(rails|rake)\s+db:(migrate|reset|drop|seed|schema:load|setup)',
    r'knex\s+migrate',
    r'sequelize(-cli)?\s+db:(migrate|seed)',
    r'alembic\s+(upgrade|downgrade)',
    r'typeorm\s+migration:run',
    r'(npm|pnpm|yarn|bun)\s+(run\s+)?(db:(?!studio|generate|types)[\w:-]+|migrate[\w:-]*)')]
SUPABASE_PUSH = re.compile(r'supabase\s+db\s+push\b')          # defaults to the linked (remote) project
SUPABASE_LOCAL = re.compile(r'supabase\s+(db\s+reset|migration\s+up)\b')  # default to local; remote only via --linked/--db-url
URL_ENV = re.compile(r'\b(DATABASE_URL|DIRECT_URL|POSTGRES_URL|POSTGRES_PRISMA_URL|SUPABASE_DB_URL)=(\S+)')
def _db_urls(text):
    """Every --db-url value in text, in order."""
    return re.findall(r'--db-url[=\s]+(\S+)', text)


def _inline_urls(text):
    """Every URL_ENV assignment value in text, quotes stripped, in order."""
    return [u.strip('\'"') for _, u in URL_ENV.findall(text)]


def _resolved(urls):
    """The urls with a host, a file DB or a local no-host form; the rest ($PROD, a path) is unresolved: the .env files decide."""
    return [u for u in urls if host_of(u) or is_file_db(u) or LOCAL_NO_HOST.match(u)]


URL_KEYS = {'DATABASE_URL', 'DIRECT_URL', 'POSTGRES_URL', 'POSTGRES_PRISMA_URL', 'SUPABASE_DB_URL'}
ENV_FILES = ('.env', '.env.local', '.env.development', '.env.development.local')
TEST_RE = re.compile(r'(jest|vitest)\b|(npm|pnpm|yarn|bun)\s+(run\s+)?(test|t)\b')
RUNNER_RE = re.compile(r'(jest|vitest)\b')
ACCEPT_RE = re.compile(r'((ba|z)?sh\s+)?accept-step\.sh\b')  # rumo's accept-step.sh runs a step's Verify
CAPS = ('--maxWorkers', '--runInBand', '--poolOptions', '--pool.threads.maxThreads', '--no-file-parallelism')
NODE_BINS = ('node', 'nodejs', 'bun')
NODE_VALUE_FLAGS = {'-r', '--require', '--import', '--loader', '--experimental-loader', '-C', '--conditions',
                    '--env-file', '--inspect-port', '--title'}  # node flags whose next argv word is their value
RUNNER_SCRIPT = re.compile(r'(?:^|/)(?:jest|vitest)(?:\.[cm]?js)?$')  # .bin/jest, jest/bin/jest.js, vitest/vitest.mjs


SEPARATORS = {';', '&&', '||', '|', '&', '(', ')', '{', '}', ';;'}
LEAD = {'sudo', 'env', 'time', 'nice', 'nohup', 'timeout', 'then', 'do', 'else', 'elif', 'if', 'while',
        'until', '!', 'exec', 'npx', 'bunx', 'npm', 'pnpm', 'yarn', 'bun', 'x', 'dlx', 'node', 'dotenv',
        'bundle', 'python', 'python3', 'command', 'xargs'}
HEREDOC_OPEN = re.compile(r"""<<-?\s*(?:(['"])(\w+)\1|(\w+))""")  # a heredoc opener, read as in _drop_heredocs' docstring regex
TERM_SPOT = re.compile(r'(?<!\s)(\s+)(\w+)(?=(\s*))')  # a word after a whitespace run: maybe a terminator line
ENV_ASSIGN = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')  # tested on the raw token: its value may hold `/`
RESERVED_WORDS = {'if', 'then', 'do', 'else', 'elif', 'while', 'until', '!', 'time'}  # the shell reads an assignment after these
SIMPLE_SUBST = re.compile(r'\$\{[^{}]*\}|\$\([^()]*\)|`[^`]*`')  # ${…} / $(…) / `…` with nothing of its kind nested inside
MASK_PASSES = 8  # nesting levels of SIMPLE_SUBST read as one word; deeper ones keep the plain lexer's segments
LOCAL_NO_HOST = re.compile(r'^(?::memory:$|[A-Za-z][A-Za-z0-9+.-]*:///(?!.*[?&]host=))')  # postgres:///db (socket), :memory:
SCAN_BUDGET_S = 15.0  # s of analysis per call (hook timeout 70 s, minus up to 50 s in wait_for_slot); env WORKTREE_GUARD_SCAN_BUDGET_S overrides


class ScanBudget(BaseException):
    """The scan budget ran out. BaseException so the helpers' `except Exception` cannot swallow it."""


def _over_budget(signum, frame):
    raise ScanBudget()


def _drop_heredocs(text):
    """text with each heredoc (opener through its terminator line) replaced by a newline: exactly what
    re.sub(r"<<-?\\s*(['\\"]?)(\\w+)\\1[^\\n]*\\n.*?\\n\\s*\\2\\s*(\\n|$)", '\\n', text, flags=re.S) returns, in
    O(n log n) instead of that regex's O(n^2) (each unterminated opener rescanned to the end). Terminator spots are
    indexed once by word; an unquoted delimiter may match as any prefix of its word, longest first, like the regex."""
    n, idx = len(text), {}
    for m in TERM_SPOT.finditer(text):
        lead, trail = m.group(1), m.group(3)
        nl = lead.rfind('\n')
        if nl < 0:
            continue
        if m.end(2) + len(trail) == n:
            end = n
        elif '\n' in trail:
            end = m.end(2) + trail.rfind('\n') + 1
        else:
            continue
        nls, ends = idx.setdefault(m.group(2), ([], []))
        nls.append(m.start(1) + nl)
        ends.append(end)
    lengths = sorted({len(k) for k in idx}, reverse=True)
    out, pos, at = [], 0, 0
    while True:
        m = HEREDOC_OPEN.search(text, at)
        if not m:
            break
        word, end = m.group(2) or m.group(3), None
        e = text.find('\n', m.end())
        if e >= 0:
            for d in ([word] if m.group(1) else [word[:k] for k in lengths if k <= len(word)]):
                if d in idx:
                    nls, ends = idx[d]
                    k = bisect.bisect_left(nls, e + 1)
                    if k < len(nls):
                        end = ends[k]
                        break
        if end is None:
            at = m.start() + 1
            continue
        out.append(text[pos:m.start()])
        out.append('\n')
        pos = at = end
    out.append(text[pos:])
    return ''.join(out)


def _lex(cmd, commenters='', strict=False):
    """cmd's segments as token lists, shlex reading `commenters` as comment starts. Unbalanced quotes: plain whitespace,
    or [] when strict."""
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=';&|(){}')
    lex.whitespace_split = True
    lex.commenters = commenters
    try:
        toks = list(lex)
    except ValueError:
        if strict:
            return []
        toks = cmd.split()
    segs, cur = [], []
    for t in toks:
        if t in SEPARATORS:
            if cur:
                segs.append(cur)
            cur = []
        else:
            cur.append(t)
    if cur:
        segs.append(cur)
    return segs


def _subst_closers(cmd):
    """Offsets of the `)` in cmd that close a `$(` (or `$((`): a `#` right after one is inside a word, not a comment."""
    closers, stack, q, j = set(), [], None, 0
    while j < len(cmd):
        ch = cmd[j]
        if q == "'":
            q = None if ch == "'" else q
        elif ch == '\\':
            j += 1
        elif ch in '\'"' and q in (None, ch):
            q = None if q else ch
        elif ch == '(' and (q is None or cmd[j - 1:j] == '$'):
            stack.append(cmd[j - 1:j] == '$')
        elif ch == ')' and stack and (q is None or stack[-1]):
            if stack.pop():
                closers.add(j)
        j += 1
    return closers


def _comment_spans(cmd):
    """_shell_scan's comment spans of cmd, or each line's own when the whole-command scan is unsure (a line it is
    unsure of keeps its text), minus a `#` right after a `)` that closes a `$(` (`$(…)#x` is one word)."""
    scan = _shell_scan(cmd)
    if scan:
        spans = scan[0]
    else:
        spans, at = [], 0
        for line in cmd.split('\n'):
            line_scan = _shell_scan(line)
            spans += [(s + at, e + at) for s, e in (line_scan[0] if line_scan else [])]
            at += len(line) + 1
    closers = _subst_closers(cmd)
    return [(s, e) for s, e in spans if s - 1 not in closers]


def _split(cmd, depth=0):
    """Executed segments as token lists: quotes respected, heredoc bodies dropped, `bash -c '…'` opened. Two readings,
    their segments merged: (1) _comment_spans cut, each comment ending at its own newline, which stays in the text for
    a `bash -c` body, shlex's comments off (a `#` inside a word or quotes is none); (2) shlex's comments on, which run
    to the end of cmd once newlines are joined: the reading before (1), kept so no segment it finds is lost (a backtick
    ends a comment in bash, _shell_scan runs it to the newline)."""
    cut = _cut(cmd, _comment_spans(cmd))
    out, seen = [], set()
    def add(seg):
        if tuple(seg) not in seen:
            seen.add(tuple(seg))
            out.append(seg)
    for text, commenters in ((_drop_heredocs(cut).replace('\n', '\n ; '), ''),
                             (_drop_heredocs(cmd).replace('\n', ' ; '), '#')):
        for seg in _lex(text, commenters):
            for i, t in enumerate(seg[:-2]):  # bash -c 'inner' / sh -c "inner"; its own _split reads its substitutions
                if os.path.basename(t) in ('bash', 'sh', 'zsh') and seg[i + 1] == '-c' and depth < 3:
                    for inner in _split(seg[i + 2], depth + 1):
                        add(inner)
            add(seg)
        masked = text
        for _ in range(MASK_PASSES):  # the lexer cuts X=$(pwd)/a apart: also read each simple substitution as one word
            prev, masked = masked, SIMPLE_SUBST.sub('V', masked)
            if masked == prev:
                break
            for seg in _lex(masked, commenters, strict=True):
                add(seg)
    return out


def _basenames(seg):
    """seg with each path reduced to its basename, except an assignment where one is read: its value may hold `/`.
    That is the leading run (bare reserved words, `time -p`, assignments), then env/sudo with their flags;
    sudo's `--` ends it, so does any other word: from there a NAME=value/… is a command path."""
    toks, reading, reserved, flags, sudo = [], True, True, False, False
    for t in seg:
        word = os.path.basename(t) if '/' in t and not t.startswith('-') else t
        is_assign = reading and ENV_ASSIGN.match(t)
        toks.append(t if is_assign else word)
        if is_assign:
            reserved = False
        elif reserved and t in RESERVED_WORDS:
            flags = t == 'time'
        elif reading and word in ('env', 'sudo') and (t == word or t.startswith('/')):
            reserved, flags, sudo = False, True, sudo or word == 'sudo'
        elif not (flags and t.startswith('-') and not (sudo and t == '--')):
            reading = False
    return toks


@functools.lru_cache(maxsize=4)
def segments(cmd):
    """Every way an executed segment can start once launcher words are skipped:
    `sudo timeout 600 FOO=1 pnpm exec ./node_modules/.bin/prisma migrate dev` yields
    'prisma migrate dev' among its candidates. Patterns are matched at the start of a candidate.
    Each segment is walked twice: with assignments kept whole (_basenames) and with every path reduced to its
    basename, the reading the guard had before; the second only adds candidates, so no earlier deny is lost."""
    cands = []
    for seg in _split(cmd):
        plain = [os.path.basename(t) if '/' in t and not t.startswith('-') else t for t in seg]
        for reading in (_basenames(seg), plain):
            toks = [re.sub(r'(?<=\w)@[\w.^~*-]+$', '', t) for t in reading]  # prisma@5 -> prisma
            prev = ''
            for i, t in enumerate(toks):
                cands.append(' '.join(toks[i:]))
                skippable = (t in LEAD or t.startswith('-') or ENV_ASSIGN.match(t)
                             or t.isdigit() or prev in ('-e', '--env', '-f', '-m') or t.startswith('.env'))
                if not skippable:
                    break
                prev = t
    return tuple(cands)


def starts(pattern, cmd):
    return any(pattern.match(seg) for seg in segments(cmd))


def out(key, text):
    signal.setitimer(signal.ITIMER_REAL, 0)  # printing the verdict is final
    body = {"hookEventName": "PreToolUse", key: text}
    if key == 'permissionDecisionReason':
        body["permissionDecision"] = "deny"
    print(json.dumps({"hookSpecificOutput": body}, ensure_ascii=False))


def deny(reason):
    out('permissionDecisionReason', reason)


def is_file_db(url):
    return url.startswith('file:') or url.lower().startswith('sqlite')


def host_of(url):
    url = url.strip('\'"')
    if is_file_db(url):
        return None
    try:
        h = urlparse(url).hostname
    except Exception:
        h = None
    if not h:
        m = re.search(r'@([^/:?\s]+)', url)
        h = m.group(1) if m else None
    return h


def is_local(host):
    return host is None or host.lower() in LOCAL_HOSTS or host.lower().endswith('.local')


FD_REDIR = re.compile(r'''(?:(?<=[\s;&|(])|^)(?:[02-9]|[1-9]\d+)(?:>>?\s*(["']?)/dev/null\1|>&\s*1)(?=[\s;&|()]|$)''')  # N>/dev/null, N>>/dev/null, N>&1 (N != 1)
COPY_CMDS = ('cp', 'ln', 'rsync', 'install')  # the copy commands of the non-frozen checks (_base_env_copy keeps its own)
WRITE_OPS = {'>', '>>', '&>', '&>>', '>|'}


def _is_terminator(line, delim, dash):
    """The heredoc terminator rule: the line equals the delimiter, leading tabs stripped only for `<<-`."""
    return (line.lstrip('\t') if dash else line) == delim


def _shell_scan(cmd):
    """(comments, heredocs) of cmd, scanned like the shell does, or None when the scan is unsure (unbalanced quote,
    `((` without `))`, a heredoc opener without its terminator). comments = [(start, end)] spans; heredocs =
    [(op, quoted, body_start, body_end)]: op = index of `<<`, quoted = the raw delimiter word holds a quote or a backslash,
    body = cmd[body_start:body_end] (body_end = start of the terminator line; an empty body has start == end).
    Quotes, `$'…'`, backslashes, `<<<` here-strings, `((…))` arithmetic and heredoc bodies (each ends at the FIRST line
    equal to its delimiter, _is_terminator, an empty body included) never hold a comment."""
    comments, docs, pending, i, n = [], [], [], 0, len(cmd)
    while i < n:
        c = cmd[i]
        if c == '\\':
            i += 2
        elif c == "'" or (c == '$' and cmd[i + 1:i + 2] == "'"):
            j = i + (2 if c == '$' else 1)
            while j < n and cmd[j] != "'":
                j += 2 if c == '$' and cmd[j] == '\\' else 1
            if j >= n:
                return None
            i = j + 1
        elif c == '"':
            j = i + 1
            while j < n and cmd[j] != '"':
                j += 2 if cmd[j] == '\\' else 1
            if j >= n:
                return None
            i = j + 1
        elif c == '#' and (i == 0 or cmd[i - 1] in ' \t\n;&|()'):
            j = cmd.find('\n', i)
            j = n if j < 0 else j
            comments.append((i, j))
            i = j
        elif cmd.startswith('((', i):
            j = cmd.find('))', i + 2)
            if j < 0:
                return None
            i = j + 2
        elif cmd.startswith('<<<', i):
            i += 3
        elif cmd.startswith('<<', i):
            j = i + 2
            dash = cmd[j:j + 1] == '-'
            j += dash
            while j < n and cmd[j] in ' \t':
                j += 1
            k = j
            while k < n and cmd[k] not in ' \t\n;&|()<>':
                k += 1
            delim = re.sub(r'''["'\\]''', '', cmd[j:k])
            if not delim:
                return None
            pending.append((delim, dash, i, any(q in cmd[j:k] for q in '\'"\\')))
            i = k
        elif c == '\n' and pending:
            pos = i + 1
            for delim, dash, op, quoted in pending:
                start = pos
                while True:
                    if pos >= n:
                        return None
                    nl = cmd.find('\n', pos)
                    nl = n if nl < 0 else nl
                    line, at = cmd[pos:nl], pos
                    pos = min(nl + 1, n)
                    if _is_terminator(line, delim, dash):
                        docs.append((op, quoted, start, at))
                        break
            pending, i = [], pos
        else:
            i += 1
    return None if pending else (comments, docs)


def _cut(cmd, spans):
    """cmd with each span blanked to as many spaces, so offsets into cmd (heredoc bodies) stay valid."""
    out, at = [], 0
    for s, e in sorted(spans):
        if s >= at:
            out.append(cmd[at:s] + ' ' * (e - s))
            at = e
    return ''.join(out) + cmd[at:]


_W = r"""(?:[^\s|;&<>()$`'"\\#]|"[^"$`\\|;&<>\n]*"|'[^'|;&<>\n]*')+"""  # a plain word: no expansion, operator or comment
_ARGS = rf'(?:[ \t]+{_W})*'
_ADD = rf'(?:git[ \t]+add{_ARGS}[ \t]*&&[ \t]*)?'  # optional `git add ARGS && ` prefix
_DELIM = r"""<<(?P<dash>-?)[ \t]*(?P<q>['"]?)(?P<delim>\w+)(?P=q)"""
_GH = r'gh[ \t]+(?:pr|issue)[ \t]+(?:create|edit|comment)'
SAFE_HEREDOC = tuple(re.compile(rf'^[ \t]*{_ADD}{p}[ \t]*$') for p in (  # opener line of a heredoc whose body is data
    rf'cat[ \t]*>>?[ \t]*{_W}[ \t]+{_DELIM}',                    # cat > PATH <<EOF, cat >> PATH <<EOF
    rf'cat[ \t]+{_DELIM}[ \t]*>>?[ \t]*{_W}',                     # cat <<EOF > PATH
    rf'tee(?:[ \t]+-a)?[ \t]+{_W}[ \t]+{_DELIM}',                 # tee [-a] PATH <<EOF (stdout not piped)
    rf'git[ \t]+commit{_ARGS}[ \t]+-F[ \t]+-[ \t]+{_DELIM}',      # git commit -F - <<EOF
    rf'{_GH}{_ARGS}[ \t]+--body-file[ \t]+-[ \t]+{_DELIM}',        # gh pr create … --body-file - <<EOF
))
SAFE_SUBST = (  # `-m "$(cat <<'EOF'` … `EOF` / `)"`: the body is the message, its last line closes the substitution
    re.compile(rf'^[ \t]*{_ADD}git[ \t]+commit{_ARGS}[ \t]+-m[ \t]+"\$\(cat[ \t]+{_DELIM}[ \t]*$'),
    re.compile(rf'^[ \t]*{_ADD}{_GH}{_ARGS}[ \t]+--body[ \t]+"\$\(cat[ \t]+{_DELIM}[ \t]*$'))
SUBST_CLOSE = re.compile(rf'^\)"{_ARGS}[ \t]*$')


def _inert_rest(cmd):
    """The command with its heredoc body and terminator dropped when the WHOLE command is one allowlisted shape
    (SAFE_HEREDOC, or SAFE_SUBST closed by a `)"` line), else None. Shape = one opener line holding the only heredoc,
    the body up to the FIRST line equal to the delimiter (leading tabs only for `<<-`), then only whitespace — or, for
    SAFE_SUBST, exactly one `)"` line with plain words. An unquoted delimiter whose body holds any `$` or a backtick can
    run that text (`$(…)`, bash 5.3 `${ cmd; }`, zsh `${(e):-…}`), so it is not inert."""
    lines = cmd.rstrip().split('\n')
    subst = False
    m = next((m for m in (r.match(lines[0]) for r in SAFE_HEREDOC) if m), None)
    if m is None:
        m = next((m for m in (r.match(lines[0]) for r in SAFE_SUBST) if m), None)
        subst = m is not None
    if m is None:
        return None
    delim, dash = m.group('delim'), m.group('dash')
    end = next((k for k in range(1, len(lines)) if _is_terminator(lines[k], delim, dash)), None)
    if end is None:
        return None
    body = '\n'.join(lines[1:end])
    if not m.group('q') and ('$' in body or '`' in body):
        return None
    tail = lines[end + 1:]
    if subst:
        return lines[0] + '\n' + tail[0] if len(tail) == 1 and SUBST_CLOSE.match(tail[0]) else None
    return None if tail else lines[0] + '\n'


# R3's one shape: `cat` then plain words with one `N>file`, then only `| grep|head|tail|wc` stages with plain words.
# _W holds no `<>|;&$`, backtick, `\`, `(`, so the matched redirect is the only redirect in the whole command; the
# whitespace before the digit is mandatory (`a\ 2>x` and `"a"2>x` redirect stdout); `cat .env 2 >x` (blank between the
# digit and `>`) never matches: shlex cannot tell it from `2>x`, hence a raw-text regex; the readers are a closed set
# with no write option (no `sort -o`, `sed w`, `awk`, `tee`, `dd`, `sponge`). Anchored, and _reduce runs it on one line.
# The fd is one ASCII digit: zsh, dash and ksh read `10>x` as the word `10` plus a stdout redirect, and Python's `\d`
# also matches non-ASCII digits, which every shell reads as a word (`1٣>x` redirects stdout).
# The target is one plain `[\w./-]+` word: a glob (`2>.en?`) or brace reaches a file no name check can see.
FD_FILE_READ = re.compile(rf'^[ \t]*cat(?:[ \t]+{_W})*[ \t]+(?P<r>[02-9]>>?[ \t]*(?P<t>[\w./-]+))(?:[ \t]+{_W})*'
                          rf'(?:[ \t]*\|[ \t]*(?:grep|head|tail|wc)(?:[ \t]+{_W})*)*[ \t]*\Z')


def _reduce(cmd):
    """cmd after the only three removals allowed to relax BASE's rule, and nothing else (no continuation join, no line
    split, no comment strip): (R1) when cmd holds no backslash-newline (bash would join it inside an unquoted body
    and could end the heredoc elsewhere) and is one whole allowlisted heredoc shape (_inert_rest), its body and
    terminator are dropped and the opener line kept; (R3) on a one-line command that is wholly FD_FILE_READ, its one
    `N>file` (target one plain word) is dropped unless the target as typed or lowered (`2>.ENV` opens `.env` on a
    case-insensitive volume) names a .env (`cat .env 2>.env | head` truncates the file), before R2 so that
    `cat .env 2>/dev/null 2>x` keeps two redirects and stays denied; (R2)
    `N>/dev/null`, `N>>/dev/null`, `N>&1` (N != 1) are dropped."""
    if '\\\n' not in cmd:
        rest = _inert_rest(cmd)
        if rest is not None:
            cmd = rest
    if '\n' not in cmd:
        m = FD_FILE_READ.match(cmd)
        if m and not (_env_names_max(m['t']) or _env_names_max(m['t'].lower())):
            cmd = cmd[:m.start('r')] + ' ' + cmd[m.end('r'):]
    return FD_REDIR.sub(' ', cmd)


def _env_word(a):
    b = os.path.basename(a)
    return bool(ENV_RE.match(b)) and not b.endswith(ENV_OK)


_NAME_SPLIT = re.compile(r"""[\s'"`()$;|&<>=,{}\[\]]+""")


def _env_names(text):
    """How many .env names (_env_word) text holds, split on whitespace, quotes and shell/code punctuation."""
    return sum(_env_word(w) for w in _NAME_SPLIT.split(text) if w)


PY_NAME = r'python[\d.]*'  # a python launcher's basename (INTERP, _py_stdin_program)
INTERP = re.compile(r'^(?:ssh|bash|sh|zsh|dash|ksh|' + PY_NAME + r'|node|nodejs|bun|deno|ruby|perl|php|Rscript|lua|osascript)$')  # runs its stdin
UNSURE_DEFS = {'function', 'eval', 'alias'}  # with `()`: the command a heredoc feeds may be defined or built elsewhere
COMPOUND_WORDS = {'if', 'then', 'else', 'elif', 'fi', 'do', 'done', 'case', 'esac', 'while', 'until', 'for', 'select', 'coproc'}
# words that make the `<<`'s list element unsure in _heredoc_elem; `eval` is left out to keep the set exactly as before
# (_defines_or_evals already fails closed on it)
ELEM_UNSURE = COMPOUND_WORDS | (UNSURE_DEFS - {'eval'})


def _interp_words(words):
    """True when any piece (_NAME_SPLIT) of any word has an INTERP basename: within the `<<`'s list element every
    word counts, not only the command word, since an unknown launcher (`mise exec --`, `op run --`, `direnv exec .`,
    `nix-shell --run`, `!`) may run any later word on the heredoc."""
    return any(INTERP.match(os.path.basename(p)) for w in words for p in _NAME_SPLIT.split(w) if p)


PY_STR_METHODS = frozenset({'replace', 'startswith', 'endswith', 'count', 'find', 'rfind', 'index', 'rindex', 'split',
    'rsplit', 'splitlines', 'partition', 'rpartition', 'strip', 'lstrip', 'rstrip', 'removeprefix', 'removesuffix',
    'join', 'format', 'lower', 'upper', 'casefold', 'encode', 'decode'})
PY_WRITE_METHODS = frozenset({'write', 'write_text', 'write_bytes', 'writelines'})
PY_SAFE_FUNCS = frozenset({'print', 'len', 'str', 'repr', 'isinstance', 'any', 'all'})  # none calls a callable argument
PY_UNSURE_NAMES = frozenset({'exec', 'eval', 'compile', '__import__', 'getattr', 'setattr', 'delattr', 'globals',
    'locals', 'vars', 'breakpoint', '__builtins__',
    'type'})  # fix round 6: type(obj) hands out obj's class (`type(h.buffer.raw)` is FileIO, which opens a name)
PY_UNSURE_ATTRS = frozenset({'import_module', '__dict__', '__builtins__', '__globals__', '__getattribute__',
    # #111 fix round 4: a module on a Path (`p.parser` is posixpath, so `.os`); a frame or code object (its globals
    # and builtins dicts hand out `open` by a string key)
    'parser', 'gi_frame', 'gi_code', 'gi_yieldfrom', 'cr_frame', 'cr_code', 'cr_await', 'ag_frame', 'ag_code',
    'ag_await', 'f_globals', 'f_builtins', 'f_locals', 'f_back', 'f_code', 'tb_frame', 'tb_next'})
# #111 fix round 1: the only modules a body citing .env may import (exact names); the Path methods that touch a file
# (`replace` among them, so that str method passes only on a string-shaped receiver); container methods that are a flow
# fix round 4: no `string` (Formatter().get_field turns a string into a bound attribute, no Attribute node)
PY_SAFE_MODULES = frozenset({'pathlib', 're', 'json', 'textwrap', 'difflib', 'collections', 'itertools', 'datetime'})
PY_PATH_METHODS = frozenset({'replace', 'rename', 'symlink_to', 'hardlink_to', 'link_to', 'copy', 'copy_into', 'move',
    'move_into', 'touch', 'open', 'read_text', 'read_bytes', 'write_text', 'write_bytes', 'samefile', 'unlink', 'chmod'})
PY_FLOW_METHODS = frozenset({'append', 'extend', 'insert', 'add', 'update', 'setdefault', 'appendleft', 'extendleft'})
PY_COOKIE = re.compile(r'^[ \t\f]*#.*?coding[:=][ \t]*[-\w.]+')  # PEP 263's comment form, on the first two lines
# #111 fix round 2: calls that touch a file (on a receiver; `open(...)` too) and those only an open() handle has
PY_HANDLE_METHODS = frozenset({'read', 'readline', 'readlines', 'write', 'writelines',
    'readall', 'readinto', 'readinto1', 'read1', 'peek', 'fileno'})  # fix round 6: raw and buffered handle reads
PY_TOUCH_METHODS = PY_HANDLE_METHODS | PY_WRITE_METHODS | PY_PATH_METHODS | frozenset({'read_text', 'read_bytes',
    'iterdir', 'glob', 'rglob', 'walk', 'exists', 'is_file', 'stat', 'resolve'})
PY_PATH_ARG_METHODS = frozenset({'replace', 'rename', 'symlink_to', 'hardlink_to', 'link_to', 'copy', 'copy_into',
    'move', 'move_into', 'samefile'})  # Path methods whose arguments name a second file
# fix round 5: a directory listing hands out paths a .env filter can pick (any call or bare attribute or name); and the
# only attributes of a safe module (`m.x`, `from m import x`) a body citing .env may use — functions, classes, flags
PY_ENUM_NAMES = frozenset({'iterdir', 'glob', 'rglob', 'walk', 'listdir', 'scandir', 'fwalk', 'iglob'})
PY_SAFE_FUNCS_BY_MODULE = {
    'pathlib': frozenset({'Path', 'PurePath', 'PurePosixPath'}),
    're': frozenset({'sub', 'subn', 'search', 'match', 'fullmatch', 'findall', 'finditer', 'split', 'escape', 'compile',
                     'IGNORECASE', 'MULTILINE', 'DOTALL', 'VERBOSE', 'I', 'M', 'S', 'X'}),
    'json': frozenset({'dumps', 'loads', 'dump', 'load'}),
    'textwrap': frozenset({'dedent', 'indent', 'fill', 'wrap', 'shorten'}),
    'difflib': frozenset({'unified_diff', 'context_diff', 'ndiff', 'SequenceMatcher', 'get_close_matches'}),
    'collections': frozenset({'Counter', 'OrderedDict', 'defaultdict', 'namedtuple', 'deque', 'ChainMap'}),
    'itertools': frozenset({'chain', 'islice', 'groupby', 'zip_longest', 'product', 'permutations', 'combinations',
                            'accumulate', 'count', 'repeat', 'cycle', 'starmap', 'takewhile', 'dropwhile', 'tee',
                            'pairwise', 'batched', 'compress', 'filterfalse'}),
    'datetime': frozenset({'date', 'datetime', 'timedelta', 'timezone', 'time'}),
}
# fix round 7: a `python3 -` run puts the cwd first on sys.path, so a file written there may be loaded as code: the
# basenames python may load (lowercased), and the Path methods whose receiver is a path they write or link
PY_LOADABLE_EXTS = ('.py', '.pyc', '.pyw', '.pth', '.so', '.dylib', '.pyd')
PY_LOADABLE_PARTS = ('__init__', 'sitecustomize', 'usercustomize')
PY_WRITE_RECV_METHODS = frozenset({'write_text', 'write_bytes', 'touch', 'open', 'symlink_to', 'hardlink_to'})
PY_SHAPE_KINDS = (ast.Lambda, ast.ClassDef, ast.Global, ast.Nonlocal) + ((ast.Match,) if hasattr(ast, 'Match') else ())


def _py_import_root(a):
    """#111: the name an import alias binds (`import a.b` binds `a`)."""
    return (a.asname or a.name).split('.')[0]


def _py_binds(nodes):
    """#111: how many times each name is bound in nodes (a store or del, an arg, a def or class, an import). A store
    or del of an attribute or item (`q.x = v`, `q[0] = v`) binds its root name too: q no longer holds one value."""
    out = collections.Counter()
    for n in nodes:
        if isinstance(n, ast.Name) and not isinstance(n.ctx, ast.Load):
            out[n.id] += 1
        elif isinstance(n, (ast.Attribute, ast.Subscript)) and not isinstance(n.ctx, ast.Load):
            r = n.value
            while isinstance(r, (ast.Attribute, ast.Subscript)):
                r = r.value
            if isinstance(r, ast.Name):
                out[r.id] += 1
        elif isinstance(n, ast.arg):
            out[n.arg] += 1
        elif isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            out[n.name] += 1
        elif isinstance(n, (ast.Import, ast.ImportFrom)):
            out.update(_py_import_root(a) for a in n.names)
    return out


def _py_unsafe_shape(nodes, binds, valpos):
    """#111: True when the program holds a capability class _py_reads_env does not follow (fail closed, whole class):
    a lambda, match, named except, class, global/nonlocal, `*`/`**` in a call, a dynamic name
    (PY_UNSURE_*), an identifier starting with `_` (a private slot: `q._str = …`; the bare name `_` is allowed); an import
    outside PY_SAFE_MODULES (exact name: relative, dotted and `*` included) or bound twice; a module attribute or
    `from m import x` outside PY_SAFE_FUNCS_BY_MODULE (`pathlib.vfsopen`, `pathlib.os`, `from json import codecs`); a
    module used as a value (`m = re`, `[re][0]`). valpos: ids of the nodes that are an attribute's value."""
    module, mods = type(os), {}
    for n in nodes:
        if isinstance(n, PY_SHAPE_KINDS) or (isinstance(n, ast.ExceptHandler) and n.name) or (
                isinstance(n, ast.Name) and n.id in PY_UNSURE_NAMES) or (
                isinstance(n, ast.Attribute) and n.attr in PY_UNSURE_ATTRS):
            return True
        if isinstance(n, ast.Call) and (any(isinstance(a, ast.Starred) for a in n.args) or any(
                k.arg is None for k in n.keywords)):
            return True
        if any(isinstance(x, str) and x.startswith('_') and not (k in ('id', 'arg') and x == '_') for k, x in (
                (k, getattr(n, k, None)) for k in ('id', 'attr', 'arg', 'name', 'asname'))):
            return True  # fix round 5: the bare throwaway name `_` is no private slot
        if not isinstance(n, (ast.Import, ast.ImportFrom)):
            continue
        if any(binds[_py_import_root(a)] != 1 for a in n.names):
            return True
        try:
            if isinstance(n, ast.Import):
                for a in n.names:
                    if a.name not in PY_SAFE_MODULES:
                        return True
                    mods[a.asname or a.name] = __import__(a.name)
            else:
                if n.level or n.module not in PY_SAFE_MODULES or any(
                        a.name not in PY_SAFE_FUNCS_BY_MODULE[n.module] for a in n.names):
                    return True  # fix round 5: only the module's allowlisted names (no `*`, no module, no vfsopen)
        except Exception:
            return True

    def res(x):  # the module object an expression names, else None
        if isinstance(x, ast.Name):
            return mods.get(x.id)
        o = getattr(res(x.value), x.attr, None) if isinstance(x, ast.Attribute) else None
        return o if isinstance(o, module) else None
    for n in nodes:
        if isinstance(n, ast.Name) and n.id in mods and id(n) not in valpos:
            return True
        m = res(n.value) if isinstance(n, ast.Attribute) else None
        if m is not None and n.attr not in PY_SAFE_FUNCS_BY_MODULE.get(m.__name__, ()):
            return True  # fix round 5: a module attribute outside its allowlist (`pathlib.vfsopen`, `pathlib.os`)
    return False


def _py_reads_env(body):
    """#111: True when the python program body may read or copy a .env — treat it as a copy. Fails closed: a coding
    cookie, an unparseable body, an unsafe shape (_py_unsafe_shape) or any error while following it is True; file
    touches only through a literal path (_py_env_reaches). A .env name is data only when it (or a name it flows into)
    never reaches an argument or receiver of a call outside the safe forms: PY_SAFE_FUNCS; PY_STR_METHODS on a
    string-shaped receiver (on any receiver for a name not in PY_PATH_METHODS); PY_FLOW_METHODS (a flow into the
    receiver); PY_WRITE_METHODS onto open(CONST)/Path(CONST); a PY_SAFE_FUNCS_BY_MODULE function given no callable.
    No directory listing (PY_ENUM_NAMES) at all."""
    if any(PY_COOKIE.search(x) for x in re.split(r'\r\n|\r|\n', body)[:2]):
        return True  # the cookie may decode the bytes into another program than the one parsed here
    try:
        with warnings.catch_warnings():
            warnings.simplefilter('ignore')
            tree = ast.parse(body.encode())
    except Exception:
        return True
    try:  # fix round 2: a RecursionError (a long `a1 = a0` chain) or any other error fails closed, not open
        return _py_env_reaches(list(ast.walk(tree)))
    except Exception:
        return True


def _py_env_reaches(nodes):
    """#111: _py_reads_env on a parsed program's nodes. When a .env constant exists, every file touch (`open(...)`,
    a PY_TOUCH_METHODS call) must go through a literal path: open(X, …)/Path(X) with X a str citing no .env (through a
    name bound once), or a name bound once to one; PY_HANDLE_METHODS only on an open() handle. Anything else —
    a `/` join, a loop variable, a param, a computed path, a touch callable held in a name (`r = p.read_text`) — is
    True: a .env name used as a filter or rebuilt from pieces cannot then pick the file."""
    env = {id(n) for n in nodes if isinstance(n, ast.Constant) and isinstance(n.value, (str, bytes)) and _env_names(
        n.value.decode('latin-1') if isinstance(n.value, bytes) else n.value)}
    if not env:
        return False
    binds = _py_binds(nodes)
    valpos = {id(n.value) for n in nodes if isinstance(n, ast.Attribute)}
    if _py_unsafe_shape(nodes, binds, valpos):
        return True
    if any((isinstance(n, ast.Attribute) and n.attr in PY_ENUM_NAMES) or (isinstance(n, ast.Name) and n.id in PY_ENUM_NAMES)
           for n in nodes):
        return True  # fix round 5: no directory listing, so no non-literal path a .env filter could pick exists
    lead = set()  # fix round 7: the leading run — a docstring, then imports; any other import runs after code
    for i, s in enumerate(getattr(nodes[0], 'body', ())):
        if i == 0 and isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant) and isinstance(s.value.value, str):
            continue
        if not isinstance(s, (ast.Import, ast.ImportFrom)):
            break
        lead.add(id(s))
    if any(isinstance(n, (ast.Import, ast.ImportFrom)) and id(n) not in lead for n in nodes):
        return True  # fix round 7: code before an import may plant the module it loads (`open("json.py", "w")`)
    imported = {_py_import_root(a) for n in nodes if isinstance(n, (ast.Import, ast.ImportFrom)) for a in n.names}
    modnames = {a.asname or a.name for n in nodes if isinstance(n, ast.Import) for a in n.names}
    defs = {n.name for n in nodes if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
    params = {n.arg for n in nodes if isinstance(n, ast.arg)}
    bound = imported | defs | params | {n.id for n in nodes if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store)} \
        | {n.attr for n in nodes if isinstance(n, ast.Attribute) and isinstance(n.ctx, ast.Store)}
    simple = {}  # name -> the values of its simple bindings: `x = v`, `x: T = v`, `(x := v)`, `with v as x`
    for n in nodes:
        for t, v in ([(n.targets[0], n.value)] if isinstance(n, ast.Assign) and len(n.targets) == 1 else
                     [(n.target, n.value)] if isinstance(n, (ast.AnnAssign, ast.NamedExpr)) and n.value else
                     [(n.optional_vars, n.context_expr)] if isinstance(n, ast.withitem) else []):
            if isinstance(t, ast.Name):
                simple.setdefault(t.id, []).append(v)
    funcpos = {id(n.func) for n in nodes if isinstance(n, ast.Call)}
    tainted, ret_callable = set(), set()
    # fix round 2: a param may hold any callable the caller passes (`h(open)`)
    callables = imported | defs | params | {k for k in dir(builtins) if callable(getattr(builtins, k))}

    def holds(n):
        return any(id(c) in env or (isinstance(c, ast.Name) and c.id in tainted)
                   or (isinstance(c, ast.Attribute) and c.attr in tainted) for c in ast.walk(n))

    def refs(n):  # may n carry a callable: a callable name not called, a bare attribute, a call that returns one
        return any((isinstance(c, ast.Name) and c.id in callables and id(c) not in funcpos) or (
            isinstance(c, ast.Attribute) and id(c) not in funcpos and id(c) not in valpos) or (
            isinstance(c, ast.Call) and isinstance(c.func, ast.Name) and c.func.id in ret_callable) for c in ast.walk(n))

    def once(n):  # the one value a name is ever bound to, else n
        ok = isinstance(n, ast.Name) and binds[n.id] == 1 and len(simple.get(n.id, ())) == 1
        return simple[n.id][0] if ok else n

    def strish(n, seen=frozenset()):  # string-shaped: a str, an f-string, a str method of one, a read result, a name
        if isinstance(n, (ast.Constant, ast.JoinedStr)):  # of those
            return isinstance(n, ast.JoinedStr) or isinstance(n.value, str)
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr not in bound:
            return n.func.attr in ('read', 'read_text') or (n.func.attr in PY_STR_METHODS and strish(n.func.value, seen))
        if not isinstance(n, ast.Name):
            return False
        if n.id in seen:  # fix round 2: `s = s.replace(…)` settles on s's other bindings …
            return True
        vs = simple.get(n.id, ())
        return 0 < binds[n.id] == len(vs) and all(strish(v, seen | {n.id}) for v in vs) and any(
            not any(isinstance(c, ast.Name) and c.id == n.id for c in ast.walk(v)) for v in vs)  # … ≥1 on its own

    def lit(x):  # a str/int constant citing no .env
        return isinstance(x, ast.Constant) and isinstance(x.value, (str, int)) and id(x) not in env

    def litpath(n):  # 'open'/'path' for open(X, …)/Path(X), X a str citing no .env, or a name bound once to one
        n = once(n)
        a = once(n.args[0]) if isinstance(n, ast.Call) and n.args else None
        if not (isinstance(a, ast.Constant) and isinstance(a.value, str) and id(a) not in env):
            return None
        f = n.func
        if isinstance(f, ast.Name) and f.id == 'open' and 'open' not in bound:
            # fix round 5: every other argument a constant, no opener (it picks the file descriptor)
            ok = all(lit(x) for x in n.args[1:]) and all(k.arg != 'opener' and lit(k.value) for k in n.keywords)
            return 'open' if ok else None
        if len(n.args) != 1 or n.keywords:
            return None  # fix round 5: Path(X) takes X alone (`Path(".", p)` joins a second path)
        return 'path' if (isinstance(f, ast.Name) and f.id == 'Path' and any(
            isinstance(i, ast.ImportFrom) and i.module == 'pathlib' and any(
                a.name == 'Path' and not a.asname for a in i.names) for i in nodes)) or (
            isinstance(f, ast.Attribute) and f.attr == 'Path' and isinstance(f.value, ast.Name)
            and f.value.id == 'pathlib' and 'pathlib' in modnames) else None

    def roots(t):
        if isinstance(t, ast.Name):
            return {t.id}
        if isinstance(t, (ast.Tuple, ast.List)):
            rs = [roots(e) for e in t.elts]
            return None if any(r is None for r in rs) else set().union(*rs)
        if isinstance(t, ast.Starred):
            return roots(t.value)
        if isinstance(t, ast.Attribute):
            r = roots(t.value)
            return None if r is None else r | {t.attr}
        return roots(t.value) if isinstance(t, ast.Subscript) else None

    def plain(f):  # a method call on a receiver that is not a module and a method name the body never binds
        return isinstance(f, ast.Attribute) and f.attr not in bound and not (
            isinstance(f.value, ast.Name) and f.value.id in imported)

    def made(v):  # fix round 6: a call result whose callee is a safe function or a safe module's allowlisted name
        f = v.func
        return (isinstance(f, ast.Name) and f.id not in bound and f.id in PY_SAFE_FUNCS) or (
            isinstance(f, ast.Name) and f.id in imported - modnames) or (
            isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and f.value.id in modnames)

    def touch_ok(c):  # False when c touches a file through a path that is not a literal
        f = c.func
        if not isinstance(f, (ast.Name, ast.Attribute)):
            return False  # fix round 6: a computed callee (`type(h)(n)`, `fs[0](n)`) may be any class or function
        if isinstance(f, ast.Name):
            if any(isinstance(v, ast.Call) and not made(v) for v in simple.get(f.id, ())):
                return False  # fix round 6: a name bound to a call result (`F = type(h); F(n)`) may hold any callable
            return f.id != 'open' or litpath(c) == 'open'
        if not isinstance(f, ast.Attribute) or f.attr not in PY_TOUCH_METHODS:
            return True
        if f.attr == 'copy' and not c.args and not c.keywords:
            return True  # fix round 3: a zero-arg .copy() is a container copy (Path.copy needs a target)
        if plain(f) and f.attr in PY_STR_METHODS and strish(f.value):
            return True  # a str method (`s.replace`), not a file touch
        if f.attr in PY_PATH_ARG_METHODS and not all(
                litpath(a) == 'path' or (isinstance(once(a), ast.Constant) and isinstance(once(a).value, str)
                                          and id(once(a)) not in env) for a in c.args + [k.value for k in c.keywords]):
            return False  # its other path (`Path("x").symlink_to(p)`) must be a literal too
        return litpath(f.value) == ('open' if f.attr in PY_HANDLE_METHODS else 'path')

    def loadable(x):  # fix round 7: a str (through a name bound once) or open(X)/Path(X) whose basename python loads
        x = once(x)
        if isinstance(x, ast.Call) and litpath(x):
            x = once(x.args[0])
        if not (isinstance(x, ast.Constant) and isinstance(x.value, str)):
            return False
        b = os.path.basename(os.path.normpath(x.value)).lower()
        return b.endswith(PY_LOADABLE_EXTS) or any(k in b for k in PY_LOADABLE_PARTS)

    def writes(c):  # open(X, mode): a mode that writes (w, a, x, +), or one not a str constant
        m = c.args[1] if len(c.args) > 1 else next((k.value for k in c.keywords if k.arg == 'mode'), None)
        m = m if m is None else once(m)
        return m is not None and (not (isinstance(m, ast.Constant) and isinstance(m.value, str)) or bool(
            set(m.value) & set('wax+')))
    for c in nodes:  # fix round 7: no write, link or move onto a path python may load
        f = c.func if isinstance(c, ast.Call) else None
        if isinstance(f, ast.Name) and f.id == 'open' and c.args and writes(c) and loadable(c.args[0]):
            return True
        if isinstance(f, ast.Attribute) and f.attr in PY_WRITE_RECV_METHODS | PY_PATH_ARG_METHODS and not (
                plain(f) and f.attr in PY_STR_METHODS and strish(f.value)) and (loadable(f.value) or (
                f.attr in PY_PATH_ARG_METHODS and any(loadable(a) for a in c.args + [k.value for k in c.keywords]))):
            return True
    # fix round 3: a file-touch callable held in a name, a container, a default or a return (`r = p.read_text`,
    # `o = open`) is a touch: its later call is out of touch_ok's sight. A bare `.copy` too (it may be Path.copy).
    if any(id(n) not in funcpos and (
            (isinstance(n, ast.Name) and n.id == 'open' and isinstance(n.ctx, ast.Load)) or (
            isinstance(n, ast.Attribute) and n.attr in PY_TOUCH_METHODS | PY_PATH_ARG_METHODS)) for n in nodes):
        return True
    parent = {id(c): p for p in nodes for c in ast.iter_child_nodes(p)}
    flows = []  # (source nodes, target root names or None, True for a return into a function's name)
    for n in nodes:
        if isinstance(n, ast.Assign):
            flows += [([n.value], roots(t), False) for t in n.targets]
        elif isinstance(n, (ast.AugAssign, ast.AnnAssign, ast.NamedExpr)) and n.value is not None:
            flows.append(([n.value], roots(n.target), False))
        elif isinstance(n, (ast.For, ast.AsyncFor, ast.comprehension)):
            flows.append(([n.iter], roots(n.target), False))
        elif isinstance(n, ast.withitem) and n.optional_vars is not None:
            flows.append(([n.context_expr], roots(n.optional_vars), False))
        elif isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
            a = n.args
            names = {x.arg for x in a.args + a.posonlyargs + a.kwonlyargs + [a.vararg, a.kwarg] if x is not None}
            flows.append((a.defaults + [d for d in a.kw_defaults if d is not None], names, False))
        elif isinstance(n, (ast.Return, ast.Yield, ast.YieldFrom)) and n.value is not None:
            p = parent.get(id(n))
            while p is not None and not isinstance(p, (ast.FunctionDef, ast.AsyncFunctionDef)):
                p = parent.get(id(p))
            if p is not None:
                flows.append(([n.value], {p.name}, True))
        elif isinstance(n, ast.Call) and plain(n.func) and n.func.attr in PY_FLOW_METHODS:
            flows.append((n.args + [k.value for k in n.keywords], roots(n.func.value), False))
    grew = True
    while grew:
        grew = False
        for srcs, targets, ret in flows:
            for found, into in ((holds, tainted), (refs, ret_callable if ret else callables)):
                if any(found(s) for s in srcs):
                    if targets is None:
                        return True
                    if not targets <= into:
                        into |= targets
                        grew = True
    for c in nodes:
        if not isinstance(c, ast.Call):
            continue
        if not touch_ok(c):
            return True
        f, args = c.func, c.args + [k.value for k in c.keywords]
        if isinstance(f, ast.Name) and f.id in PY_SAFE_FUNCS and f.id not in bound:
            continue
        if plain(f):
            if f.attr in PY_STR_METHODS and (f.attr not in PY_PATH_METHODS or strish(f.value)):
                continue
            if f.attr in PY_FLOW_METHODS:
                continue  # followed as a flow into the receiver
            if f.attr in PY_WRITE_METHODS:
                if holds(f.value):
                    return True
                continue  # touch_ok: the receiver is a literal path, the arguments are the text written
        elif ((isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and f.value.id in modnames) or (
                isinstance(f, ast.Name) and f.id in imported - modnames)) and not any(refs(a) for a in args):
            continue  # an allowlisted function of a safe module (_py_unsafe_shape) given no callable
        if any(holds(a) for a in args) or (not isinstance(f, ast.Name) and holds(f)):
            return True
    return False


def _defines_or_evals(text, docs):
    """True when text outside its heredoc bodies holds `()`, `function`, `eval` or `alias` as a word (lexed whole;
    a regex over the raw text when it does not lex): a heredoc's command may then be a function, an alias or an eval'd
    string, so _heredoc_copy treats every body as fed to an interpreter."""
    out = _cut(text, [(b0, b1) for _, _, b0, b1 in docs])
    try:
        flat = _flat_tokens(out)
    except ValueError:
        return bool(re.search(r'\(\s*\)|(?<![\w.-])(?:function|eval|alias)(?![\w.-])', out))
    return any(os.path.basename(t) in UNSURE_DEFS for t in flat) or any(
        a == '(' and b == ')' for a, b in zip(flat, flat[1:]))


def _heredoc_elem(text, op):
    """(elem, line) for the `<<` at text[op]: line is its logical line (backslash-newlines followed), elem the tokens of
    its list element (bounded by `;`, `&&`, `||`, `&`). The heredoc may be fed to an interpreter or ssh when any word
    of elem is INTERP (_interp_words(elem)). elem is None — fail closed to any INTERP word of the whole line — when the
    line does not lex, or the element is empty, touches a paren, or holds a brace, a compound keyword
    (`{ bash; } <<EOF`), a `$` or a backtick (`$P - <<EOF`)."""
    s = text.rfind('\n', 0, op) + 1
    while s >= 2 and text[s - 2:s] == '\\\n':
        s = text.rfind('\n', 0, s - 2) + 1
    e = text.find('\n', op)
    e = len(text) if e < 0 else e
    while 0 < e < len(text) and text[e - 1] == '\\':
        nxt = text.find('\n', e + 1)
        e = len(text) if nxt < 0 else nxt
    line = text[s:e].replace('\\\n', '  ')
    try:
        pre, post = _flat_tokens(line[:op - s]), _flat_tokens(line[op - s:])
    except ValueError:
        pre = None
    if pre is not None:
        lo = max((k for k, t in enumerate(pre) if _is_sep(t) and not _is_pipe(t)), default=-1)
        hi = next((k for k, t in enumerate(post) if _is_sep(t) and not _is_pipe(t)), len(post))
        elem, edge = pre[lo + 1:] + post[:hi], pre[lo:lo + 1] if lo >= 0 else []
        if elem and not any('(' in t or ')' in t for t in elem + edge + post[hi:hi + 1]) and not any(
                t in ELEM_UNSURE or t in ('{', '}') or '$' in t or '`' in t for t in elem):
            return elem, line
    return None, line


PY_FLAG = re.compile(r'^-[IBEsSuqOP]+$')


def _py_stdin_program(elem):
    """#111: True only when elem is exactly `python[\\d.]* [-FLAGS…] [-] << DELIM` — python reads the heredoc as its
    program. Anything else (`-c`, `-m`, a script, args, a wrapper, an assignment, a pipe, a redirect) may run the body
    as something other than the program, or feed its output on."""
    if len(elem) < 3 or not re.match('^' + PY_NAME + '$', os.path.basename(elem[0])):
        return False
    k = 1
    while k < len(elem) and PY_FLAG.match(elem[k]):
        k += 1
    if k < len(elem) and elem[k] == '-':
        k += 1
    return elem[k:k + 1] == ['<<'] and len(elem) == k + 2 and re.match(r'^\w+$', elem[k + 1]) is not None


SPAN_UNSURE = re.compile(r"""["'`]|<<|\$\{""")  # in a span: a `)`/`}`/backtick that may not close it


def _subst_spans(body):
    """Each outermost `$(…)`, `${…}` or backtick span of an unquoted heredoc body, balanced to its close (backslash pairs
    skipped). Fails closed — the span runs to the body end — when it is unbalanced, or its inside holds what may hide or
    fake its close (SPAN_UNSURE: a quote, `$'`, a backtick, `<<`, a nested `${`; inside `${…}` or backticks also a `$(`;
    inside `$(…)` also `case` or `#`). Only a span with none of these is bounded at its close: `$(git branch)`."""
    out, i, n = [], 0, len(body)
    while i < n:
        c = body[i]
        if c == '\\':
            i += 2
        elif c == '`' or (c == '$' and body[i + 1:i + 2] in ('(', '{')):
            o = c if c == '`' else body[i + 1]
            j = i + 1
            if o == '`':
                while j < n and body[j] != '`':
                    j += 2 if body[j] == '\\' else 1
            else:
                cl, depth = ')' if o == '(' else '}', 0
                while j < n:
                    if body[j] == '\\':
                        j += 2
                        continue
                    depth += (body[j] == o) - (body[j] == cl)
                    if depth == 0:
                        break
                    j += 1
            inner = body[i + (1 if o == '`' else 2):j]
            if j >= n or SPAN_UNSURE.search(inner) or (o != '(' and '$(' in inner) or (
                    o == '(' and re.search(r'\bcase\b|#', inner)):
                j = n
            out.append(body[i:j + 1])
            i = j + 1
        else:
            i += 1
    return out


def _heredoc_copy(text):
    """#58's heredoc checks on text (comments cut first): (a) an unquoted body (backslash-newlines removed, as bash does)
    with a .env name inside a `$(…)`, `${…}` or backtick span (_subst_spans), and (b) a body naming a .env fed to an
    interpreter or ssh (_heredoc_elem, _interp_words; every such body when the command defines or evals,
    _defines_or_evals),
    except (#111) a body a bare `python3 [-FLAGS] -` reads as its program (_py_stdin_program), quoted or with no
    `$`/backtick/backslash, whose .env names _py_reads_env proves are data. False when the scan is unsure."""
    scan = _shell_scan(text)
    if scan is None:
        return False
    if scan[0]:
        text = _cut(text, scan[0])
    unsure = None
    for op, quoted, b0, b1 in scan[1]:
        body = text[b0:b1]
        if not quoted and any(_env_names(sp) for sp in _subst_spans(body.replace('\\\n', ''))):
            return True  # (a) a substitution reads a .env
        if not _env_names(body):
            continue
        if unsure is None:
            unsure = _defines_or_evals(text, scan[1])
        if unsure:
            return True  # (b) the command defines or evals: any body may be run
        elem, line = _heredoc_elem(text, op)
        if not _interp_words(elem if elem is not None else [line]):
            continue
        if elem is not None and _py_stdin_program(elem) and (quoted or not re.search(r'[$`\\]', body)) \
                and not _py_reads_env(body):
            continue  # #111: python's own program cites .env only as data
        return True  # (b) an interpreter or ssh runs a body naming a .env
    return False


def _base_env_copy(cmd):
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        toks = list(lex)
    except ValueError:
        toks = cmd.split()
    segs, cur = [], []
    for t in toks:
        if t and set(t) <= set(';&|()'):
            segs.append(cur)
            cur = []
        else:
            cur.append(t)
    segs.append(cur)
    for seg in segs:
        if seg and os.path.basename(seg[0]) == 'cat' and ('>' in seg or '>>' in seg):  # cat other/.env > .env
            cut = seg.index('>') if '>' in seg else seg.index('>>')
            if any(ENV_RE.match(os.path.basename(a)) and not os.path.basename(a).endswith(ENV_OK)
                   for a in seg[1:cut]):
                return True
        for i, t in enumerate(seg):
            if os.path.basename(t) in ('cp', 'ln', 'rsync', 'install'):
                args = [a for a in seg[i + 1:] if not a.startswith('-')]
                for a in args[:-1]:  # sources only; the last arg is the destination
                    b = os.path.basename(a)
                    if ENV_RE.match(b) and not b.endswith(ENV_OK):
                        return True
                break
    return False


STDIN_LIST = ('--files-from', '--include-from')  # rsync options whose `-` value reads the file list from stdin


def _extra_env_copy(cmd):
    """The env-copy checks #48 added on top of BASE's rule. They only ever add denies, so they may rewrite freely: run
    on _reduce(cmd) with continuations joined, comments dropped and every line its own segment — cat with any write op
    (WRITE_OPS, `1>`, `>& file`), cp/ln/rsync/install on any line, and `xargs … cp` or `rsync --files-from=-` /
    `--include-from=-` whose sources come from stdin (a pipe, a heredoc) naming a .env file anywhere in the command, except in the test element of a command that is wholly the shape XARGS_SHAPE, tracked files copied to one destination and no other .env name (_xargs_excused). #58 adds two heredoc
    checks (_heredoc_copy, run on the command as typed — a quoted body may end in a `\\` line — and joined): (a) an
    unquoted body with a .env name inside a `$(…)`, `${…}` or backtick span (`$(cat .env)` written to a file), and (b)
    a body naming a .env file fed to an interpreter, a shell or ssh (_heredoc_elem: INTERP as any word of the `<<`'s
    list element: `python3 - <<EOF`, `sudo bash`, `op run -- python3`, `ssh h`; any body when the command defines or
    evals, _defines_or_evals); (b) cannot tell a read from a copy in another language, so it fails closed.
    Except (#111): a bare `python3 [-FLAGS] -` program body, quoted or with no `$`/backtick/backslash, that _py_reads_env proves cites .env only as data.
    (c) a `cat` naming a .env before any write op, piped (`|`, `|&`) into a stage that is `tee FILE` (_tee_file) or
    carries a write op, walking the pipeline while each separator is a pipe; R2 has already dropped `2>/dev/null`."""
    red = _reduce(cmd)
    cmd = joined = re.sub(r'\\\n', ' ', red)
    scan = _shell_scan(cmd)
    if scan and scan[0]:
        cmd = _cut(cmd, scan[0])
    raw = cmd
    cmd = cmd.replace('\n', ' ; ')
    try:
        toks = _shlex_tokens(cmd)  # comments were cut above; a `#` in a kept body must not eat the rest
    except ValueError:
        toks = cmd.split()
    segs, cur = [], []  # (tokens, the separator token that ended them; '' at the end)
    for t in toks:
        if _is_sep(t):
            segs.append((cur, t))
            cur = []
        else:
            cur.append(t)
    segs.append((cur, ''))
    for k, (seg, sep) in enumerate(segs):
        ops = _write_ops(seg)
        if seg and os.path.basename(seg[0]) == 'cat' and any(_env_word(a) for a in seg[1:ops[0] if ops else None]):
            if ops:  # cat other/.env > .env
                return True
            j, nsep = k, sep
            while _is_pipe(nsep) and j + 1 < len(segs):  # cat .env | tee x, cat .env | grep y > x
                j += 1
                nxt, nsep = segs[j]
                if _tee_file(nxt) or _write_ops(nxt):
                    return True
        for i, t in enumerate(seg):
            if os.path.basename(t) in COPY_CMDS:
                args = [a for a in seg[i + 1:] if not a.startswith('-')]
                if any(_env_word(a) for a in args[:-1]):  # sources only; the last arg is the destination
                    return True
                stdin_list = os.path.basename(t) == 'rsync' and any(
                    a in (o + '=-' for o in STDIN_LIST) or (a in STDIN_LIST and seg[j + 1:j + 2] == ['-'])
                    for j, a in enumerate(seg[i + 1:], i + 1))
                if stdin_list or 'xargs' in (os.path.basename(x) for x in seg[:i]):  # sources come from stdin
                    named = _env_names_max(_xargs_excused(red, raw))
                    redir = next((r for r, a in enumerate(args) if re.match(r'^&?[<>]', a)), len(args))
                    dest = args and _env_word(args[-1]) and redir and _env_word(args[redir - 1])
                    if named > (1 if dest else 0):  # a .env destination is the last arg AND the last before any
                        # redirect, so `xargs cp {} . < <(echo .env)` keeps its .env counted as a source
                        return True
                break
    # (a)/(b) last, on the command as typed (a quoted body may end in a `\` line) and joined (bash joins unquoted
    # bodies): they cost more, so a command the checks above deny never waits on them (the hook's timeout fails open)
    return _heredoc_copy(red) or (joined != red and _heredoc_copy(joined))


def _write_ops(seg):
    """Indexes of the write ops in a segment: WRITE_OPS, `1>` and `>& file` (not `>&2` / `>&-`)."""
    return [i for i, t in enumerate(seg) if t in WRITE_OPS
            or (t == '>&' and i + 1 < len(seg) and not (seg[i + 1].isdigit() or seg[i + 1] == '-'))]


def _is_pipe(sep):
    """A separator token that pipes stdout on: `|` or `|&`, never `||`."""
    return '|' in sep and '||' not in sep


TEE_PREFIX = {'sudo', 'doas', 'command', 'env', 'nice', 'nohup', 'stdbuf', 'time'}
TEE_SINKS = {'/dev/null', '/dev/stdout', '/dev/stderr'}


def _tee_file(seg):
    """True when a segment is `tee` (after wrapper words, their options and NAME=value) with a real file argument."""
    i = 0
    while i < len(seg) and (os.path.basename(seg[i]) in TEE_PREFIX or seg[i].startswith('-')
                            or re.match(r'^[A-Za-z_]\w*=', seg[i])):
        i += 1
    return (i < len(seg) and os.path.basename(seg[i]) == 'tee'
            and any(not a.startswith('-') and a not in TEE_SINKS for a in seg[i + 1:]))


def _env_names_max(text):
    """The most of the whitespace-word count and _env_names, so neither one can lose a .env name."""
    return max(sum(_env_word(w) for w in text.split()), _env_names(text))


_TEST_ARG = r'(?:![ \t]+)?-[efrs][ \t]+(?P<%s>[\w./-]+)'
XARGS_SHAPE = re.compile(
    r'[ \t]*(?P<test>test[ \t]+' + _TEST_ARG % 'n1' + r'|\[[ \t]+' + _TEST_ARG % 'n2' + r'[ \t]+\]|\[\[[ \t]+' + _TEST_ARG % 'n3' + r'[ \t]+\]\])'
    r'[ \t]*(?:;|&&|\|\|)[ \t]*git[ \t]+ls-files(?:[ \t]+(?!\S*\.\.)[\w.][\w./-]*)*'
    r'[ \t]*\|[ \t]*xargs[ \t]+-I\{\}[ \t]+cp[ \t]+\{\}[ \t]+[\w.][\w./-]*[ \t]*\Z')


def _xargs_excused(red, raw):
    """The text for the xargs stdin count: red (_reduce's output, before the continuation join and comment cut) with its
    test element blanked when the whole of red is the one XARGS_SHAPE; any other command returns raw unchanged and keeps
    the whole-command count. The match runs before the join and cut because a shell ends a comment at the newline, so a
    joined `#\\` would hide the next line. The shape, on one line: exactly one test
    element `test [!] -e|-f|-r|-s NAME`, `[ … ]` or `[[ … ]]` (NAME one `[\\w./-]+` word that is a .env name), then
    `;`/`&&`/`||`, then `git ls-files` with path words, then one `|`, then exactly `xargs -I{} cp {} DEST`. Why each
    part holds: a test builtin writes nothing to stdout, and nothing can run before it, so nothing can trace or redefine
    it; `git ls-files` with no flag lists only tracked files; a path word cannot leave the tree or spell a flag (it starts
    with a word character or `.` and holds no `..`); `cp` gets only `{}` plus one destination that cannot spell a flag,
    and `xargs cp -t` is left out because without `-I`, xargs splits a tracked name on blanks; a .env name left anywhere
    outside the test keeps the old count. `rsync` is not in the shape, so its stdin form keeps the count."""
    m = XARGS_SHAPE.match(red)
    if not m or not _env_word(m['n1'] or m['n2'] or m['n3']):
        return raw
    blanked = red[:m.start('test')] + ' ' * (m.end('test') - m.start('test')) + red[m.end('test'):]
    return raw if _env_names_max(blanked) > 0 else blanked


def _is_sep(t):
    return bool(t) and set(t) <= set(';&|()')


def _shlex_tokens(text):
    """shlex words and operators of text, comments off (a `#` is a word): raises ValueError on an unclosed quote."""
    lex = shlex.shlex(text, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ''
    return list(lex)


def _flat_tokens(text):
    """shlex tokens of one line (as _extra_env_copy splits them), each separator token split at its parens."""
    flat = []
    for t in _shlex_tokens(text):
        flat += [p for p in re.split(r'([()])', t) if p] if _is_sep(t) else [t]
    return flat


def env_copy(cmd):
    """BASE's rule on the minimally reduced command, or the checks #48 added: only R1-R3 (_reduce) can relax BASE."""
    return _base_env_copy(_reduce(cmd)) or _extra_env_copy(cmd)


def last_user_text(path):
    """Latest real user message of the transcript, by owner_message.user_text (the rule shared with
    pr-base-guard), cut by owner_message.owner_text: a launch prompt there yields ''. '' when unreadable
    or when owner_message is missing."""
    if owner_message is None:
        return ''
    last = ''
    try:
        lines = open(path, errors='replace')
    except Exception:
        return ''
    for line in lines:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        t = owner_message.user_text(e)
        if t:
            last = t
    return owner_message.owner_text(last)


def worktree_dir(cmd, cwd, root):
    m = re.match(re.escape(root) + r'/([^/]+)/([^/]+)', cwd or '')
    if m:
        return os.path.join(root, m.group(1), m.group(2))
    m = re.search(r'(?:' + re.escape(root) + r'|~/orca/workspaces)/([^/\s\'"]+)/([^/\s\'"]+)', cmd)
    if m:
        return os.path.join(root, m.group(1), m.group(2))
    return None


def file_urls(wt):
    urls = []
    for name in ENV_FILES:
        try:
            lines = open(os.path.join(wt, name)).read().splitlines()
        except Exception:
            continue
        for ln in lines:
            ln = ln.strip()
            if ln.startswith('#') or '=' not in ln:
                continue
            k, v = ln.split('=', 1)
            k = k.strip()
            if k.startswith('export '):
                k = k[7:].strip()
            if k in URL_KEYS:
                urls.append(v.strip().strip('\'"'))
    return urls


def etime_secs(s):
    """ps etime (MM:SS, HH:MM:SS, D-HH:MM:SS) -> seconds; None when unparseable."""
    try:
        days, _, rest = s.rpartition('-')
        parts = [int(x) for x in rest.split(':')]
        secs = 0
        for x in parts:
            secs = secs * 60 + x
        return float(int(days or 0) * 86400 + secs)
    except ValueError:
        return None


def cpu_secs(s):
    """ps time ([D-][[HH:]MM:]SS[.ff]) -> seconds; None when unparseable."""
    try:
        days, _, rest = s.rpartition('-')
        secs = 0.0
        for x in rest.split(':'):
            secs = secs * 60 + float(x)
        return int(days or 0) * 86400 + secs
    except ValueError:
        return None


_CPU_SAMPLES = 0
_PS_SAMPLES = 0
_CPU_FIRST = {}  # runner pid -> (monotonic time, {tree pid: cpu s}) from the first sample where its whole tree had CPU


def _fixture_block(path, n):
    """Block `n` of a fixture file split by `---` lines (the last block repeats past the end)."""
    blocks = open(path).read().split('---\n')
    return blocks[min(n, len(blocks) - 1)]


def cpu_sample():
    """{pid: cpu_s}. WORKTREE_GUARD_CPU file = blocks of `pid cputime` lines split by `---` (call n -> block n, the
    last repeats); WORKTREE_GUARD_PS set without it -> {} (idle detection off); else `ps -axo pid=,time=`."""
    global _CPU_SAMPLES
    try:
        f = os.environ.get('WORKTREE_GUARD_CPU')
        if f:
            text = _fixture_block(f, _CPU_SAMPLES)
            _CPU_SAMPLES += 1
        elif os.environ.get('WORKTREE_GUARD_PS'):
            return {}
        else:
            text = subprocess.run(['ps', '-axo', 'pid=,time='], capture_output=True, text=True, timeout=5).stdout
        res = {}
        for line in text.splitlines():
            parts = line.split()
            if len(parts) == 2 and cpu_secs(parts[1]) is not None:
                res[parts[0]] = cpu_secs(parts[1])
        return res
    except Exception:
        return {}


def proc_cwds(pids):
    """{pid: cwd}: WORKTREE_GUARD_CWD file (`pid path` lines), else {} under WORKTREE_GUARD_PS, else /proc, else lsof."""
    try:
        f = os.environ.get('WORKTREE_GUARD_CWD')
        if f:
            res = {}
            for line in open(f).read().splitlines():
                pid, _, path = line.strip().partition(' ')
                if pid and path:
                    res[pid] = path.strip()
            return res
        if os.environ.get('WORKTREE_GUARD_PS'):
            return {}
        if os.path.isdir('/proc'):
            return {pid: os.readlink(f'/proc/{pid}/cwd') for pid in pids if os.path.islink(f'/proc/{pid}/cwd')}
        res, cur = {}, None
        text = subprocess.run(['lsof', '-a', '-d', 'cwd', '-Fpn', '-p', ','.join(pids)],
                              capture_output=True, text=True, timeout=5).stdout
        for line in text.splitlines():
            if line.startswith('p'):
                cur = line[1:]
            elif line.startswith('n') and cur:
                res[cur] = line[1:]
        return res
    except Exception:
        return {}


def fmt_age(age):
    if age is None:
        return '?'
    return f"{int(age)} s" if age < 60 else f"{int(age // 60)} min"


def runner_script(command):
    """(script, args after it) a node/bun process runs when it is jest's or vitest's entry point, else None. pm wrappers
    (pnpm, npm exec, npx, yarn) keep their own argv0 or run their own .cjs script, and shells never start
    with node, so none of them match."""
    argv = command.split()
    if not argv or os.path.basename(argv[0]) not in NODE_BINS:
        return None
    skip = False
    for a in argv[1:]:
        if skip:
            skip = False
            continue
        if a.startswith('-'):
            skip = a in NODE_VALUE_FLAGS
            continue
        return (a, argv[argv.index(a, 1) + 1:]) if RUNNER_SCRIPT.search(a) else None
    return None


def is_watcher(args, script=''):
    """A watcher/UI process by whole argument after the runner script — never by substring, so
    `--watchAll=false`, `--watch false` or a path containing `grep` is still a run."""
    for i, a in enumerate(args):
        if a in ('--watch', '--watchAll'):
            if i + 1 < len(args) and args[i + 1] == 'false':
                continue
            return True
        if a in ('--api', '--ui') or a.startswith('--api=') or (a == '-w' and 'vitest' in os.path.basename(script)):
            return True
        for flag in ('--watch=', '--watchAll='):
            if a.startswith(flag) and a[len(flag):] != 'false':
                return True
    first = next((a for a in args if not a.startswith('-')), None)
    return first in ('watch', 'dev')


def count_runners():
    """The runners this hook counts: `_scan_runners()[0]`."""
    return _scan_runners()[0]


def _scan_runners():
    """(kept, top): `top` = [(pid, age_s)] of the live logical test runs: one per jest/vitest main node process (runner_script), minus
    watchers (is_watcher), zombie/stopped (STAT Z/T) and stale (etime > RUMO_STALE_TEST_MIN) ones;
    a runner with another counted runner among its ancestors (ppid chain) is part of that run. Idle exclusion: a runner
    whose tree (itself plus every ps-listed descendant) gained under RUMO_IDLE_CPU_PCT% (default 1) CPU, summed per pid,
    over at least RUMO_IDLE_MIN_S (default 30) s since this hook first sampled it does not count; a tree member missing
    from the CPU sample makes the runner count; `kept` is `top` after that idle filter."""
    global _PS_SAMPLES
    p = os.environ.get('WORKTREE_GUARD_PS')
    if p:  # blocks split by `---` lines: call n -> block n, the last repeats (one block = the same list every call)
        text = _fixture_block(p, _PS_SAMPLES)
        _PS_SAMPLES += 1
    else:
        text = subprocess.run(['ps', '-axo', 'pid=,ppid=,stat=,etime=,command='], capture_output=True, text=True, timeout=5).stdout
    stale = float(os.environ.get('RUMO_STALE_TEST_MIN') or 20)
    parent, runners = {}, []
    for line in text.splitlines():
        f = line.split(None, 4)
        if len(f) < 5:
            continue
        pid, ppid, stat, et, command = f
        parent[pid] = ppid
        if 'Z' in stat or 'T' in stat:
            continue
        age = etime_secs(et)
        if age is not None and age / 60 > stale:
            continue
        rs = runner_script(command)
        if rs and not is_watcher(rs[1], rs[0]):
            runners.append((pid, age))
    live = {pid for pid, _ in runners}

    def nested(pid):
        return any(a in live for a in _ancestors(pid, parent))

    top = [r for r in runners if not nested(r[0])]
    sample = cpu_sample()
    if not sample:
        return top, top
    min_s = float(os.environ.get('RUMO_IDLE_MIN_S') or 30)
    pct = float(os.environ.get('RUMO_IDLE_CPU_PCT') or 1)
    now, kept = time.monotonic(), []
    for pid, age in top:
        tree = [q for q in parent if q == pid or pid in _ancestors(q, parent)]  # from the ps listing, not the sample
        if any(q not in sample for q in tree):  # CPU unknown for the runner or a tree member: counts
            kept.append((pid, age))
            continue
        if pid not in _CPU_FIRST:
            _CPU_FIRST[pid] = (now, {q: sample[q] for q in tree})
            kept.append((pid, age))
            continue
        t0, first = _CPU_FIRST[pid]
        activity = 0.0
        for q in tree:  # per pid: a worker first seen now counts its whole CPU; one that exited never subtracts
            if q not in first:
                first[q] = 0.0
            activity += max(0.0, sample[q] - first[q])
        dt = now - t0
        if dt > 0 and dt >= min_s and activity < dt * pct / 100:
            continue
        kept.append((pid, age))
    return kept, top


def _ancestors(pid, parent):
    """Yield each ancestor of `pid` along `parent` (pid -> ppid), nearest first; stops at a falsy or repeated pid."""
    seen, cur = set(), parent.get(pid)
    while cur and cur not in seen:
        yield cur
        seen.add(cur)
        cur = parent.get(cur)


def _admit_reserved(limit, home, reserve):
    """One admission attempt under the slots lock: (runners, pending reservations, admitted)."""
    d = os.path.join(home, '.claude', 'state')
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, 'worktree-guard-slots.json')
    with open(path + '.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        now = time.time()
        try:
            res = json.load(open(path))
        except Exception:  # missing or corrupt file = no reservations
            res = []
        if not isinstance(res, list):
            res = []
        pend = sorted((x for x in res if isinstance(x, dict) and isinstance(x.get('t'), (int, float))
                       and not isinstance(x['t'], bool) and isinstance(x.get('seen'), list)
                       and 0 <= now - x['t'] <= reserve), key=lambda x: x['t'])
        runners, top = _scan_runners()  # a new reservation records `top` (the idle filter is per hook process);
        # only a counted runner (`runners`) consumes one, so a runner this hook dropped as idle frees no slot
        used = set()
        left = []
        for r in pend:  # oldest first: a reservation is consumed by the first unclaimed runner it had not seen
            seen = {str(x) for x in r['seen']}
            hit = next((pid for pid, _ in runners if pid not in seen and pid not in used), None)
            if hit is None:
                left.append(r)
            else:
                used.add(hit)
        pend = left
        admitted = len(runners) + len(pend) < limit
        out_list = pend + [{'t': now, 'seen': [pid for pid, _ in top]}] if admitted else pend
        with open(path, 'w') as f:
            json.dump(out_list, f)
        return runners, len(pend), admitted


def try_admit(limit, home):
    reserve = float(os.environ.get('RUMO_TEST_RESERVE_S') or 15)
    if reserve > 0:
        try:
            return _admit_reserved(limit, home, reserve)
        except Exception:  # fail-open: no reservation this poll, plain count
            pass
    runners = count_runners()
    return runners, 0, len(runners) < limit


def free_mem_pct():
    """Free memory % or None when unknown. WORKTREE_GUARD_MEM file = `memory_pressure -Q` output; WORKTREE_GUARD_PS set
    without it -> None (a fixture run never reads the real machine); else /usr/bin/memory_pressure -Q (macOS only:
    elsewhere the binary is missing -> None)."""
    try:
        f = os.environ.get('WORKTREE_GUARD_MEM')
        if f:
            text = open(f).read()
        elif os.environ.get('WORKTREE_GUARD_PS'):
            return None
        else:
            text = subprocess.run(['/usr/bin/memory_pressure', '-Q'], capture_output=True, text=True, timeout=2).stdout
        m = re.search(r'memory free percentage:\s*(\d+)%', text)
        return int(m.group(1)) if m else None
    except Exception:
        return None


def admission_limit():
    """Logical test runs allowed for one admission attempt: RUMO_MAX_TEST_RUNS when set (exact, no memory bonus), else
    3 when free memory is >= 30%, else 2 (unknown memory = 2)."""
    explicit = os.environ.get('RUMO_MAX_TEST_RUNS')
    if explicit:
        return int(explicit)
    pct = free_mem_pct()
    return 3 if pct is not None and pct >= 30 else 2


def wait_for_slot(home):
    """(runners [(pid, age_s)], pending, waited, admitted, limit): admission attempts every RUMO_TEST_POLL_S (default 3) s for up to
    RUMO_TEST_WAIT_S (default 50) s; admitting reserves the slot (see try_admit). Each attempt re-reads admission_limit,
    outside the slots lock; `limit` is the one in force at the last attempt."""
    wait = float(os.environ.get('RUMO_TEST_WAIT_S') or 50)
    poll = max(float(os.environ.get('RUMO_TEST_POLL_S') or 3), 0.2)
    deadline = time.monotonic() + wait
    limit = admission_limit()
    runners, pend, ok = try_admit(limit, home)
    while not ok and time.monotonic() < deadline:
        time.sleep(min(poll, max(deadline - time.monotonic(), 0)))
        limit = admission_limit()
        runners, pend, ok = try_admit(limit, home)
    return runners, pend, wait, ok, limit


SLEEP_RE = re.compile(r'sleep\s+(\d+(?:\.\d+)?)([smhd]?)(\s|$)')
SLEEP_MULT = {'': 1, 's': 1, 'm': 60, 'h': 3600, 'd': 86400}


def long_sleep(cmd):
    for seg in segments(cmd):
        m = SLEEP_RE.match(seg)
        if m and float(m.group(1)) * SLEEP_MULT[m.group(2)] >= 120:
            return True
    return False


def main():
    d = json.load(sys.stdin)
    if d.get('tool_name') != 'Bash':
        return 0
    cmd = (d.get('tool_input') or {}).get('command') or ''
    signal.signal(signal.SIGALRM, _over_budget)
    signal.setitimer(signal.ITIMER_REAL, max(float(os.environ.get('WORKTREE_GUARD_SCAN_BUDGET_S') or SCAN_BUDGET_S), 1e-6))
    cwd = d.get('cwd') or ''
    home = os.environ.get('WORKTREE_GUARD_HOME') or os.path.expanduser('~')
    root = os.path.join(home, 'orca', 'workspaces')
    in_wt = (cwd == root or cwd.startswith(root + '/') or root + '/' in cmd or '~/orca/workspaces/' in cmd)
    wt = worktree_dir(cmd, cwd, root) if in_wt else None
    nudges = []

    if in_wt and env_copy(cmd) and '#env-ok' not in last_user_text(d.get('transcript_path') or ''):
        deny("Builders/worktrees do not copy .env from another checkout. Prefer a .env.local with only what changes "
             "(local database, ports). If the owner wants the copy (e.g. the same API keys), ask in one line; "
             "they reply with #env-ok and the copy passes.")
        return 0

    if in_wt:
        # A read that can only lead to allow uses cut_all (comments removed); a read that can lead to deny uses the
        # raw cmd, as at dcf8813: the comment scan misreads a # inside ${…}/backticks or a multi-line quote, and
        # that must never hide a real --linked, remote --db-url or inline remote URL.
        cut_all = _cut(cmd, _comment_spans(cmd))
        db_all = _db_urls(cut_all)
        remote_db = [h for h in map(host_of, _db_urls(cmd)) if not is_local(h)]
        if starts(SUPABASE_PUSH, cmd):
            if not ('--local' in cut_all or (db_all and is_local(host_of(db_all[0])) and not remote_db)):
                shown = remote_db[0] if remote_db else (host_of(db_all[0]) if db_all else None)
                deny("supabase db push in a worktree without --local%s: the default is the linked (remote) project. "
                     "Run it with --local or stop and ask the user." % (f" (--db-url host {shown})" if shown else ""))
                return 0
        if starts(SUPABASE_LOCAL, cmd):
            if '--linked' in cmd or remote_db:
                deny("supabase against the remote project (--linked/non-local --db-url) in a worktree — "
                     "run it locally or stop and ask the user.")
                return 0
        if any(starts(r, cmd) for r in MIGRATE):
            inline_all, inline_raw = _inline_urls(cut_all), _inline_urls(cmd)
            urls = _resolved(inline_raw)
            if wt and (not inline_all or len(_resolved(inline_all)) < len(inline_all)
                       or len(_resolved(inline_raw)) < len(inline_raw)):
                urls += file_urls(wt)
            for u in urls:
                h = host_of(u)
                if not is_local(h):
                    deny(f"Migration in a worktree pointing at a non-local database {h} — run it against the local "
                         "database or stop and ask the user.")
                    return 0

    if starts(TEST_RE, cmd) or starts(ACCEPT_RE, cmd):
        single = '--runInBand' in cmd or re.search(r'(^|\s)-i\b', cmd)  # counts; only skips the worker nudge
        left = signal.setitimer(signal.ITIMER_REAL, 0)[0]  # the wait is not analysis: pause the scan budget
        runners, pend, waited, admitted, limit = wait_for_slot(home)
        signal.setitimer(signal.ITIMER_REAL, max(left, 1e-6))
        if not admitted:
            pids = [pid for pid, _ in runners]
            cwds = proc_cwds(pids)
            desc = '; '.join(f"{pid} (cwd {cwds.get(pid, '?')}, {fmt_age(age)})" for pid, age in runners)
            extra = f" and {pend} just admitted, still starting" if pend else ""
            deny(f"{len(pids)} test runs are already running{extra} (limit {limit} on this machine, by memory; "
                 f"PIDs: {desc}) and none finished within {waited:g} s of waiting. Run the same command "
                 "again (the hook waits again); do not poll with ps/sleep. kill <pid> only for a stuck PID of your own.")
            return 0
        if in_wt and starts(RUNNER_RE, cmd) and not any(c in cmd for c in CAPS) and not single:
            nudges.append(f"Run tests with --maxWorkers=2 (jest and vitest; Vitest 5 rejects --poolOptions): at most "
                          f"{limit} logical test runs run at once on this machine, and the others wait.")
    if long_sleep(cmd):
        nudges.append("Long wait with sleep: for CI use `gh run watch <id> --exit-status`; for builds/tests "
                      "run with run_in_background and wait for the notification.")
    if nudges:
        out('additionalContext', ' '.join(nudges))
    return 0


if __name__ == '__main__':
    try:
        rc = main()
        signal.setitimer(signal.ITIMER_REAL, 0)
        sys.exit(rc)
    except ScanBudget:
        deny("worktree-guard did not finish reading this command within its time budget and blocks instead of "
             "allowing. Split the command into smaller parts or stop and ask the user.")
        sys.exit(0)
    except Exception:
        sys.exit(0)
