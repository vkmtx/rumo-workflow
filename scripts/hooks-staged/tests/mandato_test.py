"""Unit tests for mandato.py: the host-written, signed Mandato that bounds a lane's authority (#98).
Run: python3 -I scripts/hooks-staged/tests/mandato_test.py"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MOD_DIR = os.path.join(HERE, '..')
sys.path.insert(0, MOD_DIR)
import mandato as md  # noqa: E402

CLI = os.path.join(MOD_DIR, 'mandato.py')
BRANCH = 'feat/98-x'


def git_init(d, branch=BRANCH):
    subprocess.run(['git', 'init', '-q', '-b', branch, d], check=True)


class Base(unittest.TestCase):
    def setUp(self):
        self._env = dict(os.environ)
        os.environ['GIT_CONFIG_GLOBAL'] = '/dev/null'
        os.environ['GIT_CONFIG_NOSYSTEM'] = '1'
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix='mandato-'))
        self.repo = os.path.join(self.tmp, 'repo')
        git_init(self.repo)
        self.keyfile = os.path.join(self.tmp, 'mandato.key')
        with open(self.keyfile, 'wb') as f:
            f.write(os.urandom(32).hex().encode() + b'\n')
        os.environ['RUMO_MANDATO_KEY'] = self.keyfile
        self.gitdir = os.path.join(self.repo, '.git')
        self.mfile = os.path.join(self.gitdir, md.FILE)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self._env)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def key(self):
        with open(self.keyfile, 'rb') as f:
            return f.read().strip()

    def mandato(self, **over):
        m = {'v': 1, 'politica': 'abc1234', 'repo': 'vkmtx/rumo', 'issue': 98, 'forca': 'explicito',
             'pediu': 'owner', 'aprovou': 'owner', 'fonte': 'github', 'alcance': 'pr',
             'worktree': self.repo, 'branch': BRANCH, 'emitido': '2026-11-10T06:00:00Z'}
        m.update(over)
        m['assinatura'] = md.sign(m, self.key())
        return m

    def write(self, m, raw=None):
        with open(self.mfile, 'w', encoding='utf-8') as f:
            f.write(raw if raw is not None else json.dumps(m))

    def cli(self, *args):
        return subprocess.run([sys.executable, '-I', CLI] + list(args), capture_output=True, text=True,
                              env=os.environ.copy())


class Constants(unittest.TestCase):
    def test_constants(self):
        self.assertEqual(md.FILE, 'rumo-mandato.json')
        self.assertEqual(md.KEY_ENV, 'RUMO_MANDATO_KEY')
        self.assertEqual(md.FORCAS, ('explicito', 'inferido'))
        self.assertEqual(md.FONTES, ('github', 'zulip'))
        self.assertEqual(md.ALCANCES, ('pr', 'merge'))

    def test_canonical_drops_signature_and_sorts(self):
        self.assertEqual(md.canonical({'b': 1, 'a': 'é', 'assinatura': 'x'}), '{"a":"é","b":1}'.encode('utf-8'))


class Check(Base):
    def test_path_is_in_git_dir(self):
        self.assertEqual(os.path.realpath(md.path(self.repo)), os.path.realpath(self.mfile))

    def test_path_outside_git_is_none(self):
        self.assertIsNone(md.path(self.tmp))

    def test_absent(self):
        self.assertEqual(md.check(self.repo), ('absent', None, ''))

    def test_absent_outside_git(self):
        self.assertEqual(md.check(self.tmp), ('absent', None, ''))

    def test_valid_round_trip(self):
        m = self.mandato()
        self.write(m)
        self.assertEqual(md.check(self.repo), ('valid', m, ''))

    def test_valid_from_subdir(self):
        sub = os.path.join(self.repo, 'sub')
        os.mkdir(sub)
        self.write(self.mandato(alcance='merge'))
        st, m, _ = md.check(sub)
        self.assertEqual((st, m['alcance']), ('valid', 'merge'))

    def test_tampered_field(self):
        m = self.mandato(alcance='pr')
        m['alcance'] = 'merge'
        self.write(m)
        self.assertEqual(md.check(self.repo), ('refused', None, 'signature'))

    def test_signed_with_other_key(self):
        m = self.mandato()
        m['assinatura'] = md.sign(m, b'other-key')
        self.write(m)
        self.assertEqual(md.check(self.repo)[2], 'signature')

    def test_other_worktree(self):
        other = os.path.join(self.tmp, 'other')
        git_init(other)
        self.write(self.mandato(worktree=other))
        self.assertEqual(md.check(self.repo), ('refused', None, 'worktree'))

    def test_copied_into_other_repo(self):
        other = os.path.join(self.tmp, 'other')
        git_init(other)
        with open(os.path.join(other, '.git', md.FILE), 'w') as f:
            json.dump(self.mandato(), f)
        self.assertEqual(md.check(other), ('refused', None, 'worktree'))

    def test_other_branch(self):
        self.write(self.mandato(branch='feat/other'))
        self.assertEqual(md.check(self.repo), ('refused', None, 'branch'))

    def test_missing_key(self):
        self.write(self.mandato())
        os.environ['RUMO_MANDATO_KEY'] = os.path.join(self.tmp, 'nope.key')
        self.assertEqual(md.check(self.repo), ('refused', None, 'no-key'))

    def test_empty_key(self):
        self.write(self.mandato())
        with open(self.keyfile, 'w') as f:
            f.write('  \n')
        self.assertEqual(md.check(self.repo), ('refused', None, 'no-key'))

    def test_malformed_json(self):
        self.write(None, raw='{"v": 1,')
        self.assertEqual(md.check(self.repo), ('refused', None, 'malformed'))

    def test_not_an_object(self):
        self.write(None, raw='[1, 2]')
        self.assertEqual(md.check(self.repo), ('refused', None, 'malformed'))

    def test_bad_forca(self):
        self.write(self.mandato(forca='talvez'))
        self.assertEqual(md.check(self.repo), ('refused', None, 'field forca'))

    def test_missing_field(self):
        m = self.mandato()
        del m['pediu']
        self.write(m)
        self.assertEqual(md.check(self.repo), ('refused', None, 'field pediu'))

    def test_wrong_types(self):
        cases = {'v': 2, 'issue': 0, 'repo': 'rumo', 'worktree': 'rel/path', 'fonte': 'slack',
                 'alcance': 'deploy', 'emitido': 'ontem', 'politica': ''}
        for name, bad in cases.items():
            with self.subTest(field=name):
                self.write(self.mandato(**{name: bad}))
                self.assertEqual(md.check(self.repo), ('refused', None, 'field ' + name))

    def test_bool_is_not_int(self):
        self.write(self.mandato(issue=True))
        self.assertEqual(md.check(self.repo), ('refused', None, 'field issue'))

    def test_bad_signature_shape(self):
        m = self.mandato()
        m['assinatura'] = 'zz'
        self.write(m)
        self.assertEqual(md.check(self.repo), ('refused', None, 'field assinatura'))

    def test_symlink(self):
        real = os.path.join(self.tmp, 'real.json')
        with open(real, 'w') as f:
            json.dump(self.mandato(), f)
        os.symlink(real, self.mfile)
        self.assertEqual(md.check(self.repo), ('refused', None, 'symlink'))

    def test_directory_is_not_regular(self):
        os.mkdir(self.mfile)
        self.assertEqual(md.check(self.repo), ('refused', None, 'not-a-file'))

    def test_fifo_is_not_regular(self):
        os.mkfifo(self.mfile)
        self.assertEqual(md.check(self.repo), ('refused', None, 'not-a-file'))

    def test_branch_with_whitespace_refused(self):
        for bad in (BRANCH + '\n', ' ' + BRANCH, 'feat/a b', 'feat/a\tb', 'feat/a\x7fb'):
            with self.subTest(branch=bad):
                self.write(self.mandato(branch=bad))
                self.assertEqual(md.check(self.repo), ('refused', None, 'field branch'))


class Cli(Base):
    def test_absent_exit_3(self):
        r = self.cli('check', self.repo)
        self.assertEqual((r.returncode, r.stdout.strip()), (3, 'MANDATO absent'))

    def test_valid_exit_0(self):
        self.write(self.mandato(alcance='merge'))
        r = self.cli('check', self.repo)
        self.assertEqual((r.returncode, r.stdout.strip()), (0, 'MANDATO valid alcance=merge issue=98'))

    def test_refused_exit_1(self):
        m = self.mandato()
        m['issue'] = 99
        self.write(m)
        r = self.cli('check', self.repo)
        self.assertEqual((r.returncode, r.stdout.strip()), (1, 'MANDATO refused signature'))

    def test_check_defaults_to_cwd(self):
        r = subprocess.run([sys.executable, '-I', CLI, 'check'], capture_output=True, text=True,
                           cwd=self.repo, env=os.environ.copy())
        self.assertEqual(r.returncode, 3)

    def test_sign_then_check(self):
        m = self.mandato()
        del m['assinatura']
        src = os.path.join(self.tmp, 'in.json')
        with open(src, 'w') as f:
            json.dump(m, f)
        r = self.cli('sign', '--key', self.keyfile, src)
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertRegex(out['assinatura'], '^[0-9a-f]{64}$')
        self.write(out)
        self.assertEqual(md.check(self.repo)[0], 'valid')

    def test_sign_missing_field_exit_2(self):
        m = self.mandato()
        del m['assinatura'], m['branch']
        src = os.path.join(self.tmp, 'in.json')
        with open(src, 'w') as f:
            json.dump(m, f)
        self.assertEqual(self.cli('sign', '--key', self.keyfile, src).returncode, 2)

    def test_sign_trailing_newline_exit_2(self):
        m = self.mandato()
        del m['assinatura']
        m['repo'] = 'o/r\n'
        src = os.path.join(self.tmp, 'in.json')
        with open(src, 'w') as f:
            json.dump(m, f)
        self.assertEqual(self.cli('sign', '--key', self.keyfile, src).returncode, 2)

    def test_sign_branch_whitespace_exit_2_names_field(self):
        for bad in (BRANCH + '\n', ' ' + BRANCH, BRANCH + ' ', 'feat/a b', 'feat/a\x00b'):
            with self.subTest(branch=bad):
                m = self.mandato()
                del m['assinatura']
                m['branch'] = bad
                src = os.path.join(self.tmp, 'in.json')
                with open(src, 'w') as f:
                    json.dump(m, f)
                r = self.cli('sign', '--key', self.keyfile, src)
                self.assertEqual((r.returncode, r.stdout), (2, ''))
                self.assertIn('branch', r.stderr)

    def test_check_trailing_newline_refused(self):
        m = self.mandato()
        m['assinatura'] = m['assinatura'] + '\n'
        self.write(m)
        self.assertEqual(md.check(self.repo)[0], 'refused')

    def test_usage_exit_2(self):
        self.assertEqual(self.cli().returncode, 2)
        self.assertEqual(self.cli('sign', 'x.json').returncode, 2)
        self.assertEqual(self.cli('bogus').returncode, 2)


if __name__ == '__main__':
    unittest.main()
