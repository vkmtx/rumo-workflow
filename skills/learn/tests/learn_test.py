#!/usr/bin/env python3
"""Run: python3 -I skills/learn/tests/learn_test.py  — exit 0 = all pass."""
import io, json, os, sys, tempfile, contextlib, importlib.util, glob as _glob
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('learn', os.path.join(here, '..', 'scripts', 'learn.py'))
learn = importlib.util.module_from_spec(spec); spec.loader.exec_module(learn)

def run(argv):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = learn.main(argv)
    return code, buf.getvalue()

fails = 0
def check(name, cond):
    global fails
    print(('PASS ' if cond else 'FAIL ') + name)
    fails += not cond

root = tempfile.mkdtemp()
cwd = '/tmp/fake/repo'
pdir = learn.project_dir(cwd, root); os.makedirs(pdir)
lines = [
    {'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'Done, I published the deploy.'}]}},
    {'type': 'user', 'message': {'content': 'não, eu pedi só o PR, sem deploy'}},
    {'type': 'user', 'message': {'content': 'ótimo, segue'}},
    {'type': 'user', 'message': {'content': '<local-command-caveat>não</local-command-caveat>'}},
    {'type': 'user', 'isMeta': True, 'message': {'content': 'errado meta'}},
    {'type': 'user', 'message': {'content': [{'type': 'text', 'text': '[Request interrupted by user]'}]}},
    {'type': 'user', 'message': {'content': [{'type': 'tool_result', 'is_error': True, 'content': 'PreToolUse:Bash hook error: Blocked: deploy without a request'}]}},
    {'type': 'attachment', 'attachment': {'type': 'hook_blocking_error', 'hookName': 'Stop', 'blockingError': {'blockingError': 'No verification ran'}}},
    {'type': 'user', 'message': {'content': [{'type': 'tool_result', 'is_error': True, 'content': 'Exit code 1\nnpm ERR!'}]}},
    {'type': 'user', 'message': {'content': [{'type': 'tool_result', 'is_error': True, 'content': 'Exit code 1\nnpm ERR!'}]}},
    {'type': 'user', 'isSidechain': True, 'message': {'content': 'errado (subagent)'}},
    {'type': 'user', 'message': {'content': 'não, eu pedi só o PR, sem deploy'}},
    {'type': 'user', 'message': {'content': [{'type': 'tool_result', 'is_error': True, 'content': "The user doesn't want to proceed with this tool use."}]}},
    'not json',
]
with open(os.path.join(pdir, 's1.jsonl'), 'w') as f:
    for l in lines:
        f.write((l if isinstance(l, str) else json.dumps(l)) + '\n')

code, out = run(['harvest', '--current', '--cwd', cwd, '--root', root])
check('harvest exit 0', code == 0)
check('correction caught with the assistant turn it answered', 'eu pedi só o PR' in out and 'I published the deploy' in out)
check('praise is not a correction', 'ótimo' not in out)
check('command caveats, meta and sidechain skipped', 'meta' not in out and 'subagent' not in out and 'User corrections (1)' in out)
check('interrupt counted', 'Interrupts: 1' in out)
check('PreToolUse block parsed', 'PreToolUse:Bash: Blocked' in out)
check('Stop hook block parsed', 'Stop: No verification ran' in out)
check('repeated tool failure ≥2 keeps the printed line', '×2 Exit code 1 · npm ERR!' in out)
check('duplicate correction deduped within a session', out.count('eu pedi só o PR') == 1 and '×2 sessions' not in out)
check('rejections counted apart', 'rejected tool calls: 1' in out)
# same correction in a second session -> one entry, counted ×2 sessions
with open(os.path.join(pdir, 's2.jsonl'), 'w') as f:
    f.write(json.dumps({'type': 'user', 'message': {'content': 'não, eu pedi só o PR, sem deploy'}}) + '\n')
    for probe in ['para cada arquivo, roda o lint', 'no build de ontem tinha 3 testes',
                  'roda de novo os testes por favor', 'cadê o PR? pode abrir', 'não sei, faz o que achar melhor']:
        f.write(json.dumps({'type': 'user', 'message': {'content': probe}}) + '\n')
    f.write(json.dumps({'type': 'user', 'message': {'content': 'não era isso que eu pedi'}}) + '\n')
code, out = run(['harvest', '--days', '1', '--root', root])
check('repeat across sessions counted', '×2 sessions' in out and out.count('eu pedi só o PR') == 1)
check('ordinary requests are not corrections', not any(p in out for p in ['para cada', 'no build de ontem', 'roda de novo', 'cadê o PR', 'não sei']))
check('real correction still caught', 'não era isso que eu pedi' in out)
code, out = run(['harvest', '--session', 'nope', '--root', root])
check('no match is graceful', 'no transcripts matched' in out)

ev = os.path.join(root, 'events.jsonl')
with open(ev, 'w') as f:
    for e in [
        {'ts': '2099-01-01T00:00:00Z', 'repo': 'r', 'kind': 'run', 'steps': {'sonnet': 4, 'opus': 1}, 'first_try': {'sonnet': 3, 'opus': 1}},
        {'ts': '2099-01-01T00:00:00Z', 'repo': 'r', 'kind': 'revise', 'model': 'sonnet', 'category': 'db-migration', 'why': 'forgot down migration', 'files': ['db/m.sql']},
        {'ts': '2099-01-01T00:00:00Z', 'repo': 'r', 'kind': 'escalate', 'model': 'sonnet', 'category': 'db-migration', 'why': 'forgot down migration', 'files': ['db/m.sql']},
        {'ts': '2099-01-01T00:00:00Z', 'repo': 'r', 'kind': 'finding', 'severity': 'major', 'category': 'auth', 'outcome': 'open', 'why': 'missing auth check'},
        {'kind': 'run', 'steps': {'sonnet': 10}, 'first_try': {'sonnet': 0}},
    ]:
        f.write(json.dumps(e) + '\n')
code, out = run(['stats', '--events', ev, '--days', '36500000'])
check('stats first-try rate (undated run ignored)', 'sonnet: 3/4 = 75%' in out)
check('stats category calibration', 'db-migration: 2' in out)
check('stats repeated cause', '×2 forgot down migration' in out)
check('stats hot file', '×2 db/m.sql' in out)
check('stats findings', 'major 1' in out)

import gzip

def run2(argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = learn.main(argv)
    return code, out.getvalue(), err.getvalue()

def read_lines(p):
    return [l for l in open(p).read().split('\n') if l]

ed = tempfile.mkdtemp()
evf = os.path.join(ed, 'sub', 'events.jsonl')
code, out, err = run2(['event', json.dumps({'kind': 'revise', 'repo': 'r', 'category': 'api', 'why': 'x'}), '--events', evf])
l = read_lines(evf)
check('event valid appends line with ts', code == 0 and 'logged revise' in out and len(l) == 1 and json.loads(l[0]).get('ts', '').endswith('Z'))
code, out, err = run2(['event', json.dumps({'kind': 'nope', 'repo': 'r', 'category': 'api'}), '--events', evf])
check('event bad kind exit 2, file unchanged', code == 2 and err and len(read_lines(evf)) == 1)
code, out, err = run2(['event', json.dumps({'kind': 'block', 'repo': 'r'}), '--events', evf])
check('event non-run without category exit 2', code == 2 and 'category' in err and len(read_lines(evf)) == 1)
code, out, err = run2(['event', json.dumps({'kind': 'block', 'repo': 'r', 'category': 'zzz'}), '--events', evf])
check('event category outside enum exit 2', code == 2 and 'db-migration' in err and len(read_lines(evf)) == 1)
code, out, err = run2(['event', json.dumps({'kind': 'run', 'category': 'zzz'}), '--events', evf])
check('event missing repo exit 2', code == 2 and len(read_lines(evf)) == 1)
code, out, err = run2(['event', '[1]', '--events', evf])
check('event non-object exit 2', code == 2)

check('scrub url credentials', 'postgres://<redacted>@db.x.com/a' in learn.scrub('postgres://u:pw@db.x.com/a') and 'pw' not in learn.scrub('postgres://u:pw@db.x.com/a'))
check('scrub key=value', learn.scrub('token=abc123') == 'token=<redacted>')
check('scrub sk- key', 'sk-abcdefghijklmnopqrstuv' not in learn.scrub('use sk-abcdefghijklmnopqrstuv now') and '<redacted>' in learn.scrub('use sk-abcdefghijklmnopqrstuv now'))
check('scrub leaves plain text', learn.scrub('hello world') == 'hello world')
run2(['event', json.dumps({'kind': 'finding', 'repo': 'r', 'category': 'auth', 'outcome': 'open', 'severity': 'minor', 'why': 'password: hunter2 in log', 'files': ['a']}), '--events', evf])
check('event scrubs string values', 'hunter2' not in open(evf).read())

# finding events: outcome required; axis/model optional enums
fe = os.path.join(ed, 'finding-events.jsonl')
fbase = {'kind': 'finding', 'repo': 'r', 'category': 'refactor', 'severity': 'minor'}
code, out, err = run2(['event', json.dumps(fbase), '--events', fe])
check('finding without outcome exit 2', code == 2 and 'outcome' in err and not os.path.exists(fe))
code, out, err = run2(['event', json.dumps({**fbase, 'outcome': 'meh'}), '--events', fe])
check('finding with outcome outside enum exit 2', code == 2 and 'outcome' in err and not os.path.exists(fe))
code, out, err = run2(['event', json.dumps({**fbase, 'outcome': 'fixed', 'axis': 'nope'}), '--events', fe])
check('finding with bad axis exit 2', code == 2 and 'axis' in err and not os.path.exists(fe))
code, out, err = run2(['event', json.dumps({**fbase, 'outcome': 'fixed', 'axis': 'bugs', 'model': 'gpt'}), '--events', fe])
check('finding with bad model exit 2', code == 2 and 'model' in err and not os.path.exists(fe))
code, out, err = run2(['event', json.dumps({**fbase, 'outcome': 'fixed', 'axis': 'standards', 'model': 'sonnet'}), '--events', fe])
check('finding with outcome+axis+model accepted', code == 0 and len(read_lines(fe)) == 1)
code, out, err = run2(['event', json.dumps({**fbase, 'outcome': 'open'}), '--events', fe])
check('finding with outcome only accepted', code == 0 and len(read_lines(fe)) == 2)

# harvest scrubs
root3 = tempfile.mkdtemp(); p3 = learn.project_dir('/tmp/x/y', root3); os.makedirs(p3)
with open(os.path.join(p3, 's.jsonl'), 'w') as f:
    f.write(json.dumps({'type': 'user', 'message': {'content': 'não, use postgres://admin:s3cretpw@db.example.com/app'}}) + '\n')
code, out = run(['harvest', '--current', '--cwd', '/tmp/x/y', '--root', root3])
check('harvest scrubs url password', 's3cretpw' not in out and '<redacted>@db.example.com' in out)

# rotation
rd = tempfile.mkdtemp(); rf = os.path.join(rd, 'events.jsonl')
with open(rf, 'w') as f:
    f.write(json.dumps({'ts': '2020-01-05T00:00:00Z', 'kind': 'run', 'repo': 'r', 'steps': {'sonnet': 2}, 'first_try': {'sonnet': 2}}) + '\n')
run2(['event', json.dumps({'kind': 'block', 'repo': 'r', 'category': 'config'}), '--events', rf])
check('rotation archives old month', os.path.exists(os.path.join(rd, 'events-202001.jsonl.gz')))
check('rotation starts fresh file with 1 line', len(read_lines(rf)) == 1)
code, out = run(['stats', '--events', rf, '--days', '36500000'])
check('stats reads archived .gz', '1 build run(s)' in out)

# by_category, calibration, env
cf = os.path.join(rd, 'cal.jsonl')
def bc(c, model, n, m):
    return {'ts': '2099-01-01T00:00:00Z', 'kind': 'run', 'repo': 'r', 'by_category': {c: {model: {'steps': n, 'first_try': m}}}}
with open(cf, 'w') as f:
    for e in [bc('api', 'sonnet', 6, 3), bc('docs', 'opus', 9, 9), bc('perf', 'sonnet', 4, 1),
              {'ts': '2099-01-01T00:00:00Z', 'repo': 'r', 'kind': 'revise', 'model': 'sonnet', 'category': 'config', 'env': True},
              {'ts': '2099-01-01T00:00:00Z', 'repo': 'r', 'kind': 'revise', 'model': 'sonnet', 'category': 'auth'}]:
        f.write(json.dumps(e) + '\n')
code, out = run(['stats', '--events', cf, '--days', '36500000'])
check('first-try by category section', '## First-try by category' in out and 'api · sonnet: 3/6 = 50%' in out)
check('low n flagged', 'perf · sonnet: 1/4 = 25% (low n)' in out)
check('calibration sharpen sonnet', 'api: sonnet 50% over 6 — sharpen the planner brief or route to opus' in out)
check('calibration move opus to sonnet', 'docs: opus 100% over 9 — candidate to move to sonnet' in out)
check('low n not a candidate', 'perf: sonnet' not in out)
check('env failure excluded from sonnet failures', '- auth: 1' in out and '- config: 1' not in out)
check('infra failures counted', 'Infra failures (not the model): 1' in out)

small = os.path.join(root, 'SKILL.md'); open(small, 'w').write('x' * 100)
big = os.path.join(root, 'lessons.md'); open(big, 'w').write('x' * 9000)
check('budget ok exit 0', run(['budget', small])[0] == 0)
code, out = run(['budget', small, big])
check('budget over exit 1', code == 1 and 'OVER' in out)
check('budget explicit limit', run(['budget', big + ':10'])[0] == 0)
mem = os.path.join(root, 'MEMORY.md'); open(mem, 'w').write('- [a](a.md) — ' + 'x' * 200 + '\n')
code, out = run(['budget', mem])
check('budget flags a MEMORY line over 150 chars', code == 1 and '1 over 150 chars' in out)
les = os.path.join(root, 'lessons.md'); open(les, 'w').write('- L1 · use postgres://u:pw@h/db\n- L2 · fine\n')
code, out = run(['scan', les])
check('scan flags a secret by line, without the value', code == 1 and 'lessons.md:1' in out and 'u:pw@' not in out)
open(les, 'w').write('- L2 · fine\n')
check('scan clean exits 0', run(['scan', les])[0] == 0)
oe = os.path.join(root, 'out-events.jsonl')
with open(oe, 'w') as f:
    for o in ['dismissed'] * 3 + ['fixed']:
        f.write(json.dumps({'ts': '2099-01-01T00:00:00Z', 'repo': 'r', 'kind': 'finding', 'severity': 'minor', 'category': 'refactor', 'outcome': o}) + '\n')
code, out = run(['stats', '--events', oe, '--days', '36500000'])
check('stats groups findings by outcome', 'dismissed 3' in out and 'fixed 1' in out)
check('stats flags a reviewer class dismissed 3x', 'dismissed ×3 in refactor' in out)
# spend: main session vs subagents, from transcripts
sroot = tempfile.mkdtemp()
def turn(model, ctx, out=10):
    return {'type': 'assistant', 'message': {'model': model, 'usage': {'input_tokens': 0, 'cache_read_input_tokens': ctx, 'cache_creation_input_tokens': 0, 'output_tokens': out}}}
proj = os.path.join(sroot, '-tmp-proj'); sess = os.path.join(proj, 'sess1', 'subagents'); os.makedirs(sess)
with open(os.path.join(proj, 'sess1.jsonl'), 'w') as f:
    for c in (100000, 400000): f.write(json.dumps(turn('claude-opus-5-5', c)) + '\n')
    f.write('not json\n')
with open(os.path.join(sess, 'agent-a.jsonl'), 'w') as f:
    for c in (50000, 60000, 70000): f.write(json.dumps(turn('claude-opus-5-5', c)) + '\n')
json.dump({'agentType': 'general-purpose'}, open(os.path.join(sess, 'agent-a.meta.json'), 'w'))
with open(os.path.join(sess, 'agent-b.jsonl'), 'w') as f:
    f.write(json.dumps(turn('claude-haiku-5-5', 20000)) + '\n')
json.dump({'agentType': 'rumo:extractor'}, open(os.path.join(sess, 'agent-b.meta.json'), 'w'))
code, out = run(['spend', '--root', sroot, '--days', '7'])
check('spend exits 0', code == 0)
check('spend splits main vs subagents', 'main 500.0k' in out and 'subagents 200.0k' in out)
check('spend reports main context >300k share', '>300k: 80%' in out)
check('spend groups by agent type and model', 'general-purpose' in out and 'opus' in out and 'rumo:extractor' in out and 'haiku' in out)
check('spend lists heaviest run with turns', 'agent-a' not in out and '3 turns' in out)
open(os.path.join(sess, 'agent-c.jsonl'), 'w').close()
json.dump({'agentType': 'general-purpose'}, open(os.path.join(sess, 'agent-c.meta.json'), 'w'))
code, out = run(['spend', '--root', sroot, '--days', '7'])
check('spend skips empty transcripts', '1 runs' in out and '2 runs' not in out and '? · ?' not in out)
droot = tempfile.mkdtemp(); os.makedirs(os.path.join(droot, 'p'))
m = turn('claude-opus-5-5', 100000, 0); m['message']['id'] = 'msg_1'
old = turn('claude-opus-5-5', 50000, 0); old['message']['id'] = 'msg_0'; old['timestamp'] = '2001-01-01T00:00:00Z'
nul = {'type': 'assistant', 'message': {'id': 'msg_2', 'model': 'claude-opus-5-5', 'usage': {'input_tokens': None, 'cache_read_input_tokens': 1000, 'output_tokens': None}}}
with open(os.path.join(droot, 'p', 's.jsonl'), 'w') as f:
    for l in (old, m, m, nul): f.write(json.dumps(l) + '\n')
code, out = run(['spend', '--root', droot, '--days', '7'])
check('spend counts one API response once (same message.id on several lines)', 'main 101.0k' in out)
check('spend drops turns older than the window', code == 0 and '151' not in out.splitlines()[0])
stream = lambda o: {'type': 'assistant', 'message': {'id': 'msg_s', 'model': 'claude-opus-5-5', 'usage': {'input_tokens': 0, 'cache_read_input_tokens': 1000, 'output_tokens': o}}}
sroot2 = tempfile.mkdtemp(); os.makedirs(os.path.join(sroot2, 'p'))
with open(os.path.join(sroot2, 'p', 's.jsonl'), 'w') as f:
    for o in (8, 2103): f.write(json.dumps(stream(o)) + '\n')
code, out = run(['spend', '--root', sroot2, '--days', '7'])
check('spend keeps the final usage of a streamed response (last line wins)', 'main 3.1k' in out)
code, out = run(['spend', '--root', sroot, '--days', '0'])
check('spend with nothing in window says so', code == 0 and 'no transcripts' in out)
# stats: findings by axis x model
ax = os.path.join(root, 'axis-events.jsonl')
with open(ax, 'w') as f:
    for o in ['fixed', 'dismissed', 'dismissed', 'open']:
        f.write(json.dumps({'ts': '2099-01-01T00:00:00Z', 'repo': 'r', 'kind': 'finding', 'severity': 'minor', 'category': 'refactor', 'axis': 'standards', 'model': 'sonnet', 'outcome': o}) + '\n')
    f.write(json.dumps({'ts': '2099-01-01T00:00:00Z', 'repo': 'r', 'kind': 'finding', 'severity': 'minor', 'category': 'refactor', 'axis': 'bugs', 'model': 'opus', 'outcome': 'fixed'}) + '\n')
    f.write(json.dumps({'ts': '2099-01-01T00:00:00Z', 'repo': 'r', 'kind': 'finding', 'severity': 'minor', 'category': 'refactor', 'outcome': 'dismissed'}) + '\n')
code, out = run(['stats', '--events', ax, '--days', '36500000'])
check('stats prints findings by axis x model', '## Findings by axis × model' in out
      and '- standards · sonnet: 4 findings — fixed 1, dismissed 2, open 1 (dismiss rate 50%)' in out
      and '- bugs · opus: 1 findings — fixed 1, dismissed 0, open 0 (dismiss rate 0%)' in out
      and '- ? · ?: 1 findings — fixed 0, dismissed 1, open 0 (dismiss rate 100%)' in out)
with open(ax, 'a') as f:
    for m in ('sonnet', 'opus'):
        f.write(json.dumps({'ts': '2099-01-01T00:00:00Z', 'repo': 'r', 'kind': 'finding', 'severity': 'minor', 'category': 'refactor', 'axis': 'standards', 'model': m, 'outcome': 'fixed', 'paired': True}) + '\n')
code, out = run(['stats', '--events', ax, '--days', '36500000'])
check('stats keeps paired runs in their own rows', '- standards · sonnet · paired: 1 findings' in out
      and '- standards · opus · paired: 1 findings' in out and '- standards · sonnet: 4 findings' in out)
pe = os.path.join(root, 'p.jsonl')
fb = {'kind': 'finding', 'repo': 'r', 'category': 'refactor', 'outcome': 'fixed', 'severity': 'minor'}
code, out, err = run2(['event', json.dumps(dict(fb, paired='yes')), '--events', pe])
check('paired must be a boolean', code == 2 and 'paired' in err)
code, out, err = run2(['event', json.dumps(dict(fb, paired=True)), '--events', pe])
check('paired true accepted', code == 0)
code, out = run(['stats', '--events', oe, '--days', '36500000'])
check('stats omits axis x model when no finding has an axis', 'axis × model' not in out)

# batch events from stdin
def run3(argv, text):
    old = sys.stdin
    sys.stdin = io.StringIO(text)
    try:
        return run2(argv)
    finally:
        sys.stdin = old

bf = os.path.join(ed, 'batch', 'events.jsonl')
b1 = json.dumps({'kind': 'finding', 'repo': 'r', 'category': 'api', 'outcome': 'fixed', 'severity': 'minor'})
b2 = json.dumps({'kind': 'run', 'repo': 'r'})
b3 = json.dumps({'kind': 'finding', 'repo': 'r', 'category': 'docs', 'outcome': 'open', 'severity': 'minor'})
code, out, err = run3(['event', '-', '--events', bf], b1 + '\n\n' + b2 + '\n' + b3 + '\n')
check('event - batch writes 3 lines', code == 0 and len(read_lines(bf)) == 3
      and out.strip() == 'logged 3 events (finding×2, run×1)')
bf2 = os.path.join(ed, 'batch2', 'events.jsonl')
code, out, err = run3(['event', '-', '--events', bf2], b1 + '\n' + json.dumps({'kind': 'nope', 'repo': 'r'}) + '\n' + b3 + '\n')
check('event - invalid line writes nothing, exit 2, names line 2',
      code == 2 and 'line 2' in err and not os.path.exists(bf2))
code, out, err = run3(['event', '-', '--events', bf2], b1 + '\nnot json\n')
check('event - invalid JSON line names line 2', code == 2 and 'line 2' in err and not os.path.exists(bf2))

# risk-bucketed categories stay out of calibration candidates
rk = os.path.join(root, 'risk-events.jsonl')
with open(rk, 'w') as f:
    for e in [bc('api/risk', 'opus', 6, 6), bc('api', 'opus', 5, 5)]:
        f.write(json.dumps(e) + '\n')
code, out = run(['stats', '--events', rk, '--days', '36500000'])
check('stats risk bucket still listed by category', 'api/risk · opus: 6/6 = 100%' in out)
check('stats risk bucket not a candidate', 'api: opus 100% over 5 — candidate to move to sonnet' in out
      and 'api/risk: opus' not in out)
check('stats prints risk-routed excluded line', '- risk-routed steps excluded: 6 (api/risk)' in out)

# run/finding shape validation
code, out, err = run3(['event', '-', '--events', os.path.join(root, 'shape', 'x.jsonl')], json.dumps({'kind': 'run', 'repo': 'x', 'steps': 11}) + '\n')
check('event rejects run with numeric steps (exit 2, names steps, nothing written)',
      code == 2 and 'steps' in err and not os.path.exists(os.path.join(root, 'shape', 'x.jsonl')))
RUN = {'kind': 'run', 'repo': 'r'}
FND = {'kind': 'finding', 'repo': 'r', 'category': 'api', 'outcome': 'fixed', 'severity': 'minor'}
def bad_case(name, base, contains=None, **kw):
    r = learn.validate_event(dict(base, **kw))
    check('validate rejects ' + name, bool(r) and (contains is None or contains in r))
def bad_drop(name, base, key, contains=None):
    d = dict(base); d.pop(key)
    r = learn.validate_event(d)
    check('validate rejects ' + name, bool(r) and (contains is None or contains in r))
bad_case('steps as text', RUN, steps='sonnet 0, opus 5')
bad_case('steps unknown model', RUN, steps={'gpt': 1})
bad_case('steps negative', RUN, steps={'sonnet': -1})
bad_case('steps bool count', RUN, steps={'sonnet': True})
bad_case('first_try above steps', RUN, 'first_try', steps={'sonnet': 2}, first_try={'sonnet': 3})
bad_case('first_try without steps', RUN, 'first_try', first_try={'opus': 1})
bad_case('by_category key ui', RUN, by_category={'ui': {'opus': {'steps': 1, 'first_try': 1}}})
bad_case('by_category comma key', RUN, by_category={'auth, data-model/risk': {'opus': {'steps': 1, 'first_try': 1}}})
bad_case('by_category key api/risky', RUN, by_category={'api/risky': {'opus': {'steps': 1, 'first_try': 1}}})
bad_case('by_category cell missing first_try', RUN, by_category={'api': {'opus': {'steps': 2}}})
bad_case('by_category cell string steps', RUN, by_category={'api': {'opus': {'steps': '2', 'first_try': 1}}})
bad_case('by_category cell first_try above steps', RUN, by_category={'api': {'opus': {'steps': 1, 'first_try': 2}}})
bad_case('findings key medium', RUN, findings={'medium': 1})
bad_drop('finding without severity', FND, 'severity')
bad_case('finding severity medium', FND, severity='medium')
bad_case('finding axis ci', FND, 'env', axis='ci')
bad_case('finding model ci', FND, model='ci')
bad_case('legacy not boolean', dict(kind='revise', repo='r', category='api'), legacy='yes')
check('validate accepts a full run', learn.validate_event({'kind': 'run', 'repo': 'r',
      'steps': {'sonnet': 3, 'opus': 2, 'orchestrator': 1}, 'first_try': {'sonnet': 2, 'opus': 2, 'orchestrator': 1},
      'by_category': {'api': {'sonnet': {'steps': 3, 'first_try': 2}}, 'auth/risk': {'opus': {'steps': 2, 'first_try': 2}},
                      'visual': {'orchestrator': {'steps': 1, 'first_try': 1}}},
      'findings': {'blocker': 0, 'major': 1, 'minor': 0, 'question': 0}}) is None)
check('validate accepts a bare run', learn.validate_event({'kind': 'run', 'repo': 'r'}) is None)
check('validate accepts question/open/orchestrator finding',
      learn.validate_event(dict(FND, severity='question', outcome='open', model='orchestrator')) is None)
check('validate accepts visual category', learn.validate_event({'kind': 'revise', 'repo': 'r', 'category': 'visual'}) is None)
check('validate accepts legacy true', learn.validate_event({'kind': 'revise', 'repo': 'r', 'category': 'api', 'legacy': True}) is None)

# stats: malformed lines are skipped and reported; a paired why counts once
TS = '2099-01-01T00:00:00Z'
sk = os.path.join(root, 'skip-events.jsonl')
with open(sk, 'w') as f:
    f.write(json.dumps({'ts': TS, 'kind': 'run', 'repo': 'r', 'steps': {'sonnet': 2}, 'first_try': {'sonnet': 1}}) + '\n')
    f.write(json.dumps({'ts': TS, 'kind': 'run', 'repo': 'r', 'steps': 11}) + '\n')
    f.write('not json\n')
    f.write(json.dumps({'ts': TS, 'kind': 'finding', 'repo': 'r', 'category': 'refactor', 'outcome': 'fixed', 'severity': 'medium'}) + '\n')
    f.write(json.dumps({'kind': 'run', 'steps': 5}) + '\n')
code, out = run(['stats', '--events', sk, '--days', '36500000'])
check('stats skips malformed lines and names them', code == 0 and 'skipped 3 malformed (lines 2, 3, 4)' in out and 'sonnet: 1/2 = 50%' in out)
code, out = run(['stats', '--events', cf, '--days', '36500000'])
check('stats on a clean file prints no skipped note', 'skipped' not in out)
many = os.path.join(root, 'many-bad.jsonl')
with open(many, 'w') as f:
    for _ in range(25):
        f.write(json.dumps({'ts': TS, 'kind': 'run', 'repo': 'r', 'steps': 'x'}) + '\n')
code, out = run(['stats', '--events', many, '--days', '36500000'])
check('stats caps the skipped line list', code == 0 and 'skipped 25 malformed' in out and '+5 more' in out)
pw = os.path.join(root, 'paired-why.jsonl')
def pf(m, issue):
    return {'ts': TS, 'kind': 'finding', 'repo': 'r', 'issue': issue, 'category': 'refactor', 'outcome': 'fixed',
            'severity': 'minor', 'axis': 'standards', 'model': m, 'paired': True, 'why': 'dup paired why'}
with open(pw, 'w') as f:
    for m in ('sonnet', 'opus'):
        f.write(json.dumps(pf(m, 1)) + '\n')
code, out = run(['stats', '--events', pw, '--days', '36500000'])
check('a paired why counts once per (repo, issue)', '\u00d72 dup paired why' not in out)
with open(pw, 'a') as f:
    for m in ('sonnet', 'opus'):
        f.write(json.dumps(pf(m, 2)) + '\n')
code, out = run(['stats', '--events', pw, '--days', '36500000'])
check('the same why on two issues counts twice', '\u00d72 dup paired why' in out)

# normalize: one fixture line per mapping; source untouched, backup identical, output valid
nd = tempfile.mkdtemp()
nf, no, no2 = (os.path.join(nd, n) for n in ('events.jsonl', 'out.jsonl', 'out2.jsonl'))
fin = {'ts': TS, 'kind': 'finding', 'repo': 'r', 'category': 'api', 'outcome': 'fixed',
       'severity': 'minor', 'axis': 'bugs', 'model': 'opus'}
def fv(**kw):
    d = dict(fin); d.update(kw); return {k: v for k, v in d.items() if v is not None}
fixture = [
    {'ts': TS, 'kind': 'run', 'repo': 'r', 'steps': 'sonnet 0, opus 5, orchestrator 1', 'first_try': 'opus 5', 'tag': 'text'},
    {'ts': TS, 'kind': 'run', 'repo': 'r', 'steps': 11, 'tag': 'eleven'},
    {'ts': TS, 'kind': 'run', 'repo': 'r', 'tag': 'bc', 'by_category': {
        'ui': {'opus': {'steps': 1, 'first_try': 1}}, 'ui-logic': {'opus': {'steps': 2, 'first_try': 1}},
        'auth, data-model/risk': {'sonnet': {'steps': 1, 'first_try': 0}}, 'visual': {'opus': {'steps': 1, 'first_try': 1}}}},
    {'ts': TS, 'kind': 'revise', 'repo': 'r', 'category': 'authz-race', 'tag': 'authz'},
    {'ts': TS, 'kind': 'scope', 'repo': 'r', 'category': 'observability', 'tag': 'obs'},
    {'ts': TS, 'kind': 'block', 'repo': 'r', 'category': 'fix', 'tag': 'fix'},
    fv(category='ui-copy', tag='uicopy'),
    fv(severity='medium', tag='medium'),
    fv(severity='low', tag='low'),
    fv(severity=None, tag='nosev'),
    fv(outcome=None, tag='nooutcome'),
    fv(axis='ci', model='ci', paired=True, tag='ci'),
    fv(axis=None, tag='noaxis'),
    {'ts': TS, 'kind': 'revise', 'repo': 'r', 'category': 'layout', 'tag': 'layout'},
    {'ts': TS, 'kind': 'revise', 'repo': 'r', 'category': 'bug', 'tag': 'bug'},
    {'ts': TS, 'kind': 'run', 'repo': 'r', 'steps': {'opus': 1}, 'findings': {'major': 1, 'medium': 2, 'low': 1}, 'tag': 'fmedlow'},
]
valid_line = json.dumps(fv(tag='valid'))  # default separators: a re-dump would change its bytes
with open(nf, 'w') as f:
    for e in fixture:
        f.write(json.dumps(e) + '\n')
    f.write(valid_line + '\n')
    f.write('not json\n')
orig = open(nf, 'rb').read()
code, out, err = run2(['normalize', '--events', nf, '--out', no])
check('normalize exits 0', code == 0)
check('normalize leaves the source untouched', open(nf, 'rb').read() == orig)
baks = _glob.glob(nf + '.bak-*')
check('normalize writes exactly one backup', len(baks) == 1)
check('backup equals the original bytes', len(baks) == 1 and open(baks[0], 'rb').read() == orig)
olines = read_lines(no) if os.path.exists(no) else []
oev = [json.loads(l) for l in olines]
check('every normalized line passes validate_event', bool(oev) and all(learn.validate_event(e) is None for e in oev))
by = {e.get('tag'): e for e in oev}
g = lambda t: by.get(t) or {}
check('text run steps become an object', g('text').get('steps') == {'sonnet': 0, 'opus': 5, 'orchestrator': 1})
check('text run first_try becomes an object', g('text').get('first_try') == {'opus': 5})
check('numeric steps move to legacy_steps', g('eleven').get('legacy_steps') == 11
      and 'steps' not in g('eleven') and g('eleven').get('legacy') is True)
nbc = g('bc').get('by_category') or {}
check('ui + ui-logic merge into ui-logic', nbc.get('ui-logic') == {'opus': {'steps': 3, 'first_try': 2}} and 'ui' not in nbc)
check('comma key maps to auth/risk', nbc.get('auth/risk') == {'sonnet': {'steps': 1, 'first_try': 0}})
check('visual key unchanged', nbc.get('visual') == {'opus': {'steps': 1, 'first_try': 1}} and len(nbc) == 3)
check('layout -> ui-logic', g('layout').get('category') == 'ui-logic')
check('bug -> other', g('bug').get('category') == 'other')
check('run findings medium/low fold into major/minor', g('fmedlow').get('findings') == {'major': 3, 'minor': 1})
check('authz-race -> auth', g('authz').get('category') == 'auth')
check('observability -> other', g('obs').get('category') == 'other')
check('unknown fix -> other', g('fix').get('category') == 'other')
check('ui-copy -> ui-logic', g('uicopy').get('category') == 'ui-logic')
check('medium -> major', g('medium').get('severity') == 'major')
check('low -> minor', g('low').get('severity') == 'minor')
check('missing severity -> minor + legacy', g('nosev').get('severity') == 'minor' and g('nosev').get('legacy') is True)
check('missing outcome -> open + legacy', g('nooutcome').get('outcome') == 'open' and g('nooutcome').get('legacy') is True)
ci = g('ci')
check('ci finding becomes an env revise', ci.get('kind') == 'revise' and ci.get('env') is True
      and not ({'axis', 'model', 'severity', 'outcome', 'paired'} & set(ci)))
check('axis-less finding is marked legacy', g('noaxis').get('legacy') is True)
check('already-valid line is byte-identical', valid_line in olines)
check('unparseable line dropped', len(olines) == len(fixture) + 1)
check('normalize prints the tag summary', '- category-ui:' in out and '- findings-medium-low:' in out
      and 'dropped-unparseable' in out and 'untouched' in out)
check('normalize closes with the diff command to show', 'show the user: diff ' in out and bool(baks) and baks[0] + ' ' + no in out)
code, out2, err2 = run2(['normalize', '--events', no, '--out', no2])
check('normalize is idempotent', code == 0 and ' 0 changed' in out2)
code, out3 = run(['stats', '--events', no, '--days', '36500000'])
check('stats on the normalized copy skips nothing', code == 0 and 'skipped' not in out3)
code, out4, err4 = run2(['normalize', '--events', os.path.join(nd, 'missing.jsonl'), '--out', no2])
check('normalize on a missing file exits 2', code == 2 and 'no file' in err4)

# normalize: a non-int cell in a merged by_category is reported as still invalid, never a traceback
mg = os.path.join(nd, 'merge.jsonl'); mo = os.path.join(nd, 'merge-out.jsonl')
with open(mg, 'w') as f:
    f.write(json.dumps({'ts': TS, 'kind': 'run', 'repo': 'r', 'by_category': {
        'ui': {'opus': {'steps': '2', 'first_try': 1}}, 'layout': {'opus': {'steps': 1, 'first_try': 1}}}}) + '\n')
try:
    code, out5, err5 = run2(['normalize', '--events', mg, '--out', mo])
except Exception as ex:
    code, out5 = None, f'{type(ex).__name__}: {ex}'
check('normalize merge with a non-int cell exits 1 as still invalid', code == 1 and 'still invalid' in out5 and 'TypeError' not in out5)
# normalize: the malformed cell coming second must not be dropped silently (reversed order, and a non-dict value)
for label, cats in (('reversed', {'ui': {'sonnet': {'steps': 1, 'first_try': 0}}, 'layout': {'sonnet': {'steps': '2', 'first_try': 1}}}),
                    ('non-dict', {'ui': {'sonnet': {'steps': 1, 'first_try': 0}}, 'layout': 'junk'})):
    mg2 = os.path.join(nd, f'merge-{label}.jsonl'); mo2 = os.path.join(nd, f'merge-{label}-out.jsonl')
    with open(mg2, 'w') as f:
        f.write(json.dumps({'ts': TS, 'kind': 'run', 'repo': 'r', 'steps': {'sonnet': 2}, 'first_try': {'sonnet': 1}, 'by_category': cats}) + '\n')
    try:
        code, out6, err6 = run2(['normalize', '--events', mg2, '--out', mo2])
    except Exception as ex:
        code, out6 = None, f'{type(ex).__name__}: {ex}'
    check(f'normalize merge ({label}) keeps the malformed cell and exits 1 as still invalid', code == 1 and 'still invalid' in out6 and 'TypeError' not in out6)

# stats: the skipped note says which lines normalize can fix
ar = tempfile.mkdtemp()
am, aa = os.path.join(ar, 'events.jsonl'), os.path.join(ar, 'events-202610.jsonl.gz')
good = json.dumps({'ts': TS, 'kind': 'run', 'repo': 'r', 'steps': {'sonnet': 1}, 'first_try': {'sonnet': 1}}) + '\n'
badf = json.dumps({'ts': TS, 'kind': 'finding', 'repo': 'r', 'category': 'refactor', 'outcome': 'fixed', 'severity': 'medium'}) + '\n'
open(am, 'w').write(good)
with gzip.open(aa, 'wt') as f:
    f.write(badf)
code, out6 = run(['stats', '--events', am, '--days', '36500000'])
check('archive-only skip note says the lines age out', code == 0 and 'skipped 1 malformed (lines events-202610.jsonl.gz:1)' in out6
      and 'age out' in out6 and 'normalize writes' not in out6)
open(am, 'a').write(badf)
code, out7 = run(['stats', '--events', am, '--days', '36500000'])
check('mixed skip note offers normalize and says archive lines age out', 'normalize writes a fixed copy to review; archive lines age out' in out7)
open(am, 'w').write(good + badf)
os.remove(aa)
code, out8 = run(['stats', '--events', am, '--days', '36500000'])
check('main-file skip note offers normalize only', 'normalize writes a fixed copy to review' in out8 and 'age out' not in out8)

# reason on dismissed findings (#15)
rv = os.path.join(root, 'reason-events.jsonl')
fd = {'kind': 'finding', 'repo': 'r', 'category': 'refactor', 'outcome': 'dismissed', 'severity': 'minor', 'axis': 'standards', 'model': 'opus'}
code, out, err = run2(['event', json.dumps(fd), '--events', rv])
check('event refuses a dismissed finding without reason', code == 2 and 'reason' in err)
code, out, err = run2(['event', json.dumps(dict(fd, reason='nope')), '--events', rv])
check('event refuses an unknown reason', code == 2)
code, out, err = run2(['event', json.dumps(dict(fd, outcome='fixed', reason='wrong')), '--events', rv])
check('event refuses reason on a non-dismissed finding', code == 2)
code, out, err = run2(['event', json.dumps(dict(fd, reason='pre-existing')), '--events', rv])
check('event accepts a dismissed finding with reason', code == 0)
with open(rv, 'a') as f:
    f.write(json.dumps(dict(fd, ts=TS)) + '\n')
    f.write(json.dumps(dict(fd, ts=TS, axis='bugs', reason='wrong')) + '\n')
code, out = run(['stats', '--events', rv, '--days', '36500000'])
check('stats counts a dismissed finding without reason as legacy',
      code == 0 and 'skipped' not in out and '- standards · legacy: 1' in out)
check('stats prints dismissed by axis x reason', '## Dismissed by axis × reason' in out
      and '- standards · pre-existing: 1' in out and '- bugs · wrong: 1' in out)

# phases: session timeline and critical-path attribution
import datetime
ph_base = datetime.datetime(2026, 1, 1, 10, tzinfo=datetime.timezone.utc)
ph_ts = lambda s: (ph_base + datetime.timedelta(seconds=s)).isoformat().replace('+00:00', 'Z')
ph_root = tempfile.mkdtemp(); ph_proj = os.path.join(ph_root, '-tmp-proj'); ph_sid = 'sess-build-1'
os.makedirs(os.path.join(ph_proj, ph_sid, 'subagents'))
def ph_hu(s): return {'type': 'user', 'timestamp': ph_ts(s), 'origin': {'kind': 'human'}, 'message': {'content': 'go'}}
def ph_at(s, x='ok'): return {'type': 'assistant', 'timestamp': ph_ts(s), 'message': {'content': [{'type': 'text', 'text': x}]}}
def ph_au(s, tid, name, **i): return {'type': 'assistant', 'timestamp': ph_ts(s), 'message': {'content': [{'type': 'tool_use', 'id': tid, 'name': name, 'input': i}]}}
def ph_re(s, tid, **r): return {'type': 'user', 'timestamp': ph_ts(s), 'toolUseResult': r, 'message': {'content': [{'type': 'tool_result', 'tool_use_id': tid, 'content': 'x'}]}}
def ph_tn(s, tid): return {'type': 'user', 'timestamp': ph_ts(s), 'origin': {'kind': 'task-notification'}, 'message': {'content': '<task-notification>\n<task-id>t</task-id>\n<tool-use-id>%s</tool-use-id>\n<status>completed</status>\n</task-notification>' % tid}}
def ph_ag(s, tid, t): return [ph_au(s, tid, 'Agent', subagent_type=t, prompt='p'), ph_re(s, tid, isAsync=True, status='async_launched')]
ph_main = [ph_hu(0)] + ph_ag(10, 'tu_plan', 'rumo:planner') + [ph_at(15), ph_tn(620, 'tu_plan'),
    ph_au(630, 'tu_t', 'Bash', command='bash scripts/test-all.sh'), ph_re(690, 'tu_t'),
    ph_au(700, 'tu_a', 'Bash', command="bash skills/rumo/scripts/accept-step.sh . 'x'"), ph_re(720, 'tu_a'),
    ph_au(730, 'tu_v', 'Bash', command='orca exec --command "screenshot /tmp/a.png"'), ph_re(740, 'tu_v'),
    ph_au(750, 'tu_o', 'Bash', command='git status'), ph_re(755, 'tu_o'),
    ph_au(765, 'tu_q', 'AskUserQuestion', questions=[]), ph_re(825, 'tu_q'),
    ph_au(835, 'tu_bg', 'Bash', command='pytest -q', run_in_background=True), ph_re(835, 'tu_bg', backgroundTaskId='bg1'),
    ph_at(840), ph_tn(935, 'tu_bg'), ph_at(940),
    {'type': 'user', 'isMeta': True, 'timestamp': ph_ts(999), 'message': {'content': 'injected'}}, ph_hu(1000)
    ] + ph_ag(1010, 'tu_b1', 'rumo:builder') + ph_ag(1011, 'tu_b2', 'rumo:builder-opus') + [ph_at(1015), ph_tn(1120, 'tu_b1'), ph_tn(1170, 'tu_b2')
    ] + ph_ag(1175, 'tu_b3', 'rumo:builder') + [ph_at(1180), ph_tn(1370, 'tu_b3'), ph_at(1380, 'paused token=abc123def456'), ph_hu(8580)
    ] + ph_ag(8590, 'tu_r1', 'rumo:reviewer') + ph_ag(8591, 'tu_r2', 'rumo:reviewer-sonnet') + [ph_at(8595), ph_tn(8910, 'tu_r2')
    ] + ph_ag(8920, 'tu_r3', 'rumo:reviewer') + [ph_at(8925), ph_tn(9100, 'tu_r3'),
    ph_au(9110, 'tu_pr', 'Bash', command='gh pr create --base master'), ph_re(9112, 'tu_pr'), ph_at(9120)]
ph_path = os.path.join(ph_proj, ph_sid + '.jsonl')
with open(ph_path, 'w') as f:
    f.write('not json\n[1, 2]\n')
    for l in ph_main: f.write(json.dumps(l) + '\n')
for n, k, a, b in (('p', 'rumo:planner', 20, 620), ('b1', 'rumo:builder', 1020, 1120), ('b2', 'rumo:builder-opus', 1070, 1170),
                   ('b3', 'rumo:builder', 1270, 1370), ('r1', 'rumo:reviewer', 8600, 8900),
                   ('r2', 'rumo:reviewer-sonnet', 8610, 8910), ('r3', 'rumo:reviewer', 9000, 9100)):
    with open(os.path.join(ph_proj, ph_sid, 'subagents', 'agent-%s.jsonl' % n), 'w') as f:
        f.write(json.dumps({'type': 'user', 'timestamp': ph_ts(a), 'message': {'content': 'x'}}) + '\n')
        f.write(json.dumps({'type': 'assistant', 'timestamp': ph_ts(b), 'message': {'content': []}}) + '\n')
    json.dump({'agentType': k}, open(os.path.join(ph_proj, ph_sid, 'subagents', 'agent-%s.meta.json' % n), 'w'))
ph_tl = learn.session_timeline(ph_path, -1e15)
ph_attr = learn.attribute_seconds(ph_tl['events'], ph_tl['intervals'])
ph_want = {'user-wait': 60, 'ask-user': 60, 'bash:test': 60, 'bash:accept-step': 20, 'bash:visual': 10, 'bash:other': 7,
           'agent:builder-opus': 100, 'agent:builder': 150, 'agent:planner': 600, 'agent:reviewer': 400,
           'agent:reviewer-sonnet': 10, 'bg:test': 100, 'generation': 163, 'idle': 180, 'suspended': 7200}
check('phases attributes every category to the second', dict(ph_attr['totals']) == ph_want)
check('phases sum covers the span', sum(ph_attr['totals'].values()) == 9120)
check('phases lists the 2 h gap as a hole', len(ph_attr['holes']) == 1 and ph_attr['holes'][0][1] - ph_attr['holes'][0][0] == 7200)
check('phases idle gaps merge', len(ph_attr['idle_gaps']) == 5)
check('phases never puts a secret in a label', not any('abc123def456' in l for _, l in ph_tl['events'])
      and any('token=<redacted>' in l for _, l in ph_tl['events']))
check('phases classifies foreground Bash',
      learn.bash_fg_kind("bash skills/rumo/scripts/accept-step.sh . 'pnpm test'") == 'accept-step'
      and learn.bash_fg_kind('cd x && pnpm --filter a test') == 'test'
      and learn.bash_fg_kind('bash skills/rumo/scripts/visual-lint.sh --project . http://x') == 'visual'
      and learn.bash_fg_kind('git status') == 'other')
check('phases classifies background Bash',
      learn.bash_bg_kind('sleep 30') == 'wait' and learn.bash_bg_kind('gh run watch 1') == 'wait'
      and learn.bash_bg_kind('pytest -q') == 'test' and learn.bash_bg_kind('pnpm dev') == 'other')
ph_u = lambda s, **k: (s, dict({'type': 'user', 'message': {'content': 'p'}}, **k))
ph_a = lambda s: (s, {'type': 'assistant', 'message': {'content': []}})
check('phases splits a resumed subagent',
      learn.subagent_runs([ph_u(0), ph_a(100), ph_u(1000, isMeta=True), ph_a(1100)]) == [(0, 100), (1000, 1100)])
ph_tr = (1000, {'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'x'}]}})
check('phases keeps a run across a long tool call',
      learn.subagent_runs([ph_u(0), ph_a(100), ph_tr, ph_a(1100)]) == [(0, 1100)])

ph_m = learn.session_metrics(ph_tl, ph_attr)
check('phases metrics', ph_m.get('active') == 1740 and ph_m.get('plan') == 620 and ph_m.get('build') == 780
      and ph_m.get('review') == 510 and ph_m.get('max_builders') == 2 and ph_m.get('builder_gaps') == [100]
      and ph_m.get('rounds') == 2 and ph_m.get('stalled') is True)
with open(os.path.join(ph_proj, 'sess-other.jsonl'), 'w') as f:
    for l in (ph_hu(0), ph_at(10)): f.write(json.dumps(l) + '\n')
os.makedirs(os.path.join(ph_proj, 'sess-other', 'subagents'))
with open(os.path.join(ph_proj, 'sess-other', 'subagents', 'agent-g.jsonl'), 'w') as f:
    f.write(json.dumps(ph_hu(1)) + '\n'); f.write(json.dumps(ph_at(5)) + '\n')
json.dump({'agentType': 'general-purpose'}, open(os.path.join(ph_proj, 'sess-other', 'subagents', 'agent-g.meta.json'), 'w'))
ph_code, ph_out = run(['phases', '--root', ph_root, '--days', '36500000'])
ph_heads = ('critical path', 'phases (', 'builder concurrency', 'review rounds', 'stalls')
check('phases prints the five sections', ph_code == 0 and all(h in ph_out for h in ph_heads))
check('phases counts only build sessions', '1 build sessions' in ph_out)
check('phases prints seconds', any('user-wait' in l and '0:01:00' in l for l in ph_out.splitlines())
      and 'suspended, out of the sum: 2:00:00' in ph_out)
check('phases lists the stall with its last event, scrubbed',
      any('sess-bui' in l and '2:03:00' in l and 'last: assistant: paused token=<redacted>' in l for l in ph_out.splitlines())
      and 'abc123def456' not in ph_out)
ph_code2, ph_out2 = run(['phases', '--root', tempfile.mkdtemp(), '--days', '14'])
check('phases with no sessions still prints the sections', ph_code2 == 0 and all(h in ph_out2 for h in ph_heads)
      and '0 build sessions' in ph_out2 and '0:00:00' in ph_out2)
ph_skill = open(os.path.join(here, '..', 'SKILL.md')).read()
check('learn review prints phases', 'learn.py phases --days 14' in ph_skill and 'Print the `phases` block' in ph_skill)

def ph_write(proj, sid, main_lines, subs=()):
    os.makedirs(os.path.join(proj, sid, 'subagents'), exist_ok=True)
    path = os.path.join(proj, sid + '.jsonl')
    with open(path, 'w') as f:
        for l in main_lines: f.write(json.dumps(l) + '\n')
    for n, k, lines in subs:
        with open(os.path.join(proj, sid, 'subagents', 'agent-%s.jsonl' % n), 'w') as f:
            for l in lines: f.write(json.dumps(l) + '\n')
        json.dump({'agentType': k}, open(os.path.join(proj, sid, 'subagents', 'agent-%s.meta.json' % n), 'w'))
    return path
def ph_totals(sid, main_lines, subs=()):
    tl = learn.session_timeline(ph_write(ph_proj, sid, main_lines, subs), -1e15)
    return dict(learn.attribute_seconds(tl['events'], tl['intervals'])['totals'])
ph_hk = ph_totals('sess-hk', [ph_hu(0), ph_at(10),
    {'type': 'system', 'subtype': 'informational', 'timestamp': ph_ts(3300), 'content': 'x'},
    {'type': 'user', 'isCompactSummary': True, 'timestamp': ph_ts(3301), 'message': {'content': 'summary'}},
    ph_hu(3400), ph_at(3410)])
check('phases keeps a user wait across housekeeping lines', ph_hk == {'generation': 20, 'user-wait': 3390})
ph_ao = ph_totals('sess-att', [{'type': 'attachment', 'timestamp': ph_ts(0)}, ph_hu(2000), ph_at(2010)])
check('phases counts the wait for the first prompt', ph_ao == {'user-wait': 2000, 'generation': 10})
ph_rk = ph_totals('sess-rank', [ph_hu(0), ph_au(10, 't1', 'Bash', command='sleep 100', run_in_background=True),
    ph_re(20, 't1', backgroundTaskId='b1'), ph_au(30, 't2', 'Bash', command='pnpm dev', run_in_background=True),
    ph_re(40, 't2', backgroundTaskId='b2'), ph_at(50), ph_tn(220, 't1'), ph_tn(340, 't2'), ph_at(400)],
    [('v', 'rumo:visual-judge', [ph_hu(60), ph_at(120)]), ('g', 'general-purpose', [ph_hu(130), ph_at(170)])])
check('phases ranks agents above background above generation',
      ph_rk == {'generation': 70, 'idle': 10, 'bg:wait': 100, 'agent:visual-judge': 60, 'agent:other': 40, 'bg:other': 120})

# runs_tests: citing a test file is not running it
for ph_c in ('sed -n 1,5p a_test.py', 'cd x && git add a_test.py && git commit -m "pytest"', "cat > b.md <<'EOF'\npnpm test\nEOF",
             'f=src/a.test.ts', 'sed -n 1p jest.config.js'):
    check('phases: not a test run: %r' % ph_c, learn.bash_fg_kind(ph_c) == 'other')
check('phases: git add of a test file is not a bg test', learn.bash_bg_kind('git add a_test.py') == 'other')
for ph_c in ('git add a_test.py && bash tests/a_test.sh', 'FOO=1 bash scripts/test-all.sh 2>&1 | tail -5',
             'for t in tests/*_test.sh; do bash "$t"; done'):
    check('phases: a test run: %r' % ph_c, learn.bash_fg_kind(ph_c) == 'test')

def ph_qo(s, tid, op='enqueue'): return {'type': 'queue-operation', 'operation': op, 'timestamp': ph_ts(s), 'content': ph_tn(s, tid)['message']['content']}
ph_q = [ph_hu(0), ph_au(10, 't1', 'Bash', command='pytest -q', run_in_background=True), ph_re(20, 't1', backgroundTaskId='b1'), ph_at(30)]
check('phases closes a bg task on a queue line alone',
      ph_totals('sess-q1', ph_q + [ph_qo(120, 't1'), ph_at(130)]) == {'generation': 20, 'idle': 10, 'bg:test': 100})
check('phases closes a bg task once when queue and user lines both arrive',
      ph_totals('sess-q2', ph_q + [ph_qo(120, 't1'), ph_qo(121, 't1', 'remove'), ph_tn(122, 't1'), ph_at(130)])
      == {'generation': 18, 'idle': 12, 'bg:test': 100})
check('phases ignores a dequeue line without content',
      ph_totals('sess-q3', ph_q + [{'type': 'queue-operation', 'operation': 'dequeue', 'timestamp': ph_ts(120)}, ph_at(130)])
      == {'generation': 120, 'idle': 10})
check('help.md lists learn.py phases', 'learn.py phases' in open(os.path.join(here, '..', '..', 'rumo', 'references', 'help.md')).read())

# runs_tests: separators inside complete quotes do not split a segment
for ph_c in ('git commit -m "fix: y\n\nTests pass with pytest"', 'git commit -m "fix; pytest"', 'gh pr create --body "a; pytest"'):
    check('phases: quoted text is not a test run: %r' % ph_c, learn.bash_fg_kind(ph_c) == 'other')
for ph_c in ('bash -c "cd x; pytest"', 'bash -c "cd x && bash tests/a_test.sh"', "echo don't; pytest"):
    check('phases: a test run despite quotes: %r' % ph_c, learn.bash_fg_kind(ph_c) == 'test')

# runs_tests: #83 — wrappers, heredocs, comments, escapes, nested scripts, citations
for ph_c in ('if bash tests/a_test.sh; then echo ok; fi', 'elif bash tests/a_test.sh; then :; fi', 'while ! bash tests/a_test.sh; do sleep 1; done',
             'until bash tests/a_test.sh; do :; done', 'nohup bash tests/a_test.sh > log 2>&1', 'caffeinate -i bash scripts/test-all.sh',
             'timeout -k 5 60 bash tests/a_test.sh', 'nice -n 10 bash tests/a_test.sh', 'env -i PATH=/bin bash tests/a_test.sh',
             'time (bash tests/a_test.sh)', 'npx tsx src/a.test.ts', "cat > x.txt <<'EOF' && pytest -q\nbody\nEOF",
             'echo $((1 << 3))\nbash tests/a_test.sh', "bash <<'EOF'\ncd x\npytest -q\nEOF",
             "python3 - <<'EOF'\nimport os\nEOF\nbash tests/a_test.sh", "# don't run this twice\nbash tests/a_test.sh\necho 'x'",
             "echo it\\'s; bash tests/a_test.sh; echo 'x'", 'bash -c "cd x && \\\n bash tests/a_test.sh"',
             'for t in tests/*_test.sh; do bash "$t"; done', 'for f in a_test.py b_test.py; do python3 "${f}"; done',
             'bash -c \'T=skills/x/tests/a_test.sh; bash $T | tail -1\'',
             'bash -c "cd \\"$d\\" && pytest -q"', "bash -c 'echo '\\''x'\\''; pytest'", 'bash -e tests/a_test.sh',
             'for t in tests/*_test.sh; do bash -e "$t"; done'):
    check('phases #83: a test run: %r' % ph_c, learn.bash_fg_kind(ph_c) == 'test')
for ph_c in ('npx eslint src/a.test.tsx', 'for f in tests/*_test.sh; do wc -l "$f"; done', 'bash -n tests/a_test.sh',
             'python3 -m py_compile skills/learn/tests/learn_test.py', 'bash -c "git add a_test.py"',
             'python3 -c "print(open(\'a_test.py\').read())"', "echo x | grep -c '#' a_test.py",
             'git commit -m "fix: x \\\nbash tests/a_test.sh"', 'find tests -name "*_test.sh" -exec bash {} \\;', 'ls tests/*_test.sh | xargs -n1 bash',
             "f=tests/a_test.py; python3 - \"$f\" <<'EOF'\nimport sys\nEOF",
             "cat > a_test.py <<EOF\nimport os\nbash tests/b_test.sh\nEOF"):
    check('phases #83: not a test run: %r' % ph_c, learn.bash_fg_kind(ph_c) == 'other')

# phases #106: wave orchestrators out of the build set, launcher-wait, work in flight outranks user-wait, owner touches
def ph_ht(s, text): return dict(ph_hu(s), message={'content': text})
ph_root2 = tempfile.mkdtemp(); ph_proj2 = os.path.join(ph_root2, '-tmp-proj2')
ph_b1 = [('b', 'rumo:builder', [ph_hu(20), ph_at(120)])]
ph_run = lambda first: [first] + ph_ag(10, 'tu_b', 'rumo:builder') + [ph_at(15), ph_tn(120, 'tu_b'), ph_at(130)]
ph_write(ph_proj2, 'sess-wave-typed', ph_run(ph_ht(0, ' /rumo wave 421 412')), ph_b1)
ph_write(ph_proj2, 'sess-wave-cmd', ph_run(ph_ht(0, '<command-message>rumo:rumo</command-message>\n'
    '<command-name>/rumo:rumo</command-name>\n<command-args>wave #6 #8</command-args>')), ph_b1)
ph_write(ph_proj2, 'sess-wave-queued', ph_run({'type': 'attachment', 'timestamp': ph_ts(0),
    'attachment': {'type': 'queued_command', 'prompt': '/rumo wave #9'}}), ph_b1)
ph_write(ph_proj2, 'sess-wave-skill', [ph_hu(0), ph_au(5, 'tu_s', 'Skill', skill='rumo', args='wave #6 #8'), ph_re(6, 'tu_s')]
    + ph_ag(10, 'tu_b', 'rumo:builder') + [ph_at(15), ph_tn(120, 'tu_b'), ph_at(130)], ph_b1)
# a lane (`/rumo build` under a WAVE BRIEF) and a session that only mentions the command stay builds
ph_write(ph_proj2, 'sess-lane', ph_run(ph_ht(0, '/rumo build #7\nLAUNCHED-BY: wave w1\nWAVE BRIEF: /x/w1.md — read it first.')), ph_b1)
ph_touch = ph_write(ph_proj2, 'sess-touch', ph_run(ph_ht(0, 'sei que existe o /rumo wave, mas roda o build')) + [
    ph_hu(200), ph_at(210), ph_ht(250, 'AUTHORIZED: "pode mergear" (wave w1)'), ph_at(260), ph_hu(300), ph_at(310),
    ph_ht(350, 'Orquestrador: status?'), ph_at(360), ph_hu(400), ph_at(410),
    ph_ht(420, '<bash-stdout>ok</bash-stdout>'), ph_at(430)], ph_b1)
ph_code3, ph_out3 = run(['phases', '--root', ph_root2, '--days', '36500000'])
ph_l3 = ph_out3.splitlines()
check('phases #106: a /rumo wave session with a builder run is not a build session', ph_code3 == 0 and '2 build sessions' in ph_l3[0])
check('phases #106: wave orchestrators line sits under the header',
      len(ph_l3) > 1 and ph_l3[1] == 'wave orchestrators, out of the build set: 4 sessions · 0:08:09 active')
check('phases #106: no wave orchestrator prints a zero line',
      'wave orchestrators, out of the build set: 0 sessions · 0:00:00 active' in ph_out.splitlines()[1]
      and 'wave orchestrators, out of the build set: 0 sessions · 0:00:00 active' in ph_out2.splitlines()[1])
check('phases #106: a launch prompt ends a launcher-wait, not a user-wait',
      ph_totals('sess-lw1', [ph_at(0), ph_ht(600, 'LAUNCHED-BY: wave x\nCONTINUE'), ph_at(610)]) == {'launcher-wait': 600, 'generation': 10})
check('phases #106: a bare PAUSA relay ends a launcher-wait',
      ph_totals('sess-lw2', [ph_at(0), ph_ht(600, 'PAUSA — machine load high'), ph_at(610)]) == {'launcher-wait': 600, 'generation': 10})
def ph_lm(t):
    try: return learn.is_launcher_message(t)
    except NotImplementedError: return None
for ph_c in ('<command-message>rumo:rumo</command-message>\n<command-name>/rumo:rumo</command-name>\n<command-args>build #1\nWAVE BRIEF: /x.md',
             '<command-args>AUTHORIZED: "autorizo"', 'CONTINUE — normal load', 'Orquestrador: proceed', '  WAVE BRIEF: /x.md'):
    check('phases #106: a launcher message: %r' % ph_c, ph_lm(ph_c) is True)
for ph_c in ('go', 'pausa aí', 'continue', 'o AUTHORIZED: do brief', 'Orquestrador da wave, me diz', ''):
    check('phases #106: an owner message: %r' % ph_c, ph_lm(ph_c) is False)
check('phases #106: a Bash still running when the owner writes keeps its seconds',
      ph_totals('sess-fly1', [ph_hu(0), ph_au(10, 't', 'Bash', command='git fetch --all'), ph_hu(370), ph_re(610, 't'), ph_at(620)])
      == {'generation': 20, 'bash:other': 600})
check('phases #106: a subagent or bg task running when the owner writes keeps its seconds',
      ph_totals('sess-fly2', [ph_hu(0)] + ph_ag(10, 'tu_b', 'rumo:builder') + [ph_at(15),
          ph_au(16, 't1', 'Bash', command='pnpm dev', run_in_background=True), ph_re(17, 't1', backgroundTaskId='b1'), ph_at(18),
          ph_hu(400), ph_at(410), ph_tn(500, 't1'), ph_at(510), ph_hu(600), ph_at(610)], ph_b1)
      == {'generation': 36, 'agent:builder': 100, 'bg:other': 383, 'user-wait': 90, 'idle': 1})
check('phases #106: a pending AskUserQuestion still outranks running work',
      ph_totals('sess-fly3', [ph_hu(0), ph_au(10, 't1', 'Bash', command='pnpm dev', run_in_background=True),
          ph_re(11, 't1', backgroundTaskId='b1'), ph_au(20, 'q', 'AskUserQuestion', questions=[]), ph_re(80, 'q'), ph_tn(100, 't1'), ph_at(110)])
      == {'generation': 20, 'ask-user': 60, 'bg:other': 29, 'idle': 1})
ph_tl3 = learn.session_timeline(ph_touch, -1e15)
ph_m3 = learn.session_metrics(ph_tl3, learn.attribute_seconds(ph_tl3['events'], ph_tl3['intervals']))
check('phases #106: owner touches leave out launcher and machine messages and the ones before the build started',
      ph_m3.get('owner_touches') == 3 and ph_tl3.get('wave') is False)
ph_cp = next((i for i, l in enumerate(ph_l3) if l.startswith('  suspended, out of the sum')), -99)
check('phases #106: prints owner touches after the critical path',
      ph_l3[ph_cp + 1:ph_cp + 3] == ['owner touches per build: p50 3 · p90 3', 'builds with zero owner touches after start: 1/2'])
check('phases #106: launcher-wait reaches the critical path', any(l.endswith('launcher-wait') and '0:01:20' in l for l in ph_l3))

sys.exit(1 if fails else 0)
