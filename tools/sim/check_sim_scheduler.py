#!/usr/bin/env python3
"""Verify the simulation scheduler using fake runners; execute no HDL tools."""

from collections import Counter
from contextlib import redirect_stderr, redirect_stdout
import io
from pathlib import Path
import subprocess
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import run_all


def passed(name):
    return run_all.Result(name, True, "TB PASS: " + name)


class SchedulerTests(unittest.TestCase):
    def test_serial_default_runs_each_selected_bench_in_order(self):
        names = ["tb_c", "tb_a", "tb_b"]
        calls = []

        def fake(name):
            calls.append((name, threading.get_ident()))
            return passed(name)

        with patch.object(run_all, "run_testbench", side_effect=fake):
            results = run_all.run_testbenches(names)
        self.assertEqual([name for name, _ in calls], names)
        self.assertEqual([result.name for result in results], names)
        self.assertTrue(all(thread == threading.get_ident() for _, thread in calls))

    def test_parallel_is_bounded_and_preserves_order_after_late_first_result(self):
        names = ["tb_" + str(i) for i in range(9)]
        first_release = threading.Event()
        others_release = threading.Event()
        state = threading.Condition()
        calls, completed, results, raised = [], [], [], []
        active = peak = 0

        def fake(name):
            nonlocal active, peak
            with state:
                calls.append(name)
                active += 1
                peak = max(peak, active)
                state.notify_all()
            try:
                release = first_release if name == names[0] else others_release
                if not release.wait(5):
                    raise AssertionError("scheduler fixture did not release worker")
                return passed(name)
            finally:
                with state:
                    active -= 1
                    completed.append(name)
                    state.notify_all()

        def schedule():
            try:
                results.extend(run_all.run_testbenches(names, jobs=3))
            except BaseException as exc:
                raised.append(exc)

        with patch.object(run_all, "run_testbench", side_effect=fake):
            scheduler = threading.Thread(target=schedule)
            scheduler.start()
            try:
                with state:
                    self.assertTrue(state.wait_for(lambda: len(calls) >= 3, timeout=3),
                                    "parallel scheduler did not fill its three slots")
                    self.assertEqual(active, 3)
                    self.assertEqual(len(calls), 3)
                others_release.set()
                with state:
                    self.assertTrue(state.wait_for(lambda: len(completed) == len(names) - 1,
                                                   timeout=3),
                                    "waiting first result blocked independent benches")
                    self.assertNotIn(names[0], completed)
            finally:
                first_release.set()
                others_release.set()
                scheduler.join(5)
        self.assertFalse(scheduler.is_alive())
        self.assertEqual(raised, [])
        self.assertEqual(Counter(calls), Counter(names))
        self.assertEqual(completed[-1], names[0])
        self.assertEqual(peak, 3)
        self.assertEqual([result.name for result in results], names)
        self.assertTrue(all(result.ok for result in results))

    def test_failure_timeout_and_exception_preserve_every_result(self):
        names = ["tb_pass", "tb_fail", "tb_timeout", "tb_error", "tb_after"]
        for jobs in (1, 3):
            with self.subTest(jobs=jobs):
                calls = []
                lock = threading.Lock()

                def fake(name):
                    with lock:
                        calls.append(name)
                    if name == "tb_fail":
                        return run_all.Result(name, False, "failure details", "vvp exit 1")
                    if name == "tb_timeout":
                        raise subprocess.TimeoutExpired("fake-vvp", 300,
                                                        output=b"partial stdout\n",
                                                        stderr=b"partial stderr\n")
                    if name == "tb_error":
                        raise OSError("fake runner unavailable")
                    return passed(name)

                with patch.object(run_all, "run_testbench", side_effect=fake):
                    results = run_all.run_testbenches(names, jobs=jobs)
                self.assertEqual(Counter(calls), Counter(names))
                self.assertEqual([result.name for result in results], names)
                self.assertEqual([result.ok for result in results], [True, False, False, False, True])
                self.assertEqual(results[1].reason, "vvp exit 1")
                self.assertEqual(results[2].reason, "timeout after 300s")
                self.assertEqual(results[2].output, "partial stdout\npartial stderr\n")
                self.assertEqual(results[3].reason, "runner OSError")
                self.assertIn("fake runner unavailable", results[3].output)

    def test_real_result_parser_still_rejects_tool_errors_and_missing_pass(self):
        good_compile = SimpleNamespace(returncode=0, stdout="", stderr="")
        for returncode, output, expected in (
            (0, "TB PASS: fake\n", True),
            (0, "silent completion\n", False),
            (1, "TB PASS: fake\n", False),
            (0, "ERROR: fake failure\nTB PASS: fake\n", False),
        ):
            with self.subTest(returncode=returncode, output=output):
                completion = SimpleNamespace(returncode=returncode, stdout=output, stderr="")
                with patch.object(run_all, "read_sources", return_value=[]), \
                        patch.object(run_all, "read_timeout", return_value=300), \
                        patch.object(run_all.subprocess, "run",
                                     side_effect=[good_compile, completion]) as tool:
                    result = run_all.checked_testbench("tb_fake.sv")
                self.assertEqual(tool.call_count, 2)
                self.assertEqual(result.ok, expected)
        for compile_result in (
            SimpleNamespace(returncode=2, stdout="", stderr="fake compile failure"),
            SimpleNamespace(returncode=0, stdout="ERROR: fake compile diagnostic", stderr=""),
        ):
            with self.subTest(compile_result=compile_result):
                with patch.object(run_all, "read_sources", return_value=[]), \
                        patch.object(run_all, "read_timeout", return_value=300), \
                        patch.object(run_all.subprocess, "run", return_value=compile_result) as tool:
                    result = run_all.checked_testbench("tb_fake.sv")
                self.assertFalse(result.ok)
                self.assertEqual(tool.call_count, 1)
        with patch.object(run_all, "read_sources", return_value=[]), \
                patch.object(run_all, "read_timeout", return_value=900), \
                patch.object(run_all.subprocess, "run", side_effect=[good_compile,
                             subprocess.TimeoutExpired("fake-vvp", 900, output="last line\n")]) as tool:
            result = run_all.checked_testbench("tb_fake.sv")
        self.assertFalse(result.ok)
        self.assertEqual(tool.call_args.kwargs["timeout"], 900)
        self.assertEqual(result.reason, "timeout after 900s")
        self.assertEqual(result.output, "last line\n")

    def test_timeout_metadata_is_optional_strict_and_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tb_metadata.sv"
            path.write_text("// SOURCES: example.sv\nmodule tb_metadata; endmodule\n")
            self.assertEqual(run_all.read_timeout(path), 300)
            for value in (1, 300, 600, 900, 1800):
                with self.subTest(value=value):
                    path.write_text("// TIMEOUT: {}\nmodule tb_metadata; endmodule\n".format(value))
                    self.assertEqual(run_all.read_timeout(path), value)
            for header in ("// TIMEOUT: 0", "// TIMEOUT: 1801", "// TIMEOUT: -1",
                           "// TIMEOUT: 1.5", "// TIMEOUT: many", "// TIMEOUT:",
                           "// TIMEOUT: 300 seconds", "// TIMEOUT: 300\n// TIMEOUT: 900"):
                with self.subTest(header=header):
                    path.write_text(header + "\nmodule tb_metadata; endmodule\n")
                    with self.assertRaises(ValueError):
                        run_all.read_timeout(path)
                    with patch.object(run_all, "read_sources", return_value=[]), \
                            patch.object(run_all.subprocess, "run") as tool:
                        result = run_all.checked_testbench(str(path))
                    self.assertFalse(result.ok)
                    self.assertEqual(result.reason, "bad TIMEOUT header")
                    tool.assert_not_called()

    def test_structural_checks_remain_serial_sorted_and_filtered(self):
        calls = []

        def fake(command, **kwargs):
            calls.append((command[-1], threading.get_ident()))
            return SimpleNamespace(returncode=0, stdout="checked", stderr="")

        with patch.object(run_all.os, "listdir", return_value=[
                "check_sel_z.py", "tb_sel.sv", "check_else.py", "check_sel_a.py"]), \
                patch.object(run_all.subprocess, "run", side_effect=fake):
            results = run_all.run_structural_checks("sel")
        self.assertEqual([result.name for result in results], ["check_sel_a", "check_sel_z"])
        self.assertEqual([name.rsplit("/", 1)[-1] for name, _ in calls],
                         ["check_sel_a.py", "check_sel_z.py"])
        self.assertTrue(all(thread == threading.get_ident() for _, thread in calls))

    def test_main_finishes_checks_before_benches_and_reports_discovery_order(self):
        checks_finished = threading.Event()
        calls = []

        def checks(keyword):
            self.assertEqual(keyword, "sel")
            checks_finished.set()
            return [run_all.Result("check_sel", False, "check detail", "exit 1")]

        def fake(name):
            self.assertTrue(checks_finished.is_set())
            calls.append(name)
            return passed(name)

        output = io.StringIO()
        with patch.object(run_all, "run_structural_checks", side_effect=checks), \
                patch.object(run_all, "discover", return_value=["tb_sel_b", "tb_sel_a"]) as discover, \
                patch.object(run_all, "run_testbench", side_effect=fake), \
                patch("sys.argv", ["run_all.py", "-j", "3", "-k", "sel"]), \
                redirect_stdout(output):
            status = run_all.main()
        self.assertEqual(status, 1)
        discover.assert_called_once_with("sel")
        self.assertEqual(Counter(calls), Counter(["tb_sel_b", "tb_sel_a"]))
        log = output.getvalue()
        self.assertLess(log.index("FAIL check_sel"), log.index("PASS tb_sel_b"))
        self.assertLess(log.index("PASS tb_sel_b"), log.index("PASS tb_sel_a"))
        self.assertIn("3 run, 2 passed, 1 failed", log)
        self.assertIn("failed: check_sel", log)

    def test_cli_default_bounds_and_empty_selection(self):
        for options, expected_jobs in (([], 1), (["--jobs", "8"], 8)):
            with self.subTest(options=options), \
                    patch.object(run_all, "run_structural_checks", return_value=[]), \
                    patch.object(run_all, "discover", return_value=[]), \
                    patch.object(run_all, "run_testbenches", return_value=[]) as schedule, \
                    patch("sys.argv", ["run_all.py", *options]), redirect_stdout(io.StringIO()):
                self.assertEqual(run_all.main(), 1)
                schedule.assert_called_once_with([], expected_jobs)
        for jobs in ("0", "9", "-1", "1.5", "many"):
            with self.subTest(jobs=jobs), \
                    patch.object(run_all, "run_structural_checks") as checks, \
                    patch.object(run_all, "discover") as discover, \
                    patch("sys.argv", ["run_all.py", "--jobs", jobs]), redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as stopped:
                    run_all.main()
                self.assertEqual(stopped.exception.code, 2)
                checks.assert_not_called()
                discover.assert_not_called()
        for jobs in (0, 9):
            with self.assertRaises(ValueError):
                run_all.run_testbenches([], jobs)


if __name__ == "__main__":
    unittest.main()
