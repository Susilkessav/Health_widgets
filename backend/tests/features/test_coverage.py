"""Coverage resolution by revision and UTC span (Step 6-8 plan section 7)."""
from datetime import date, datetime
from zoneinfo import ZoneInfo

from app.features.models import CalculationContext, CoverageWindow

DAY = date(2026, 9, 22)


def ctx(*windows, zone="America/Chicago", day=DAY, hour=13, minute=0):
    effective = datetime.combine(day, datetime.min.time(), ZoneInfo(zone)).replace(hour=hour, minute=minute)
    return CalculationContext(day=day, timezone=zone, effective_at=effective, known_at=effective, coverage=windows)


def window(status, revision, start=DAY, end=DAY, zone="America/Chicago", domain="sleep"):
    return CoverageWindow(domain=domain, start_day=start, end_day=end, timezone=zone, status=status, revision=revision)


def test_later_success_supersedes_an_earlier_failure():
    assert ctx(window("unavailable", 1), window("complete", 2)).covered("sleep", DAY, DAY)


def test_later_failure_supersedes_an_earlier_success():
    assert not ctx(window("complete", 1), window("unavailable", 2)).covered("sleep", DAY, DAY)


def test_equal_revision_disagreement_is_not_covered():
    assert not ctx(window("complete", 3), window("unavailable", 3)).covered("sleep", DAY, DAY)


def test_overlapping_windows_resolve_per_instant():
    wide = window("complete", 1, date(2026, 9, 20), date(2026, 9, 22))
    failed = window("unavailable", 2, date(2026, 9, 21), date(2026, 9, 21))
    context = ctx(wide, failed)
    assert context.covered("sleep", date(2026, 9, 20), date(2026, 9, 20))
    assert not context.covered("sleep", date(2026, 9, 21), date(2026, 9, 21))
    assert context.covered("sleep", date(2026, 9, 22), date(2026, 9, 22))
    assert not context.covered("sleep", date(2026, 9, 20), date(2026, 9, 22))


def test_undeclared_time_and_other_domains_are_not_coverage():
    assert not ctx().covered("sleep", DAY, DAY)
    assert not ctx(window("complete", 1, domain="hrv")).covered("sleep", DAY, DAY)


def test_travel_checks_the_true_utc_span():
    # A Chicago-declared day ends at 05:00 UTC; the Los Angeles day runs to 07:00 UTC.
    # Evaluated at 23:30 in Los Angeles (06:30 UTC), the gap after 05:00 UTC matters.
    chicago = window("complete", 1)
    assert not ctx(chicago, zone="America/Los_Angeles", hour=23, minute=30).covered("sleep", DAY, DAY)
    both = window("complete", 1, DAY, date(2026, 9, 23))
    assert ctx(both, zone="America/Los_Angeles", hour=23, minute=30).covered("sleep", DAY, DAY)


def test_dst_days_use_their_real_length():
    fall = date(2026, 11, 1)  # 25 hours in Chicago
    assert ctx(window("complete", 1, fall, fall), day=fall).covered("sleep", fall, fall)
    # A same-date window in a zone without DST that day misses part of the 25-hour span.
    assert not ctx(window("complete", 1, fall, fall, zone="America/Phoenix"), day=fall).covered("sleep", fall, fall)


def test_replay_at_an_older_revision_sees_the_old_answer():
    failure, success = window("unavailable", 1), window("complete", 2)
    assert not ctx(failure).covered("sleep", DAY, DAY)          # the view before revision 2
    assert ctx(failure, success).covered("sleep", DAY, DAY)


# ---------------------------------------------------------------- partial days (Step 9-13 plan section 3A)

def instant(status, revision, start, end, domain="sleep"):
    return CoverageWindow(domain=domain, timezone="America/Chicago", status=status, revision=revision,
                          start_at=start, end_at=end)


CHI = ZoneInfo("America/Chicago")


def test_a_partial_day_declaration_covers_only_until_its_query_finished():
    morning = instant("complete", 1, datetime(2026, 9, 22, 0, 0, tzinfo=CHI), datetime(2026, 9, 22, 13, 0, tzinfo=CHI))
    assert ctx(morning, hour=13).covered("sleep", DAY, DAY)          # calculated at 13:00
    assert not ctx(morning, hour=18).covered("sleep", DAY, DAY)      # 13:00-18:00 is unknown
    later = instant("complete", 2, datetime(2026, 9, 22, 13, 0, tzinfo=CHI), datetime(2026, 9, 22, 18, 5, tzinfo=CHI))
    assert ctx(morning, later, hour=18).covered("sleep", DAY, DAY)


def test_time_after_the_calculation_is_never_required():
    whole_day = window("complete", 1)
    failed_evening = instant("unavailable", 2, datetime(2026, 9, 22, 20, 0, tzinfo=CHI),
                             datetime(2026, 9, 22, 22, 0, tzinfo=CHI))
    assert ctx(whole_day, failed_evening, hour=13).covered("sleep", DAY, DAY)
    assert not ctx(whole_day, failed_evening, hour=23).covered("sleep", DAY, DAY)


def test_a_window_needs_exactly_one_form():
    import pytest
    from pydantic import ValidationError
    moment = datetime(2026, 9, 22, 13, 0, tzinfo=CHI)
    for bad in ({"start_day": DAY}, {"start_day": DAY, "end_day": DAY, "start_at": moment, "end_at": moment},
                {"start_at": moment, "end_at": moment}, {}):
        with pytest.raises(ValidationError):
            CoverageWindow(domain="sleep", timezone="America/Chicago", status="complete", **bad)
