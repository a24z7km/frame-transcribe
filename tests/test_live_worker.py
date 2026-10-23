import unittest
import numpy as np
from live_worker import PhraseBuffer, RATE, BLOCK, remove_overlap

class LiveWorkerTests(unittest.TestCase):
    def test_25_minutes_of_continuous_audio_stays_bounded(self):
        segmenter = PhraseBuffer()
        voice = np.full(BLOCK, .08, dtype=np.float32)
        count, previous = 0, -1
        for _ in range(25 * 60 * 10):
            result = segmenter.push(voice)
            self.assertLessEqual(segmenter.samples, 7 * RATE)
            self.assertLessEqual(len(segmenter.preroll), int(.3 * RATE))
            if result:
                audio, start = result
                self.assertLessEqual(len(audio), 7 * RATE)
                self.assertGreater(start, previous)
                previous = start
                count += 1
        self.assertGreater(count, 200)

    def test_silence_never_requests_transcription(self):
        segmenter = PhraseBuffer()
        for _ in range(1000):
            self.assertIsNone(segmenter.push(np.zeros(BLOCK, dtype=np.float32)))
        self.assertIsNone(segmenter.flush())
        self.assertLessEqual(len(segmenter.preroll), RATE // 4)

    def test_short_answer_and_silence_flush(self):
        segmenter = PhraseBuffer()
        results = []
        for block in [np.full(BLOCK,.1,dtype=np.float32)]*3 + [np.zeros(BLOCK,dtype=np.float32)]*8:
            result=segmenter.push(block)
            if result:results.append(result)
        self.assertEqual(len(results),1)
        self.assertIsNone(segmenter.flush())

    def test_overlap_does_not_repeat_prefix(self):
        self.assertEqual(remove_overlap('We meet at the station.', 'the station tomorrow morning.'), 'tomorrow morning.')
        self.assertEqual(remove_overlap('Yes.', 'Yes, I agree.'), 'Yes, I agree.')
        self.assertEqual(remove_overlap('I like tea.', 'I prefer coffee.'), 'I prefer coffee.')

if __name__=='__main__':unittest.main()
