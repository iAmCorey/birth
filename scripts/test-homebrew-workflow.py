#!/usr/bin/env python3
"""Exercise Homebrew validation and publishing contracts without network access."""
import base64
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
        cls.publish_script = subprocess.check_output([
            'ruby', '-ryaml', '-e',
            'puts YAML.load_file(ARGV[0]).fetch("jobs").fetch("publish").fetch("steps").first.fetch("run")',
            str(workflow),
        ], text=True)
        cls.cask_script = subprocess.check_output([
            'ruby', '-ryaml', '-e',
            'puts YAML.load_file(ARGV[0]).fetch("jobs").fetch("update-tap").fetch("steps").find { |step| step["id"] == "cask" }.fetch("run")',
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

    def test_publishing_targets_this_repository_and_preserves_blob_guard(self):
        arguments = self.root / 'arguments'
        (self.root / 'gh').write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$GH_ARGUMENTS"\n')
        result = subprocess.run(['bash', '-c', self.publish_script], text=True, capture_output=True, env={
            **os.environ,
            'PATH': str(self.root) + os.pathsep + os.environ['PATH'],
            'GITHUB_REPOSITORY': 'maintainer/birth', 'GH_TOKEN': 'automatic-workflow-token',
            'GH_ARGUMENTS': str(arguments), 'VERSION': '0.2.11',
            'CONTENT': 'validated-base64-cask', 'ORIGINAL_SHA': 'original-cask-blob',
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        passed = arguments.read_text().splitlines()
        self.assertIn('repos/maintainer/birth/contents/Casks/birth.rb', passed)
        self.assertIn('sha=original-cask-blob', passed)
        self.assertIn('content=validated-base64-cask', passed)
        self.assertIn('branch=main', passed)

    def test_cask_content_output_handles_crlf_base64_wrapping(self):
        cask = self.root / 'Casks/birth.rb'
        cask.parent.mkdir()
        cask.write_bytes(b'validated cask content\n')
        encoder = self.root / 'base64'
        encoder.write_text("#!/usr/bin/env python3\nimport base64, sys, textwrap\nsys.stdout.write('\\r\\n'.join(textwrap.wrap(base64.b64encode(sys.stdin.buffer.read()).decode(), 12)) + '\\r\\n')\n")
        encoder.chmod(0o755)
        formatter = next(line.strip() for line in self.cask_script.splitlines() if "printf 'content=" in line)
        result = subprocess.run(['bash', '-c', formatter], text=True, capture_output=True, env={
            **os.environ,
            'PATH': str(self.root) + os.pathsep + os.environ['PATH'],
            'tap_repository': str(self.root),
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'content=' + base64.b64encode(cask.read_bytes()).decode() + '\n')


if __name__ == '__main__':
    unittest.main()
