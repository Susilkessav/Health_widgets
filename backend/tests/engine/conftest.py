"""Contract-valid DailyFeatures for any combination of domain states."""
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from app.config import Settings, settings_sha256
from app.contracts.features import DailyFeatures

SETTINGS = Settings()
CONFIG = settings_sha256(SETTINGS)
CHI = ZoneInfo("America/Chicago")
DAY = date(2026, 9, 22)
NOW = datetime(2026, 9, 22, 13, 0, tzinfo=CHI)
WAKE = datetime(2026, 9, 22, 7, 0, tzinfo=CHI)

SLEEP_STATES = ("below_baseline", "typical", "above_baseline", "missing", "calibrating")
POINT_STATES = ("below_usual", "typical", "above_usual", "missing", "calibrating")
MOVEMENT_STATES = ("behind_usual", "typical", "ahead_of_usual", "missing", "calibrating")
WORKOUT_STATES = ("just_completed", "recent_workout", "none_recent", "missing")  # G1 never emits active
READY = {"baseline_status": "ready", "usable_days": 28, "required_days": 14}
CALIBRATING = {"baseline_status": "calibrating", "usable_days": 5, "required_days": 14, "state": "calibrating"}


def sleep_block(state="typical", confidence=1.0, hours=None):
    if state == "missing":
        return {**READY, "state": state, "confidence": confidence, "baseline_hours": 7.5, "baseline_mad_hours": 0.25}
    hours = hours if hours is not None else {"below_baseline": 5.5, "above_baseline": 9.5}.get(state, 7.5)
    episode = {"hours": hours, "sleep_start": WAKE - timedelta(hours=hours), "sleep_end": WAKE, "span_hours": hours,
               "timezone": "America/Chicago", "source": "synthetic_watch",
               "source_policy_version": "sleep-source-policy@0.1.0"}
    if state == "calibrating":
        return {**CALIBRATING, "confidence": confidence, **episode}
    return {**READY, "state": state, "confidence": confidence, **episode, "baseline_hours": 7.5,
            "baseline_mad_hours": 0.25, "delta_hours": hours - 7.5, "ratio": hours / 7.5}


def point_block(domain, state="typical", confidence=1.0):
    center = 50.0 if domain == "hrv" else 60.0
    value = {"below_usual": center - 20, "above_usual": center + 20}.get(state, center)
    reading = {"value": value, "observed_at": WAKE + timedelta(minutes=15), "source_record_id": f"hk-{domain}",
               "source_name": "Synthetic Watch"}
    if state == "calibrating":
        return {**CALIBRATING, "confidence": confidence, **reading}
    baseline = {"baseline": center, "mad": 3.0}
    if state == "missing":
        return {**READY, "state": state, "confidence": confidence, **baseline}
    return {**READY, "state": state, "confidence": confidence, **reading, **baseline,
            "robust_z": (value - center) / 4.4478}


def movement_block(state="typical", confidence=1.0):
    snapshot = {"steps": {"behind_usual": 2000, "ahead_of_usual": 8000}.get(state, 5200), "as_of": NOW,
                "source_record_id": "steps:x"}
    if state == "calibrating":
        return {**CALIBRATING, "confidence": confidence, **snapshot}
    if state == "missing":
        return {**READY, "state": state, "confidence": confidence, "expected_steps_now": 5200.0}
    return {**READY, "state": state, "confidence": confidence, **snapshot, "expected_steps_now": 5200.0,
            "ratio": snapshot["steps"] / 5200}


def workout_block(state="none_recent", confidence=1.0, workout_type="traditional_strength_training"):
    if state == "missing":
        return {"state": state, "confidence": confidence}
    block = {"state": state, "confidence": confidence, "workout_minutes_today": 0, "workout_minutes_last_7d": 0}
    ago = {"just_completed": 1, "recent_workout": 6, "active": 0.5}.get(state)
    if ago is not None:
        end = NOW - timedelta(hours=ago)
        block.update(type=workout_type, last_workout_start=end - timedelta(minutes=30), last_workout_end=end,
                     source_record_id="hk-workout", source_name="Synthetic Watch", hours_since=ago,
                     workout_minutes_today=30, workout_minutes_last_7d=30)
    return block


def features(sleep="typical", hrv="typical", rhr="typical", movement="typical", workout="none_recent",
             confidence=None, **overrides) -> DailyFeatures:
    c = {"sleep": 1.0, "hrv": 1.0, "rhr": 1.0, "movement": 1.0, "workout": 1.0, **(confidence or {})}
    data = {
        "config_sha256": CONFIG, "day": DAY, "timezone": "America/Chicago", "effective_at": NOW,
        "sleep": sleep_block(sleep, c["sleep"]), "hrv": point_block("hrv", hrv, c["hrv"]),
        "rhr": point_block("rhr", rhr, c["rhr"]), "movement": movement_block(movement, c["movement"]),
        "workout": workout_block(workout, c["workout"]),
    }
    return DailyFeatures.model_validate({**data, **overrides})
