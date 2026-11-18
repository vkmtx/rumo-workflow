"""Usage: python3 -I replay-blocks.py --since YYYY-MM-DD --out DIR [--projects DIR] [--orca DIR]
[--old-ref REF] [--new-dir DIR] [--labels FILE.jsonl] [--assume-marker NAME ...]
[--judge-pack FILE.jsonl]

Replay every recorded Stop-hook block of check-verify / render-verify found in the Claude Code
transcripts (read-only), run the old hook (git ref) and the new hook (working tree) on the transcript
cut just before the block, and write OUT/records.jsonl plus a summary. With --labels, evaluate the
criterion: >=90% of the false-labelled blocks now allow, every true-labelled block still blocks,
and the old hook reproduces >=95% of the recorded blocks.
Python 3.9 compatible.
"""
import argparse
import calendar
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

SCRATCH_OUT = re.compile(r'/scratchpad/|^/(private/)?tmp/|^/(private/)?var/folders/')
HOOKS = ("check-verify", "render-verify")


def parse_line(s):
    try:
        e = json.loads(s)
    except Exception:
        return None
    return e if isinstance(e, dict) else None


def block_hook(e, since):
    """Hook name when entry e is a Stop block of one of our hooks at/after since, else None."""
    a = e.get("attachment")
    if e.get("type") != "attachment" or not isinstance(a, dict):
        return None
    if a.get("type") != "hook_blocking_error" or a.get("hookEvent") != "Stop":
        return None
    if str(e.get("timestamp", "")) < since:
        return None
    be = a.get("blockingError")
    cmd = be.get("command", "") if isinstance(be, dict) else ""
    for h in HOOKS:
        if h + ".sh" in cmd:
            return h
    return None


def is_feedback(e):
    if e.get("type") != "user" or not e.get("isMeta"):
        return False
    c = (e.get("message") or {}).get("content", e.get("content"))
    return isinstance(c, str) and c.startswith("Stop hook feedback")


def cut_index(lines, k):
    """Walk back from block line k over attachment lines and the isMeta feedback line."""
    meta = False
    while k > 0:
        e = parse_line(lines[k - 1])
        if e is None:
            break
        if e.get("type") == "attachment":
            k -= 1
        elif is_feedback(e):
            meta = True
            k -= 1
        else:
            break
    return k, ("meta" if meta else "fallback")


def find_cwd(lines, k, block):
    if block.get("cwd"):
        return block["cwd"]
    for s in reversed(lines[max(0, k - 200):k]):
        e = parse_line(s)
        if e and e.get("cwd"):
            return e["cwd"]
    return ""


def discover(projects, since):
    min_mtime = calendar.timegm(time.strptime(since[:10], "%Y-%m-%d"))
    found = []
    for root, dirs, files in os.walk(projects):
        dirs.sort()
        for f in sorted(files):
            if not f.endswith(".jsonl"):
                continue
            p = os.path.join(root, f)
            try:
                if os.path.getmtime(p) < min_mtime:
                    continue
            except OSError:
                continue
            found.append(p)
    found.sort()
    for p in found:
        hits = []
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                for n, s in enumerate(fh):
                    if "hook_blocking_error" not in s:
                        continue
                    e = parse_line(s)
                    if e is None:
                        continue
                    h = block_hook(e, since)
                    if h:
                        be = e["attachment"]["blockingError"]
                        hits.append((n, h, be.get("blockingError", ""), e))
        except OSError:
            continue
        if not hits:
            continue
        with open(p, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().split("\n")
        for n, h, reason, e in hits:
            yield p, lines, n, h, reason, e


def run_hook(hook_path, cut_path, cwd, explain_path=None):
    env = dict(os.environ)
    if explain_path:
        if os.path.exists(explain_path):
            os.remove(explain_path)
        env["VERIFY_HOOK_EXPLAIN"] = explain_path
    else:
        env.pop("VERIFY_HOOK_EXPLAIN", None)
    inp = json.dumps({"transcript_path": cut_path, "cwd": cwd})
    try:
        r = subprocess.run(["/bin/bash", hook_path], input=inp, capture_output=True, text=True,
                           timeout=60, env=env)
    except subprocess.TimeoutExpired:
        return "error"
    return "block" if '"block"' in r.stdout else "allow"


def read_explain(path):
    last = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for s in fh:
                e = parse_line(s)
                if e is not None:
                    last = e
    except OSError:
        pass
    return last


def why_of(rec):
    seen = []
    for f in rec.get("files", []):
        w = f.get("why")
        if w and w not in seen:
            seen.append(w)
    return ",".join(seen) if seen else "-"


def parse_label(v):
    if v is True or (isinstance(v, str) and v.lower() == "true"):
        return "true"
    if v is False or (isinstance(v, str) and v.lower() == "false"):
        return "false"
    if isinstance(v, str) and v.lower() == "ambiguous":
        return "ambiguous"
    return None


def real_files(real, cache):
    """{path: bytes} of the package.json files, every .gitignore and .claude/no-render-verify
    tracked at HEAD of real."""
    if real in cache:
        return cache[real]
    out = {}
    r = subprocess.run(["git", "-C", real, "ls-files", "-z"], capture_output=True)
    if r.returncode == 0:
        for rel in r.stdout.decode("utf-8", "replace").split("\0"):
            if not rel or not (os.path.basename(rel) in ("package.json", ".gitignore")
                               or rel == ".claude/no-render-verify"):
                continue
            g = subprocess.run(["git", "-C", real, "show", "HEAD:" + rel], capture_output=True)
            if g.returncode == 0:
                out[rel] = g.stdout
    cache[real] = out
    return out


def copy_exclude(real, stand):
    """Copy real's $(git-common-dir)/info/exclude into the stand-in's .git/info/exclude."""
    r = subprocess.run(["git", "-C", real, "rev-parse", "--git-common-dir"],
                       capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return
    common = os.path.join(real, r.stdout.strip())
    try:
        with open(os.path.join(common, "info", "exclude"), "rb") as fh:
            data = fh.read()
    except OSError:
        return
    dst = os.path.join(stand, ".git", "info", "exclude")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "wb") as fh:
        fh.write(data)


def build_world(world, repo, real, names, assume, cache):
    """Stand-in main checkout + worktrees for repo under world; returns the stand-in main path."""
    main = os.path.join(world, "projects", repo)
    os.makedirs(main, exist_ok=True)
    subprocess.run(["git", "init", "-q", main], capture_output=True)
    for rel, data in real_files(real, cache).items():
        dst = os.path.join(main, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as fh:
            fh.write(data)
    if repo in assume:
        os.makedirs(os.path.join(main, ".claude"), exist_ok=True)
        open(os.path.join(main, ".claude", "no-render-verify"), "w").close()
    subprocess.run(["git", "-C", main, "add", "-A"], capture_output=True)
    subprocess.run(["git", "-C", main, "-c", "commit.gpgsign=false", "-c", "user.name=replay",
                    "-c", "user.email=replay@local", "commit", "-q", "--allow-empty", "-m",
                    "standin"], capture_output=True)
    copy_exclude(real, main)
    seen = set()
    for name in names:
        if name in (".", "..") or name.lower() in seen:
            continue
        seen.add(name.lower())
        subprocess.run(["git", "-C", main, "worktree", "add", "-q", "--detach",
                        os.path.join(world, "workspaces", repo, name)], capture_output=True)
    return main


NAME = r'([A-Za-z0-9_][A-Za-z0-9._-]*)'
# a path component ends where the next character cannot continue a name ("." only counts mid-name)
END = r'(?![A-Za-z0-9_-]|\.[A-Za-z0-9_-])'


def spellings(path):
    """Regex alternation of the ways a command can write absolute path: itself, $HOME/rel,
    ${HOME}/rel and ~/rel (the last three only when path is under $HOME)."""
    alts = [re.escape(path)]
    home = os.path.expanduser("~").rstrip("/")
    if home and path.startswith(home + "/"):
        rel = re.escape(path[len(home) + 1:])
        alts += [r'\$HOME/' + rel, r'\$\{HOME\}/' + rel, r'~/' + rel]
    return "(?:" + "|".join(alts) + ")"


def make_assumed(rid_world, cwd, cut_text, assume, cache):
    """Stand-in (with .claude/no-render-verify) for a live repo named in assume that lacks the marker.
    Runs whenever cwd is a live dir outside rid_world, whether or not an orca stand-in was also built.
    Returns (cut_text, cwd, built); never writes into the real repo."""
    if not cwd or not os.path.isdir(cwd):
        return cut_text, cwd, False
    if os.path.realpath(cwd).startswith(os.path.realpath(rid_world) + os.sep):
        return cut_text, cwd, False
    r = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if r.returncode != 0:
        return cut_text, cwd, False
    top = r.stdout.strip()
    base = os.path.basename(top)
    if not top or base.lower() not in assume or os.path.exists(os.path.join(top, ".claude", "no-render-verify")):
        return cut_text, cwd, False
    stand = os.path.join(rid_world, "assumed", base)
    os.makedirs(stand, exist_ok=True)
    subprocess.run(["git", "init", "-q", stand], capture_output=True)
    for rel, data in real_files(top, cache).items():
        dst = os.path.join(stand, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as fh:
            fh.write(data)
    os.makedirs(os.path.join(stand, ".claude"), exist_ok=True)
    open(os.path.join(stand, ".claude", "no-render-verify"), "w").close()
    subprocess.run(["git", "-C", stand, "add", "-A"], capture_output=True)
    subprocess.run(["git", "-C", stand, "-c", "commit.gpgsign=false", "-c", "user.name=replay",
                    "-c", "user.email=replay@local", "commit", "-q", "--allow-empty", "-m",
                    "standin"], capture_output=True)
    copy_exclude(top, stand)
    pat = re.compile(spellings(top) + END, flags=re.I)
    sub = lambda _m: stand
    return pat.sub(sub, cut_text), pat.sub(sub, cwd), True


def make_world(rid, out, orca, cut_text, cwd, assume, cache):
    """Rebuild the orca repos a block referenced but that are gone.
    Returns (cut_text, cwd, world_built)."""
    O = spellings(orca)
    hay = cut_text + "\n" + cwd
    refs = set(re.findall(O + r'/workspaces/' + NAME + '/' + NAME, hay, flags=re.I))
    proj = set(r.lower().rstrip(".") for r in re.findall(O + r'/projects/' + NAME, hay, flags=re.I))
    refs = set((r.lower(), n.rstrip(".")) for r, n in refs)
    missing = set((r, n) for r, n in refs
                  if not os.path.isdir(os.path.join(orca, "workspaces", r, n)))
    repos = set(r for r, _ in missing)
    m = re.match(O + r'/(?:workspaces|projects)/' + NAME, cwd, flags=re.I) if cwd else None
    if m:
        crepo = m.group(1).lower().rstrip(".")
        if not os.path.isdir(cwd) or crepo in assume:
            repos.add(crepo)
    repos |= set(r for r in assume if r in set(x for x, _ in refs) | proj)
    world = os.path.join(out, "world", rid)
    shutil.rmtree(world, ignore_errors=True)
    projects_dir = os.path.join(orca, "projects")
    try:
        entries = os.listdir(projects_dir)
    except OSError:
        entries = []
    built = False
    for repo in sorted(repos):
        real = None
        for ent in entries:
            if ent.lower() == repo:
                real = os.path.join(projects_dir, ent)
                break
        if real is None:
            continue
        names = sorted(n for r, n in refs if r == repo)
        main = build_world(world, repo, real, names, assume, cache)
        built = True
        wsdir = os.path.join(world, "workspaces", repo) + "/"
        pj = re.compile(O + "/projects/" + re.escape(repo) + END, flags=re.I)
        wk = re.compile(O + "/workspaces/" + re.escape(repo) + "/", flags=re.I)
        cut_text = wk.sub(lambda _m, wsdir=wsdir: wsdir, pj.sub(lambda _m, main=main: main, cut_text))
        cwd = wk.sub(lambda _m, wsdir=wsdir: wsdir, pj.sub(lambda _m, main=main: main, cwd))
    return cut_text, cwd, built, world


def msg_content(e):
    return (e.get("message") or {}).get("content", e.get("content"))


def result_text(r):
    c = r.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return " ".join(b.get("text", "") for b in c if isinstance(b, dict))
    return ""


HEREDOC = re.compile(r'<<-?[ \t]*([\'"]?)(\w+)\1[ \t]*\n(.*?)(?:\n|^)[ \t]*\2(?=\s|$)', re.S)


def short_command(cmd):
    """Whole command up to 1500 chars; each heredoc body becomes a stub with its line count."""
    def stub(m):
        body = m.group(3)
        return "<<%s [%d lines: %s] %s" % (m.group(2), len(body.split("\n")),
                                         body[:160].replace("\n", "⏎"), m.group(2))
    cmd = HEREDOC.sub(stub, cmd)
    cmd = cmd.replace("\n", " ⏎ ")
    return cmd if len(cmd) <= 1500 else cmd[:1500] + "…"


def judge_line(rid, hook, cwd, reason, cut_lines):
    """Blind judge pack entry from the original cut transcript lines."""
    entries = [e for e in (parse_line(s) for s in cut_lines) if e is not None]
    last_user, last_text = -1, ""
    for i, e in enumerate(entries):
        if e.get("type") != "user" or e.get("isMeta"):
            continue
        c = msg_content(e)
        if isinstance(c, str):
            last_user, last_text = i, c
        elif isinstance(c, list) and not any(
                isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
            last_user = i
            last_text = " ".join(b.get("text", "") for b in c
                                 if isinstance(b, dict) and b.get("type") == "text")
    results = {}
    for e in entries:
        c = msg_content(e)
        if e.get("type") == "user" and isinstance(c, list):
            for b in c:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    results[b.get("tool_use_id")] = b
    timeline = []
    for e in entries[last_user + 1:]:
        c = msg_content(e)
        if e.get("type") != "assistant" or not isinstance(c, list):
            continue
        for b in c:
            if not isinstance(b, dict) or b.get("type") != "tool_use":
                continue
            name, ti = b.get("name", ""), b.get("input") or {}
            if name in ("Edit", "Write", "MultiEdit", "Read"):
                timeline.append("%s %s" % (name, ti.get("file_path", "")))
            elif name == "Bash":
                t = "Bash " + short_command(str(ti.get("command", "")))
                if ti.get("run_in_background"):
                    t += " (background)"
                r = results.get(b.get("id"))
                t += " → "
                if r is None:
                    t += "(no result)"
                else:
                    txt = result_text(r)
                    m = re.match(r'Exit code (\d+)', txt)
                    if m:
                        t += "[exit %s] " % m.group(1)
                    if r.get("is_error"):
                        t += "[error] "
                    tail = txt[-200:].replace("\n", "⏎")
                    t += tail if tail else "(no result)"
                timeline.append(t)
            else:
                timeline.append(name)
    return {"id": rid, "hook": hook, "cwd": cwd, "reason": reason,
            "last_user": last_text[:300], "timeline": timeline[-40:]}


def pct(a, b):
    return 100.0 * a / b if b else 0.0


def main():
    ap = argparse.ArgumentParser(prog="replay-blocks.py")
    ap.add_argument("--since", required=True)
    ap.add_argument("--out", required=True)  # no default: cut/ and world/ copies run to GBs per run
    ap.add_argument("--projects", default="~/.claude/projects")
    ap.add_argument("--orca", default="~/orca")
    ap.add_argument("--old-ref", default="b0d7ff9")
    ap.add_argument("--new-dir", default=None)
    ap.add_argument("--labels", default=None)
    ap.add_argument("--assume-marker", action="append", default=[])
    ap.add_argument("--judge-pack", default=None)
    a = ap.parse_args()

    here = os.path.dirname(os.path.realpath(__file__))
    out = os.path.expanduser(a.out)
    projects = os.path.expanduser(a.projects)
    new_dir = os.path.realpath(os.path.expanduser(a.new_dir)) if a.new_dir \
        else os.path.dirname(here)
    labels_path = os.path.expanduser(a.labels) if a.labels else None
    pack_path = os.path.expanduser(a.judge_pack) if a.judge_pack else None
    orca = os.path.abspath(os.path.expanduser(a.orca))
    assume = set(x.lower() for x in a.assume_marker)

    # 1. out-dir guard
    if SCRATCH_OUT.search(os.path.realpath(out)):
        sys.stderr.write("replay: --out is under a scratch path the old hook ignores; pick another\n")
        return 2

    # 2. old hooks from git, new hooks from the working tree
    for sub in ("old", "cut", "explain"):
        os.makedirs(os.path.join(out, sub), exist_ok=True)
    top = subprocess.run(["git", "-C", here, "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True)
    if top.returncode != 0:
        sys.stderr.write("replay: cannot find the git toplevel of " + here + "\n")
        return 2
    top = top.stdout.strip()
    old_hooks, new_hooks = {}, {}
    for h in HOOKS:
        r = subprocess.run(["git", "-C", top, "show",
                            "%s:scripts/hooks-staged/%s.sh" % (a.old_ref, h)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.stderr.write("replay: git show %s:%s.sh failed: %s\n" % (a.old_ref, h, r.stderr.strip()))
            return 2
        old_hooks[h] = os.path.join(out, "old", h + ".sh")
        with open(old_hooks[h], "w") as fh:
            fh.write(r.stdout)
        new_hooks[h] = os.path.join(new_dir, h + ".sh")

    # 3-7. discover, cut, run, record
    records = []
    pack = []
    cache = {}
    for p, lines, k, hook, reason, block in discover(projects, a.since):
        rid = hashlib.sha1(os.path.abspath(p).encode()).hexdigest()[:10] + "-" + str(k + 1)
        cwd = find_cwd(lines, k, block)
        ck, cut = cut_index(lines, k)
        cut_text = "\n".join(lines[:ck]) + "\n"
        run_cwd = cwd
        cut_text, run_cwd, built, world = make_world(rid, out, orca, cut_text, cwd, assume, cache)
        cut_text, run_cwd, assumed = make_assumed(world, run_cwd, cut_text, assume, cache)
        if built or assumed:
            status = "standin" if built else "live"
            if os.path.realpath(run_cwd).startswith(os.path.realpath(world) + os.sep):
                os.makedirs(run_cwd, exist_ok=True)
        else:
            status = "live" if cwd and os.path.isdir(cwd) else "unresolved"
        cut_path = os.path.join(out, "cut", rid + ".jsonl")
        with open(cut_path, "w") as fh:
            fh.write(cut_text)
        if pack_path:
            pack.append(judge_line(rid, hook, cwd, reason, lines[:ck]))
        explain_path = os.path.join(out, "explain", rid + ".jsonl")
        old_v = run_hook(old_hooks[hook], cut_path, run_cwd)
        new_v = run_hook(new_hooks[hook], cut_path, run_cwd, explain_path)
        ex = read_explain(explain_path)
        records.append({
            "id": rid, "source": p, "line": k + 1, "transcript": cut_path, "hook": hook,
            "cwd": cwd, "run_cwd": run_cwd, "cwd_status": status,
            "cut": cut, "reason": reason, "old_verdict": old_v, "new_verdict": new_v,
            "files": ex.get("files", []),
            "verify_cmds_after_last_edit": ex.get("verify_after_last_edit", []),
            "explain": ex,
        })
    if pack_path:
        os.makedirs(os.path.dirname(os.path.abspath(pack_path)), exist_ok=True)
        with open(pack_path, "w", encoding="utf-8") as fh:
            for e in pack:
                fh.write(json.dumps(e, ensure_ascii=False) + "\n")
    with open(os.path.join(out, "records.jsonl"), "w") as fh:
        for r in records:
            fh.write(json.dumps(r) + "\n")

    # 8. summary
    n = len(records)
    per = dict((h, [r for r in records if r["hook"] == h]) for h in HOOKS)
    rep = sum(1 for r in records if r["old_verdict"] == "block")
    print("blocks: %d (check-verify %d · render-verify %d)" % (n, len(per["check-verify"]),
                                                              len(per["render-verify"])))
    print("old-hook reproduce: %d/%d (%.1f%%)" % (rep, n, pct(rep, n)))
    nb = sum(1 for r in records if r["new_verdict"] == "block")
    na = sum(1 for r in records if r["new_verdict"] == "allow")
    ne = sum(1 for r in records if r["new_verdict"] == "error")
    print("new verdict: block %d · allow %d · error %d" % (nb, na, ne))
    for h in HOOKS:
        rs = per[h]
        print("%s: old block %d · new block %d · new allow %d" % (
            h, sum(1 for r in rs if r["old_verdict"] == "block"),
            sum(1 for r in rs if r["new_verdict"] == "block"),
            sum(1 for r in rs if r["new_verdict"] == "allow")))
    for st in ("live", "standin", "unresolved"):
        rs = [r for r in records if r["cwd_status"] == st]
        if rs:
            print("%s: %d · old reproduce %d/%d" % (
                st, len(rs), sum(1 for r in rs if r["old_verdict"] == "block"), len(rs)))
    sane = n > 0 and rep / n >= 0.95
    if n and not sane:
        print("SANITY LOW: the old hook did not reproduce every block — check the cut/inputs")

    # 9. labels
    if not labels_path:
        return 0
    by_id = dict((r["id"], r) for r in records)
    labels = {}
    with open(labels_path, encoding="utf-8", errors="replace") as fh:
        for s in fh:
            e = parse_line(s)
            if e is None or "id" not in e:
                continue
            lab = parse_label(e.get("label"))
            if lab is None:
                continue
            if e["id"] not in by_id:
                sys.stderr.write("warning: label for unknown id %s\n" % e["id"])
                continue
            labels[e["id"]] = lab
    F = [i for i, v in labels.items() if v == "false"]
    T = [i for i, v in labels.items() if v == "true"]
    A = [i for i, v in labels.items() if v == "ambiguous"]
    print("labels: %d (false %d · true %d · ambiguous %d · unlabelled %d)" % (
        len(labels), len(F), len(T), len(A), n - len(labels)))
    cleared = [i for i in F if by_id[i]["new_verdict"] == "allow"]
    still = [i for i in T if by_id[i]["new_verdict"] == "block"]
    p_ok = bool(F) and len(cleared) / len(F) >= 0.90
    t_ok = len(still) == len(T)
    print("false cleared: %d/%d (%.1f%%) %s" % (len(cleared), len(F), pct(len(cleared), len(F)),
                                                "PASS" if p_ok else "FAIL"))
    print("true still blocking: %d/%d %s" % (len(still), len(T), "PASS" if t_ok else "FAIL"))
    print("sanity: %d/%d %s" % (rep, n, "PASS" if sane else "FAIL"))
    for i in F:
        if by_id[i]["new_verdict"] != "allow":
            print("STILL BLOCKS %s %s %s" % (i, by_id[i]["hook"], why_of(by_id[i])))
    for i in T:
        if by_id[i]["new_verdict"] != "block":
            print("REGRESSION %s %s %s" % (i, by_id[i]["hook"], why_of(by_id[i])))
    if p_ok and t_ok and sane:
        print("CRITERION PASS")
        return 0
    print("CRITERION FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
