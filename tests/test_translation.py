import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
import translation

class TranslationTests(unittest.TestCase):
    def test_long_transcript_is_automatic_and_lossless(self):
        source = ('The next meeting starts at nine tomorrow morning. Please bring your notes.\n' * 500)
        chunks = translation.split_text(source)
        self.assertGreater(len(source), 30000)
        self.assertGreater(len(chunks), 20)
        self.assertTrue(all(0 < len(chunk) <= 1200 for chunk in chunks))
        self.assertEqual(' '.join(' '.join(chunks).split()), ' '.join(source.split()))

    def test_long_words_and_unicode(self):
        for source in ('a' * 6001, '😀テスト' * 700):
            chunks = translation.split_text(source)
            self.assertEqual(''.join(chunks), source)
            self.assertTrue(all(len(chunk) <= 1200 for chunk in chunks))

    def test_invalid_input(self):
        for value in ('', None, ' ', 'a' * (translation.MAX_TEXT_BYTES + 1)):
            with self.assertRaises(ValueError): translation.split_text(value)

    def wait_for_end(self, manager):
        for _ in range(100):
            result = manager.snapshot()
            if not result.get('running'): return result
            time.sleep(.02)
        self.fail('Worker did not finish')

    def test_native_process_protocol_and_releases_process(self):
        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory) / 'helper'
            helper.write_text('#!/usr/bin/env python3\nimport json,sys\nrequest=json.load(sys.stdin)\nprint(json.dumps({"state":"done","text":"日本語訳", "progress":100}),flush=True)\n')
            helper.chmod(0o755)
            with patch('translation.HELPER', helper):
                manager = translation.TranslationManager()
                manager.start('The meeting starts tomorrow. ' * 1000)
                result = self.wait_for_end(manager)
                self.assertEqual(result['state'], 'done')
                self.assertEqual(result['text'], '日本語訳')
                self.assertIsNone(manager.process)
                self.assertGreater(len(result['source']), 5000)

    def test_cancel_keeps_partial_text(self):
        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory) / 'helper'
            helper.write_text('#!/usr/bin/env python3\nimport json,sys,time\njson.load(sys.stdin)\nprint(json.dumps({"state":"translating","text":"途中の訳文"}),flush=True)\ntime.sleep(10)\n')
            helper.chmod(0o755)
            with patch('translation.HELPER', helper):
                manager = translation.TranslationManager()
                manager.start('Hello world.')
                for _ in range(100):
                    if manager.snapshot()['text']: break
                    time.sleep(.02)
                manager.cancel()
                result = self.wait_for_end(manager)
                self.assertEqual(result['state'], 'cancelled')
                self.assertEqual(result['text'], '途中の訳文')
                self.assertIsNone(manager.process)

if __name__ == '__main__': unittest.main()
