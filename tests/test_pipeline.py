import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import server
from translation import TranslationError, TranslationManager


class PipelineTests(unittest.TestCase):
    def run_worker(self, update, code=0):
        process = Mock(stdout=io.StringIO(json.dumps(update) + '\n'), stderr=io.StringIO(''))
        process.wait.return_value = code
        manager = Mock()
        with tempfile.NamedTemporaryFile(delete=False) as file:
            path = file.name
        job = {'state': 'loading', 'running': True}
        with patch.object(server, 'JOB', job), patch.object(server, 'TRANSLATION', manager), \
                patch.object(server.subprocess, 'Popen', return_value=process):
            server.run_job(path, 'tiny.en')
        self.assertFalse(Path(path).exists())
        self.assertFalse(job['running'])
        return job, manager

    def test_completed_transcript_starts_translation_without_browser(self):
        job, manager = self.run_worker({'state': 'done', 'text': 'Hello there.'})
        manager.start_automatic.assert_called_once_with('Hello there.')
        self.assertEqual(job['text'], 'Hello there.')

    def test_empty_cancelled_and_failed_jobs_do_not_translate(self):
        for state, text, code in [('done', '', 0), ('cancelled', 'Partial.', 0),
                                   ('error', 'Partial.', 1), ('done', 'Partial.', 1)]:
            with self.subTest(state=state, code=code):
                _, manager = self.run_worker({'state': state, 'text': text}, code)
                manager.start_automatic.assert_not_called()

    def test_translation_start_failure_is_visible_and_keeps_english(self):
        manager = TranslationManager()
        with patch.object(manager, 'start', side_effect=TranslationError('モデルがありません')):
            manager.start_automatic('Hello there.')
        result = manager.snapshot()
        self.assertEqual(result['state'], 'error')
        self.assertFalse(result['running'])
        self.assertEqual(result['source'], 'Hello there.')
        self.assertEqual(result['text'], '')
        self.assertEqual(result['message'], 'モデルがありません')
