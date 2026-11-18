"""inbox_test — sessions waiting on the owner (inbox.py). Run: python3 -I skills/rumo/tests/inbox_test.py"""
import datetime
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, '..', 'scripts', 'inbox.py')
sys.path.insert(0, os.path.join(HERE, '..', 'scripts'))
import relatorio  # noqa: E402

PROJ = '-Users-dev-orca-workspaces-rumo-98-mandato'


def ts(minutes_ago):
    t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=minutes_ago)
    return t.strftime('%Y-%m-%dT%H:%M:%S.000Z')


def text_entry(kind, text, ago, **extra):
    e = {'type': kind, 'timestamp': ts(ago), 'message': {'role': kind, 'content': [{'type': 'text', 'text': text}]}}
    e.update(extra)
    return e


def user(text, ago):
    return {'type': 'user', 'timestamp': ts(ago), 'message': {'role': 'user', 'content': text}}


def asst(text, ago, **extra):
    return text_entry('assistant', text, ago, **extra)


def tool_use(tid, name, inp, ago):
    return {'type': 'assistant', 'timestamp': ts(ago),
            'message': {'role': 'assistant', 'content': [{'type': 'tool_use', 'id': tid, 'name': name, 'input': inp}]}}


def tool_result(tid, ago):
    return {'type': 'user', 'timestamp': ts(ago),
            'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': tid, 'content': 'ok'}]}}


def rel(**kw):
    d = {'estado': 'progress', 'issue': None, 'pr': None, 'merged': False, 'motivo': None, 'pergunta': None}
    d.update(kw)
    assert not relatorio.validate(d), relatorio.validate(d)
    return relatorio.line(d)


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def session(self, sid, entries, proj=PROJ, raw=None, age_days=0):
        d = os.path.join(self.root, proj)
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, sid + '.jsonl')
        with open(p, 'w', encoding='utf-8') as f:
            for e in entries:
                f.write(json.dumps(e, ensure_ascii=False) + '\n')
            for r in raw or []:
                f.write(r + '\n')
        if age_days:
            t = time.time() - age_days * 86400
            os.utime(p, (t, t))
        return p

    def run_cli(self, *args):
        r = subprocess.run([sys.executable, '-I', SCRIPT, '--root', self.root] + list(args),
                           capture_output=True, text=True, encoding='utf-8')
        return r

    def rows(self, *args):
        r = self.run_cli('--json', *args)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)

    def states(self):
        return {row['session']: row['state'] for row in self.rows()}


class States(Base):
    def test_question(self):
        self.session('aaaaaaaa-1', [
            user('go', 30), tool_use('t1', 'AskUserQuestion', {'questions': [{'question': 'Which seam?\nline 2', 'options': []}]}, 20)])
        rows = self.rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['state'], 'question')
        self.assertEqual(rows[0]['pergunta'], 'Which seam? line 2')

    def test_answered_question_not_listed(self):
        self.session('aaaaaaaa-1', [
            tool_use('t1', 'AskUserQuestion', {'questions': [{'question': 'Which?'}]}, 30),
            tool_result('t1', 25), asst('seguindo', 20)])
        self.assertEqual(self.rows(), [])

    def test_waiting(self):
        self.session('bbbbbbbb-1', [
            user('go', 30), asst('summary\n' + rel(estado='waiting', issue=98, pergunta='Approve the seam?') + '\nNEXT: keep-open until answer', 20)])
        rows = self.rows()
        self.assertEqual([r['state'] for r in rows], ['waiting'])
        self.assertEqual(rows[0]['pergunta'], 'Approve the seam?')
        self.assertEqual(rows[0]['issue'], 98)

    def test_blocked_and_failed(self):
        self.session('cccccccc-1', [asst(rel(estado='blocked', issue=7, motivo='gate', pergunta='Release?'), 20)])
        self.session('dddddddd-1', [asst(rel(estado='failed', issue=8, motivo='tests'), 10)])
        rows = {r['session']: r for r in self.rows()}
        self.assertEqual(rows['cccccccc']['state'], 'blocked')
        self.assertIn('gate', rows['cccccccc']['pergunta'])
        self.assertIn('Release?', rows['cccccccc']['pergunta'])
        self.assertEqual(rows['dddddddd']['state'], 'failed')
        self.assertEqual(rows['dddddddd']['pergunta'], 'tests')
        self.assertEqual(rows['dddddddd']['issue'], 8)

    def test_ready_not_listed(self):
        self.session('eeeeeeee-1', [asst(rel(estado='ready', issue=98, pr='https://github.com/vkmtx/rumo/pull/1') + '\nNEXT: clear', 20)])
        self.assertEqual(self.rows(), [])

    def test_progress_and_dropped_not_listed(self):
        self.session('eeeeeeee-1', [asst(rel(estado='progress'), 20)])
        self.session('eeeeeeee-2', [asst(rel(estado='dropped'), 20)])
        self.assertEqual(self.rows(), [])

    def test_error_flag(self):
        self.session('ffffffff-1', [user('go', 30), asst('Rate limited', 20, isApiErrorMessage=True)])
        self.assertEqual(self.states(), {'ffffffff': 'error'})

    def test_error_text_prefix(self):
        self.session('ffffffff-1', [user('go', 30), asst('API Error: 529 overloaded', 20)])
        rows = self.rows()
        self.assertEqual(rows[0]['state'], 'error')
        self.assertTrue(rows[0]['pergunta'].startswith('API Error'))

    def test_keep_open(self):
        self.session('99999999-1', [asst('done\n\nNEXT: keep-open until PR 98 merges\n', 20)])
        rows = self.rows()
        self.assertEqual(rows[0]['state'], 'keep-open')
        self.assertEqual(rows[0]['pergunta'], 'PR 98 merges')

    def test_next_clear_not_listed(self):
        self.session('99999999-1', [asst('done\nNEXT: clear', 20)])
        self.assertEqual(self.rows(), [])

    def test_answered_and_working_not_listed(self):
        self.session('88888888-1', [
            asst(rel(estado='waiting', pergunta='Approve?') + '\nNEXT: keep-open until answer', 30),
            user('aprovado', 10)])
        self.assertEqual(self.rows(), [])

    def test_question_precedes_relatorio(self):
        self.session('77777777-1', [
            asst(rel(estado='failed', motivo='tests'), 30),
            tool_use('t9', 'AskUserQuestion', {'questions': [{'question': 'E agora?'}]}, 10)])
        self.assertEqual(self.states(), {'77777777': 'question'})

    def test_issue_from_branch_when_no_relatorio(self):
        self.session('66666666-1', [asst('x\nNEXT: keep-open until y', 20, gitBranch='feat/98-mandato')])
        self.assertEqual(self.rows()[0]['issue'], 98)


class Selection(Base):
    def test_old_file_not_listed(self):
        self.session('11111111-1', [asst('NEXT: keep-open until x', 20)], age_days=5)
        self.session('22222222-1', [asst('NEXT: keep-open until x', 20)])
        self.assertEqual(self.states(), {'22222222': 'keep-open'})
        self.assertEqual(len(self.rows('--days', '10')), 2)

    def test_subagents_ignored(self):
        self.session('33333333-1', [asst('NEXT: keep-open until x', 20)])
        d = os.path.join(self.root, PROJ, '33333333-1', 'subagents')
        os.makedirs(d)
        with open(os.path.join(d, 'agent-1.jsonl'), 'w') as f:
            f.write(json.dumps(asst('NEXT: keep-open until x', 20)) + '\n')
        self.assertEqual(len(self.rows()), 1)

    def test_corrupt_line_skipped(self):
        self.session('44444444-1', [asst('NEXT: keep-open until x', 20)], raw=['{not json', '', '[1,2]'])
        self.assertEqual(self.states(), {'44444444': 'keep-open'})

    def test_missing_root_is_empty(self):
        r = subprocess.run([sys.executable, '-I', SCRIPT, '--root', os.path.join(self.root, 'nope'), '--json'],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(json.loads(r.stdout), [])


class Output(Base):
    def test_sorted_oldest_first(self):
        self.session('aaaaaaaa-1', [asst('NEXT: keep-open until a', 60)])
        self.session('bbbbbbbb-1', [asst('NEXT: keep-open until b', 300)])
        self.session('cccccccc-1', [asst('NEXT: keep-open until c', 10)])
        self.assertEqual([r['session'] for r in self.rows()], ['bbbbbbbb', 'aaaaaaaa', 'cccccccc'])

    def test_json_shape(self):
        self.session('abcdef12-3456', [asst(rel(estado='waiting', issue=5, pergunta='Ok?'), 192)])
        row = self.rows()[0]
        self.assertEqual(set(row), {'age', 'age_seconds', 'state', 'project', 'session', 'issue', 'pergunta'})
        self.assertEqual(row['project'], 'orca-workspaces-rumo-98-mandato')
        self.assertEqual(row['session'], 'abcdef12')
        self.assertEqual(row['age'], '3h12m')
        self.assertTrue(abs(row['age_seconds'] - 192 * 60) < 120)

    def test_text_rows_and_summary(self):
        self.session('abcdef12-3456', [asst(rel(estado='waiting', issue=5, pergunta='Ok?'), 192)])
        self.session('12345678-0000', [tool_use('t1', 'AskUserQuestion', {'questions': [{'question': 'x' * 300}]}, 5)])
        self.session('99999999-0000', [asst('NEXT: keep-open until z', 1)], proj='-Users-dev-other')
        r = self.run_cli()
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        self.assertEqual(len(lines), 4)
        self.assertEqual(lines[0], '3h12m waiting orca-workspaces-rumo-98-mandato abcdef12 #5 — Ok?')
        self.assertTrue(lines[1].startswith('5m question orca-workspaces-rumo-98-mandato 12345678 - — x'), lines[1])
        self.assertLessEqual(len(lines[1].split(' — ', 1)[1]), 160)
        self.assertTrue(lines[2].startswith('1m keep-open other 99999999 - — z'), lines[2])
        self.assertEqual(lines[3], 'inbox: 3 waiting (1 question, 1 waiting, 1 keep-open)')

    def test_empty_summary(self):
        r = self.run_cli()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), 'inbox: 0 waiting')

    def test_bad_args_exit_2(self):
        self.assertEqual(self.run_cli('--days', 'abc').returncode, 2)
        self.assertEqual(self.run_cli('--nope').returncode, 2)


if __name__ == '__main__':
    unittest.main()
