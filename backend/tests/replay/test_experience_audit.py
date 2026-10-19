"""Experience review must preserve missingness, time boundaries and source data."""
from datetime import date, datetime, timezone
import hashlib
import json
import sys

import pytest

from app import experience_audit as audit
from .test_device_check_empty import database


def at(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def test_partial_first_day_and_latest_incomplete_noon_are_excluded():
    lower = at("2026-09-20T08:00:00Z")  # 03:00 local; omit this partial day
    through = {"sleep": at("2026-09-25T20:00:00Z"), "movement": at("2026-09-23T16:00:00Z")}
    points = audit.checkpoints(lower, through, "America/Chicago", 30)
    assert [key for key, _ in points] == ["noon:2026-09-21", "noon:2026-09-22"]
    assert all(value.hour == 17 for _, value in points)


def test_window_uses_local_calendar_days_across_dst():
    points = audit.checkpoints(at("2026-10-01T00:00:00Z"), {"sleep": at("2026-11-02T20:00:00Z")},
                              "America/Chicago", 3)
    assert [value.hour for _, value in points] == [17, 18, 18]
    assert [key for key, _ in points] == ["noon:2026-10-31", "noon:2026-11-01", "noon:2026-11-02"]
    assert all(value.tzinfo == timezone.utc for _, value in points)


def test_end_caps_the_window_and_missing_coverage_is_not_zero():
    lower = at("2026-09-01T00:00:00Z")
    assert audit.checkpoints(lower, {}, "America/Chicago", 30) == []
    points = audit.checkpoints(lower, {"sleep": at("2026-09-25T20:00:00Z")}, "America/Chicago", 2,
                              date(2026, 9, 22))
    assert [key for key, _ in points] == ["noon:2026-09-21", "noon:2026-09-22"]


def test_morning_hour_samples_a_day_noon_would_exclude():
    lower = at("2026-09-20T08:00:00Z")
    through = {"sleep": at("2026-09-23T15:00:00Z")}  # 10:00 local: past 08:00, before noon
    points = audit.checkpoints(lower, through, "America/Chicago", 30, hour=8)
    assert [key for key, _ in points] == ["0800:2026-09-21", "0800:2026-09-22", "0800:2026-09-23"]
    assert all(value.hour == 13 for _, value in points)
    with pytest.raises(ValueError):
        audit.checkpoints(lower, through, "America/Chicago", 30, hour=24)


@pytest.mark.parametrize("days", [0, -1, 61])
def test_rejects_invalid_windows_even_without_coverage(days):
    with pytest.raises(ValueError):
        audit.checkpoints(at("2026-09-01T00:00:00Z"), {}, "America/Chicago", days)


def test_categories_use_the_primary_trait_not_copy_or_global_calibration():
    results = {}
    for index, trait in enumerate(("sleep", "typical", "calibration", "no_data", "workout"), start=1):
        results[str(index)] = {"day": f"2026-09-{index:02}", "effective_at": f"2026-09-{index:02}T17:00:00Z",
                              "widget_state": {"primary_trait": {"id": trait},
                                               "presentation": {"headline": "same | wording"}},
                              "health_state": {"calibration": {"status": "calibrating"}}}
    summary = audit.summarize(results)
    assert summary["counts"] == {"headline": 2, "quiet": 1, "calibrating": 1, "no_data": 1}
    assert summary["evaluated_days"] == 5
    assert summary["headline_frequencies"] == {"same | wording": 5}
    assert summary["days"][0]["category"] == "headline"
    results["1"]["widget_state"]["primary_trait"]["id"] = "unknown_future_trait"
    with pytest.raises(ValueError, match="Unknown primary trait"):
        audit.summarize(results)


def test_empty_readable_health_data_is_no_data_not_quiet_and_db_is_unchanged(tmp_path):
    source = database(tmp_path, True)
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    report, points = audit.audit(str(source), "America/Chicago", 30)
    assert report["counts"] == {"headline": 0, "quiet": 0, "calibrating": 0, "no_data": 3}
    assert report["first_day"] == "2026-09-20"
    assert report["last_day"] == "2026-09-22"
    assert report["requested_days"] == 30 and report["evaluated_days"] == 3
    assert len(points) == 3
    assert hashlib.sha256(source.read_bytes()).hexdigest() == before


@pytest.mark.parametrize("coverage, exit_code", [(True, None), (False, 2)])
def test_cli_writes_review_and_swift_compatible_checkpoints(tmp_path, monkeypatch, coverage, exit_code):
    source = database(tmp_path, coverage)
    out = tmp_path / "review"
    monkeypatch.setattr(sys, "argv", ["experience_audit", str(source), "--out-dir", str(out)])
    if exit_code:
        with pytest.raises(SystemExit) as result:
            audit.main()
        assert result.value.code == exit_code
    else:
        audit.main()
    report = json.loads((out / "report.json").read_text())
    points = json.loads((out / "checkpoints.json").read_text())
    assert len(points) == report["evaluated_days"]
    assert "not historical delivery" in (out / "review.md").read_text()
    assert all({"features", "health_state", "widget_state", "effective_at"} <= value.keys()
               for value in points.values())
    before = (out / "report.json").read_bytes()
    with pytest.raises(SystemExit) as result:
        audit.main()
    assert result.value.code == 2
    assert (out / "report.json").read_bytes() == before
