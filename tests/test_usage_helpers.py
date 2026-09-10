import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXTURES = pathlib.Path(__file__).resolve().parent / "fixtures"


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "src" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


agy_usage = load("agy_usage", "agy-usage.py")
codex_usage = load("codex_usage", "codex-usage.py")
claude_usage = load("claude_usage", "claude-desktop-usage.py")


class AgyUsageTests(unittest.TestCase):
    def test_parses_both_families_as_used_percent(self):
        report = (FIXTURES / "agy-usage-report.txt").read_text(encoding="utf-8")
        families = agy_usage.parse_report(report)
        self.assertEqual(set(families), {"gemini", "claude_gpt"})
        self.assertEqual(families["gemini"]["weekly"]["used_percent"], 4.0)
        self.assertEqual(families["gemini"]["weekly"]["window_minutes"], 10080)
        self.assertEqual(families["claude_gpt"]["five_hour"]["left_percent"], 100.0)

        normalized = agy_usage.normalize(families)
        self.assertEqual(normalized["model"], "Gemini Models")
        self.assertIs(normalized["weekly"], families["gemini"]["weekly"])

    def test_rejects_report_without_limit_lines(self):
        with self.assertRaises(agy_usage.AgyError):
            agy_usage.parse_report("nothing to see here")


class CodexUsageTests(unittest.TestCase):
    def test_normalizes_rate_limits_and_counts_available_credits(self):
        raw = {
            "rateLimits": {
                "planType": "plus",
                "primary": {"usedPercent": 12, "resetsAt": 1789079869, "windowDurationMins": 300},
                "secondary": {"usedPercent": 56, "resetsAt": 1789553980, "windowDurationMins": 10080},
            },
            "rateLimitResetCredits": {
                "credits": [
                    {"id": "a", "resetType": "codexRateLimits", "status": "available", "expiresAt": 1789946079},
                    {"id": "b", "resetType": "codexRateLimits", "status": "consumed", "expiresAt": 1788592000},
                ]
            },
        }
        normalized = codex_usage.normalize(raw)
        self.assertEqual(normalized["plan"], "plus")
        self.assertEqual(normalized["five_hour"]["left_percent"], 88.0)
        self.assertEqual(normalized["weekly"]["window_minutes"], 10080)
        self.assertEqual(normalized["reset_credits"]["available_count"], 1)
        self.assertEqual(normalized["reset_credits"]["credits"][0]["expires_at_epoch"], 1789946079)


class ClaudeScopedLimitTests(unittest.TestCase):
    USAGE = {
        "limits": [
            {"kind": "session", "percent": 62, "scope": None},
            {
                "kind": "weekly_scoped",
                "percent": 91,
                "resets_at": "2026-09-11T09:00:00+00:00",
                "scope": {"model": {"id": None, "display_name": "Fable"}, "surface": None},
                "is_active": True,
            },
        ]
    }

    def test_finds_fable_weekly_cap(self):
        window = claude_usage.normalize_scoped_window(claude_usage.find_scoped_limit(self.USAGE, "fable"))
        self.assertEqual(window["used_percent"], 91.0)
        self.assertEqual(window["left_percent"], 9.0)
        self.assertEqual(window["resets_at_epoch"], 1789117200)

    def test_missing_scope_yields_empty_window(self):
        window = claude_usage.normalize_scoped_window(claude_usage.find_scoped_limit({"limits": []}, "Fable"))
        self.assertIsNone(window["used_percent"])


if __name__ == "__main__":
    unittest.main()
