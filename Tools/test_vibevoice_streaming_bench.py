import unittest
from unittest.mock import MagicMock, patch
from pathlib import Path
import signal
import subprocess
import tempfile
from types import SimpleNamespace

from vibevoice_streaming_bench import content_only, distance, normalized_units, run_apple, score


class BenchmarkScoringTests(unittest.TestCase):
    def test_edit_distance(self):
        self.assertEqual(distance([], []), 0)
        self.assertEqual(distance([], ["word"]), 1)
        self.assertEqual(distance(list("abc"), list("axc")), 1)
        self.assertEqual(distance(list("abc"), list("ac")), 1)

    def test_speaker_labels_not_scored_as_speech(self):
        self.assertEqual(content_only(" \n Speaker 0:We ruled out \n Speaker 1:a leak."),
                         "We ruled out \na leak.")
        self.assertEqual(content_only(" \n Speaker 0:"), "")

    def test_formatting_equivalents(self):
        self.assertEqual(normalized_units("15%, not 50%", "en"),
                         normalized_units("fifteen percent, not fifty percent", "en"))
        self.assertEqual(normalized_units("3.5万元不是35万元", "zh"),
                         normalized_units("三点五万元不是三十五万元", "zh"))

    def test_meaningful_errors_remain(self):
        self.assertNotEqual(normalized_units("cache", "en"), normalized_units("cash", "en"))
        self.assertNotEqual(normalized_units("键值", "zh"), normalized_units("见只", "zh"))
        self.assertNotEqual(normalized_units("15%", "en"), normalized_units("50%", "en"))

    def test_unknown_reference_not_scored(self):
        self.assertEqual(score({"reference": None}, {"text": "hello"}), {"text": "hello"})

    def test_timeout_stops_only_the_benchmark_process_group(self):
        process = MagicMock(pid=12345)
        process.wait.side_effect = [subprocess.TimeoutExpired("replay", 91), 0]
        with tempfile.TemporaryDirectory() as folder, \
                patch("vibevoice_streaming_bench.subprocess.Popen", return_value=process) as launch, \
                patch("vibevoice_streaming_bench.duration", return_value=1), \
                patch("vibevoice_streaming_bench.os.killpg") as kill:
            args = SimpleNamespace(output=Path(folder), apple_binary=Path("replay"))
            with self.assertRaises(subprocess.TimeoutExpired):
                run_apple({"id": "test", "audio": "test.wav", "language": "en"}, args)
            self.assertTrue(launch.call_args.kwargs["start_new_session"])
            kill.assert_called_once_with(12345, signal.SIGTERM)


if __name__ == "__main__":
    unittest.main()
