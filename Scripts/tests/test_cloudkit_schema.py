"""Synthetic CKDB fixtures only: never call CloudKit from tests."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("cloudkit_schema", Path(__file__).parents[1] / "cloudkit_schema.py")
schema = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(schema)
FIXTURE = '''DEFINE SCHEMA
CREATE ROLE Family;
RECORD TYPE Note (
 title STRING QUERYABLE SORTABLE,
 value NUMBER PREFERRED AS INT64,
 tags LIST<STRING>,
 secret ENCRYPTED STRING,
 GRANT WRITE, READ TO Family
);'''


class ParserTests(unittest.TestCase):
    def test_versioned_export_if_present(self):
        if schema.SCHEMA.exists():
            schema.parse_schema(schema.SCHEMA.read_text())

    def test_comments_quotes_case_order_and_implicit_fields(self):
        a = schema.parse_schema('define schema // comment\n RECORD TYPE "Note" ( "title" STRING, GRANT READ TO "_world");')
        b = schema.parse_schema('DEFINE SCHEMA /* x */ CREATE ROLE "_world"; RECORD TYPE Note (GRANT READ TO _world, ___etag STRING, title STRING); -- end')
        self.assertEqual(a, b)
        schema.parse_schema(FIXTURE)

    def test_unknown_syntax_fails_closed(self):
        for text in ('DEFINE SCHEMA DROP TYPE Note;', 'DEFINE SCHEMA RECORD TYPE Note (x MAGIC);',
                     'DEFINE SCHEMA RECORD TYPE Note (x STRING FANCY);', 'DEFINE SCHEMA /* unclosed',
                     'DEFINE SCHEMA RECORD TYPE Note (x LIST<LIST<STRING>>);'):
            with self.subTest(text=text), self.assertRaises(schema.SchemaError):
                schema.parse_schema(text)

    def test_removal_rename_type_indexes_permissions_encryption(self):
        original = schema.parse_schema(FIXTURE)
        for text in (FIXTURE.replace('Note', 'Other'), FIXTURE.replace('title', 'renamed'),
                     FIXTURE.replace('title STRING', 'title BYTES'), FIXTURE.replace(' SORTABLE', ''),
                     FIXTURE.replace('WRITE, READ', 'READ'), FIXTURE.replace('ENCRYPTED ', '')):
            with self.subTest(text=text):
                self.assertTrue(schema.incompatible(original, schema.parse_schema(text)))

    def test_additions_are_compatible(self):
        self.assertFalse(schema.incompatible(schema.parse_schema(FIXTURE), schema.parse_schema(FIXTURE.replace('title STRING', 'added BYTES, title STRING'))))


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.versioned = self.root / 'CloudKit/development.ckdb'
        self.report = self.root / 'Artifacts/CloudKit/report.json'
        self.calls = []
        self.exports = {'development': FIXTURE, 'production': FIXTURE}
        self.failure = None
        for name, value in [('SCHEMA', self.versioned), ('REPORT', self.report)]:
            patcher = patch.object(schema, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = patch.object(schema, 'cktool', side_effect=self.fake_cktool)
        patcher.start()
        self.addCleanup(patcher.stop)

    def fake_cktool(self, command, environment, *args):
        self.calls.append((command, environment, args))
        if self.failure == (command, environment):
            raise schema.SchemaError('synthetic failure')
        if command == 'export-schema':
            text = self.exports[environment]
            if text is not None:
                Path(args[1]).write_text(text)
        if command == 'import-schema':
            self.exports['development'] = Path(args[-1]).read_text()

    def test_prepare_order_and_idempotency(self):
        schema.run()
        self.assertEqual([(c[0], c[1]) for c in self.calls], [('export-schema', 'development'), ('export-schema', 'production'), ('validate-schema', 'development')])
        before = self.versioned.stat().st_mtime_ns
        self.exports['development'] = FIXTURE + '\n// formatting only'
        schema.run()
        self.assertEqual(before, self.versioned.stat().st_mtime_ns)

    def test_check_and_dry_run_never_write_versioned_or_import(self):
        for command, dry_run in [('check', True), ('prepare', True), ('import-development', True)]:
            if command == 'import-development':
                self.versioned.parent.mkdir(parents=True)
                self.versioned.write_text(FIXTURE)
            schema.run(command, dry_run, True)
            self.assertFalse(any(c[0] == 'import-schema' for c in self.calls))
            if command != 'import-development':
                self.assertFalse(self.versioned.exists())

    def test_failures_and_partial_exports_preserve_versioned(self):
        self.versioned.parent.mkdir(parents=True)
        self.versioned.write_text(FIXTURE)
        for failure in [('export-schema', 'development'), ('export-schema', 'production'), ('validate-schema', 'development')]:
            self.failure = failure
            with self.assertRaises(schema.SchemaError):
                schema.run()
            self.assertEqual(self.versioned.read_text(), FIXTURE)
            self.assertEqual(json.loads(self.report.read_text())['status'], 'incomplete')
        self.failure = None
        for text in (None, '', 'DEFINE SCHEMA RECORD TYPE Bad (x MAGIC);'):
            self.exports['production'] = text
            with self.assertRaises(schema.SchemaError):
                schema.run()
            self.assertEqual(self.versioned.read_text(), FIXTURE)

    def test_incompatible_export_never_saved(self):
        self.exports['development'] = FIXTURE.replace('title', 'renamed')
        with self.assertRaises(schema.SchemaError):
            schema.run()
        self.assertFalse(self.versioned.exists())

    def test_import_requires_confirmation_and_checks_development(self):
        with self.assertRaises(schema.SchemaError):
            schema.run('import-development')
        self.assertEqual(self.calls, [])
        self.versioned.parent.mkdir(parents=True)
        self.versioned.write_text(FIXTURE)
        self.exports['development'] = FIXTURE.replace('title STRING', 'added STRING, title STRING')
        with self.assertRaises(schema.SchemaError):
            schema.run('import-development', confirm=True)
        self.assertFalse(any(c[0] == 'import-schema' for c in self.calls))
        self.exports['development'] = FIXTURE
        schema.run('import-development', confirm=True)
        self.assertFalse(any(c[0] == 'import-schema' for c in self.calls))
        self.exports['development'] = FIXTURE.replace(' tags LIST<STRING>,', '')
        schema.run('import-development', confirm=True)
        imports = [c for c in self.calls if c[0] == 'import-schema']
        self.assertEqual(imports[-1][1], 'development')
        self.assertIn('--validate', imports[-1][2])
        self.assertFalse(any(c[0] == 'import-schema' and c[1] == 'production' for c in self.calls))

    def test_verify_detects_production_mismatch(self):
        self.versioned.parent.mkdir(parents=True)
        self.versioned.write_text(FIXTURE.replace('title STRING', 'added STRING, title STRING'))
        with self.assertRaises(schema.SchemaError):
            schema.run('verify-production')

    def test_failed_import_report_never_claims_success(self):
        self.versioned.parent.mkdir(parents=True)
        self.versioned.write_text(FIXTURE)
        self.exports['development'] = FIXTURE.replace(' tags LIST<STRING>,', '')
        self.failure = ('import-schema', 'development')
        with self.assertRaises(schema.SchemaError):
            schema.run('import-development', confirm=True)
        self.assertEqual(json.loads(self.report.read_text())['status'], 'import-incomplete')

    def test_subprocess_uses_native_auth_and_redacts_errors(self):
        # Bypass the fake helper for this isolated subprocess contract test.
        original = SPEC.loader
        module = importlib.util.module_from_spec(SPEC)
        original.exec_module(module)
        with patch.object(module.subprocess, 'run') as run:
            run.return_value.returncode = 1
            run.return_value.stderr = 'SECRET TOKEN'
            with self.assertRaises(module.SchemaError) as caught:
                module.cktool('export-schema', 'production', '--output-file', '/tmp/fixture.ckdb')
            self.assertNotIn('SECRET', str(caught.exception))
            argv = run.call_args.args[0]
            self.assertNotIn('--token', argv)
            self.assertEqual(argv[:3], ['xcrun', 'cktool', 'export-schema'])
            run.return_value.returncode = 0
            module.cktool('validate-schema', 'development', '--file', '/tmp/fixture.ckdb')
            self.assertEqual(run.call_args.args[0][:3], ['xcrun', 'cktool', 'validate-schema'])
            self.assertNotIn('--token', run.call_args.args[0])

    def test_wrapper_end_to_end_with_fake_xcrun(self):
        project = self.root / 'проект with spaces'
        scripts = project / 'Scripts'
        scripts.mkdir(parents=True)
        for name in ('cloudkit_schema.py', 'cloudkit-schema.sh'):
            shutil.copy(Path(__file__).parents[1] / name, scripts / name)
        binary = self.root / 'bin'
        binary.mkdir()
        fake = binary / 'xcrun'
        fake.write_text('#!' + sys.executable + '\n' +
                        'import sys\nfrom pathlib import Path\n' +
                        'args = sys.argv[1:]\n' +
                        'assert args[0] == "cktool"\n' +
                        'assert "--token" not in args\n' +
                        'assert args[1] in {"export-schema", "validate-schema"}\n' +
                        'if args[1] == "export-schema":\n' +
                        '    Path(args[args.index("--output-file") + 1]).write_text(' + repr(FIXTURE) + ')\n')
        fake.chmod(0o755)
        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'])
        result = subprocess.run(['sh', str(scripts / 'cloudkit-schema.sh'), '--dry-run'], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((project / 'CloudKit/development.ckdb').exists())
        report = json.loads((project / 'Artifacts/CloudKit/report.json').read_text())
        self.assertEqual(report['status'], 'checked')
        self.assertTrue(report['dry_run'])


if __name__ == '__main__':
    unittest.main()
