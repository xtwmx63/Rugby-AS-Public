"""Protect the bundled data when an import is malformed or repeated."""
import contextlib
import copy
import io
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

import build_archive
import jrfu
from test_jrfu import SCHEDULE


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        record = jrfu.parse_schedule(SCHEDULE, 2025, "大学", "2026-09-24T00:00:00Z")[0]
        self.payload = dict(matches=[record], coverage=[], errors=[])
        self.source = self.root / 'source.json'
        self.output = self.root / 'archive.sqlite'

    def build(self, payload):
        self.source.write_text(json.dumps(payload, ensure_ascii=False))
        with contextlib.redirect_stdout(io.StringIO()):
            return build_archive.assemble([self.source], self.output)

    def test_null_and_zero_are_stored_distinctly(self):
        self.payload['matches'][0]['homeScore'] = None
        self.build(self.payload)
        with contextlib.closing(sqlite3.connect(self.output)) as database:
            self.assertEqual(database.execute('SELECT homeScore, awayScore FROM matches').fetchone(), (None, 0))

    def test_duplicates_merge_category_memberships(self):
        second = copy.deepcopy(self.payload['matches'][0])
        second['category'] = 'その他'
        second['categories'] = ['その他']
        self.payload['matches'].append(second)
        manifest = self.build(self.payload)
        self.assertEqual(manifest['matchCount'], 1)
        with contextlib.closing(sqlite3.connect(self.output)) as database:
            categories = {row[0] for row in database.execute('SELECT category FROM match_categories')}
        self.assertEqual(categories, {'大学', 'その他'})

    def test_invalid_import_preserves_existing_archive(self):
        self.build(self.payload)
        original = self.output.read_bytes()
        for field, value in [('homeScore', True), ('awayScore', -1), ('date', '2025-02-30'),
                             ('sourceURL', 'https://example.com/match/123'), ('categories', []),
                             ('fetchedAt', '2025-01-01')]:
            invalid = copy.deepcopy(self.payload)
            invalid['matches'][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.build(invalid)
            self.assertEqual(self.output.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
