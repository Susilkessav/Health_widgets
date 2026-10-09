"""Per-domain cutoffs (decision D-A): a later step read moves movement only.
Other domains keep the records and coverage of their own import cutoff."""
from datetime import timedelta

import pytest

from app.contracts._types import local_day_start
from app.features.calculate import calculate_features
from app.features.models import DOMAINS, CalculationContext, CoverageWindow
from app.synthetic.generator import Builder
from tests.features.conftest import DAY, SETTINGS, ZONE, at, history, observations, point, workout

APP_IMPORT, STEP_READ = at(10), at(13)
OTHERS = ("sleep", "hrv", "rhr", "workout")


def coverage():
    """Whole days before today; today only as far as each query reached."""
    whole = [CoverageWindow(domain=d, timezone=ZONE, status="complete",
                            start_day=DAY - timedelta(days=40), end_day=DAY - timedelta(days=1)) for d in DOMAINS]
    today = [CoverageWindow(domain=d, timezone=ZONE, status="complete", start_at=local_day_start(DAY, ZONE),
                            end_at=STEP_READ if d == "movement" else APP_IMPORT) for d in DOMAINS]
    return tuple(whole + today)


def features(effective, cutoffs=None):
    b = Builder("t", ZONE)
    history(b)
    b.daily(DAY, hrv=None, steps=None)            # last night's sleep and morning resting HR; no HRV yet
    b.snapshot(DAY, APP_IMPORT, 3000)
    point(b, "late-hrv", "hrv_sdnn_ms", 80, at(12))  # arrives after the app's import
    workout(b, "late-run", at(11), at(11, 45), 45)
    b.snapshot(DAY, STEP_READ, 5200)              # the widget's own step read
    context = CalculationContext(day=DAY, timezone=ZONE, effective_at=effective, known_at=STEP_READ,
                                 coverage=coverage(), cutoffs=cutoffs or {})
    return calculate_features(observations(b), context, SETTINGS).features


def test_a_later_step_read_moves_only_movement():
    app = features(APP_IMPORT)
    widget = features(STEP_READ, {domain: APP_IMPORT for domain in OTHERS})

    assert (app.movement.steps, widget.movement.steps) == (3000, 5200)
    assert widget.movement.as_of == STEP_READ
    for domain in ("sleep", "hrv", "rhr", "workout"):
        before = getattr(app, domain).model_dump(exclude={"confidence"})
        assert getattr(widget, domain).model_dump(exclude={"confidence"}) == before, domain
    assert widget.hrv.value is None                           # the only HRV today (12:00) is past the cutoff
    assert widget.workout.last_workout_end is None            # so is the 11:45 run
    assert widget.sleep.confidence > 0 and widget.rhr.confidence > 0  # coverage checked to the cutoff only


def test_without_cutoffs_the_later_time_needs_coverage_it_does_not_have():
    late = features(STEP_READ)
    assert late.sleep.confidence == 0 and late.workout.state == "missing"


def test_a_cutoff_cannot_be_after_the_result():
    with pytest.raises(ValueError, match="cutoff"):
        CalculationContext(day=DAY, timezone=ZONE, effective_at=APP_IMPORT, known_at=STEP_READ,
                           cutoffs={"sleep": STEP_READ})


def test_no_cutoffs_keeps_the_original_report_shape():
    context = CalculationContext(day=DAY, timezone=ZONE, effective_at=APP_IMPORT, known_at=APP_IMPORT)
    assert "cutoffs" not in context.model_dump()
    assert context.cutoff("sleep") == APP_IMPORT
