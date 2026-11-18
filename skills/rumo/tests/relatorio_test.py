"""relatorio_test — the RELATÓRIO line emitter/parser (#98). Run: python3 -I skills/rumo/tests/relatorio_test.py"""
import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, '..', 'scripts', 'relatorio.py')
sys.path.insert(0, os.path.join(HERE, '..', 'scripts'))

PR = 'https://github.com/vkmtx/rumo/pull/101'


def cli(*args, stdin=None):
    return subprocess.run([sys.executable, '-I', SCRIPT] + list(args), input=stdin,
                          capture_output=True, text=True, encoding='utf-8')


def emit(*args):
    return cli('emit', *args)


class RoundTrip(unittest.TestCase):
    CASES = {
        'progress': ['--estado', 'progress', '--issue', '98'],
        'waiting': ['--estado', 'waiting', '--issue', '98', '--pergunta', 'Approve the Mandato seam?'],
        'ready': ['--estado', 'ready', '--issue', '98', '--pr', PR],
        'blocked': ['--estado', 'blocked', '--issue', '98', '--motivo', 'gate', '--pergunta', 'Approve?'],
        'failed': ['--estado', 'failed', '--issue', '98', '--motivo', 'tests'],
        'dropped': ['--estado', 'dropped'],
    }

    def test_each_estado_round_trips(self):
        for estado, args in self.CASES.items():
            with self.subTest(estado=estado):
                e = emit(*args)
                self.assertEqual(e.returncode, 0, e.stderr)
                line = e.stdout.strip()
                self.assertTrue(line.startswith('RELATÓRIO: '), line)
                p = cli('parse', stdin=line + '\n')
                self.assertEqual(p.returncode, 0, p.stderr)
                d = json.loads(p.stdout)
                self.assertEqual(d['estado'], estado)
                self.assertEqual(json.loads(line[len('RELATÓRIO: '):]), d)

    def test_key_order_and_compact(self):
        e = emit('--estado', 'blocked', '--issue', '98', '--motivo', 'gate', '--pergunta', 'Approve the Mandato seam?')
        self.assertEqual(
            e.stdout.strip(),
            'RELATÓRIO: {"estado":"blocked","issue":98,"pr":null,"merged":false,"motivo":"gate",'
            '"pergunta":"Approve the Mandato seam?"}')

    def test_merged_with_pr(self):
        e = emit('--estado', 'ready', '--issue', '98', '--pr', PR, '--merged')
        self.assertEqual(e.returncode, 0, e.stderr)
        self.assertIn('"merged":true', e.stdout)


class Invalid(unittest.TestCase):
    def assertRefused(self, *args):
        e = emit(*args)
        self.assertEqual(e.returncode, 2, e.stdout + e.stderr)
        self.assertEqual(e.stdout, '')
        self.assertTrue(e.stderr.strip())

    def test_blocked_needs_motivo(self):
        self.assertRefused('--estado', 'blocked')

    def test_failed_needs_motivo(self):
        self.assertRefused('--estado', 'failed')

    def test_waiting_needs_pergunta(self):
        self.assertRefused('--estado', 'waiting')

    def test_merged_needs_pr(self):
        self.assertRefused('--estado', 'ready', '--merged')

    def test_bad_pr_url(self):
        self.assertRefused('--estado', 'ready', '--pr', 'https://example.com/pull/1')
        self.assertRefused('--estado', 'ready', '--pr', PR + '/files')

    def test_newline_in_pergunta(self):
        self.assertRefused('--estado', 'waiting', '--pergunta', 'a\nb')

    def test_long_pergunta(self):
        self.assertRefused('--estado', 'waiting', '--pergunta', 'x' * 501)

    def test_whitespace_in_pr_owner_or_repo(self):
        import relatorio
        for bad in ('https://github.com/o wner/rumo/pull/1', 'https://github.com/vkmtx/ru\nmo/pull/1',
                    'https://github.com/vk\tmtx/rumo/pull/1', 'https://github.com/vkmtx/rumo\n/pull/1'):
            with self.subTest(pr=bad):
                self.assertRefused('--estado', 'ready', '--pr', bad)
                self.assertTrue(relatorio.validate({'estado': 'ready', 'issue': None, 'pr': bad, 'merged': False,
                                                    'motivo': None, 'pergunta': None}))

    def test_trailing_newline_pr(self):
        self.assertRefused('--estado', 'ready', '--pr', PR + '\n')

    def test_trailing_newline_motivo(self):
        self.assertRefused('--estado', 'blocked', '--motivo', 'gate\n')

    def test_bad_estado(self):
        self.assertRefused('--estado', 'done')

    def test_bad_motivo(self):
        self.assertRefused('--estado', 'blocked', '--motivo', 'Open Finding')

    def test_bad_issue(self):
        self.assertRefused('--estado', 'progress', '--issue', '0')


class Validate(unittest.TestCase):
    def base(self, **kw):
        d = {'estado': 'progress', 'issue': None, 'pr': None, 'merged': False, 'motivo': None, 'pergunta': None}
        d.update(kw)
        return d

    def test_ok(self):
        import relatorio
        self.assertEqual(relatorio.validate(self.base()), [])

    def test_extra_key(self):
        import relatorio
        self.assertTrue(relatorio.validate(self.base(extra=1)))

    def test_missing_key(self):
        import relatorio
        d = self.base()
        del d['pr']
        self.assertTrue(relatorio.validate(d))

    def test_bool_is_not_issue(self):
        import relatorio
        self.assertTrue(relatorio.validate(self.base(issue=True)))

    def test_not_a_dict(self):
        import relatorio
        self.assertTrue(relatorio.validate([]))

    def test_merged_must_be_bool(self):
        import relatorio
        self.assertTrue(relatorio.validate(self.base(merged='yes')))


class Parse(unittest.TestCase):
    def test_last_line_wins_and_next_ignored(self):
        a = emit('--estado', 'progress', '--issue', '98').stdout
        b = emit('--estado', 'ready', '--issue', '98', '--pr', PR).stdout
        p = cli('parse', stdin='DONE: x\n' + a + 'PENDING: nada\n' + b + 'NEXT: clear\n')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout)['estado'], 'ready')

    def test_none_exits_1(self):
        p = cli('parse', stdin='DONE: x\nNEXT: clear\n')
        self.assertEqual(p.returncode, 1)

    def test_invalid_last_line_exits_1(self):
        a = emit('--estado', 'progress').stdout
        p = cli('parse', stdin=a + 'RELATÓRIO: {"estado":"blocked"}\n')
        self.assertEqual(p.returncode, 1)

    def test_non_utf8_byte_before_a_valid_line(self):
        a = emit('--estado', 'ready', '--issue', '98', '--pr', PR).stdout.encode('utf-8')
        p = subprocess.run([sys.executable, '-I', SCRIPT, 'parse'], input=b'log \xff\xfe bytes\n' + a,
                           capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout.decode('utf-8'))['estado'], 'ready')

    def test_non_utf8_only_exits_1(self):
        p = subprocess.run([sys.executable, '-I', SCRIPT, 'parse'], input=b'\xff\xfe\n', capture_output=True)
        self.assertEqual((p.returncode, p.stderr), (1, b''))

    def test_garbage_json_exits_1(self):
        p = cli('parse', stdin='RELATÓRIO: {nope\n')
        self.assertEqual(p.returncode, 1)


if __name__ == '__main__':
    unittest.main(verbosity=1)
