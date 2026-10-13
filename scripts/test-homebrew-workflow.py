#!/usr/bin/env python3
"""Exercise the workflow's release validation without network access."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class ReleaseValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workflow = Path(__file__).resolve().parents[1] / '.github/workflows/homebrew.yml'
        cls.script = subprocess.check_output([
            'ruby', '-ryaml', '-e',
            'puts YAML.load_file(ARGV[0]).fetch("jobs").fetch("update-tap").fetch("steps").find { |step| step["id"] == "release" }.fetch("run")',
            str(workflow),
        ], text=True)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.dmg = self.root / 'fixture.dmg'
        self.dmg.write_bytes(b'release fixture')
        self.sha256 = hashlib.sha256(self.dmg.read_bytes()).hexdigest()
        self.release = {
            'tag_name': 'v0.2.11', 'draft': False, 'prerelease': False,
            'assets': [{
                'name': 'Birth-0.2.11.dmg', 'state': 'uploaded',
                'browser_download_url': 'https://github.com/iAmCorey/birth/releases/download/v0.2.11/Birth-0.2.11.dmg',
                'digest': 'sha256:' + self.sha256,
            }],
        }
        for command, body in {
            'gh': 'cat "$RELEASE_FIXTURE"',
            'curl': 'cp "$DMG_FIXTURE" "${@: -1}"',
        }.items():
            executable = self.root / command
            executable.write_text('#!/bin/bash\nset -eu\n' + body + '\n')
            executable.chmod(0o755)

    def run_release(self, release):
        source = self.root / 'source.json'
        source.write_text(json.dumps(release))
        output = self.root / 'output'
        output.unlink(missing_ok=True)
        result = subprocess.run(['bash', '-c', self.script], text=True, capture_output=True, env={
            **os.environ,
            'PATH': str(self.root) + os.pathsep + os.environ['PATH'],
            'RUNNER_TEMP': str(self.root), 'GITHUB_OUTPUT': str(output),
            'RELEASE_FIXTURE': str(source), 'DMG_FIXTURE': str(self.dmg),
        })
        return result, output.read_text() if output.exists() else ''

    def test_verified_release_outputs(self):
        result, output = self.run_release(self.release)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, f'version=0.2.11\nsha256={self.sha256}\n')

    def test_invalid_releases_never_emit_update_outputs(self):
        cases = []
        for field, value in [('tag_name', 'v0.2.11; echo injected'), ('draft', True), ('prerelease', True)]:
            release = copy.deepcopy(self.release)
            release[field] = value
            cases.append((field, release))
        for assets in [[], self.release['assets'] * 2]:
            release = copy.deepcopy(self.release)
            release['assets'] = assets
            cases.append(('missing or duplicate DMG', release))
        for field, value in [('state', 'new'), ('browser_download_url', 'https://example.com/Birth.dmg'), ('digest', 'sha256:' + '0' * 64), ('digest', None)]:
            release = copy.deepcopy(self.release)
            release['assets'][0][field] = value
            cases.append((field, release))
        for name, release in cases:
            with self.subTest(name=name):
                result, output = self.run_release(release)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output, '')


if __name__ == '__main__':
    unittest.main()
