"""Store a synthetic dataset directly (bypassing the API) for storage tests."""
from uuid import UUID

from app import store
from app.contracts._types import utc
from app.features.models import DOMAINS, CoverageWindow

USER = UUID("00000000-0000-4000-8000-00000000000a")


def store_dataset(engine, dataset, user_id=USER):
    """One revision per delivery batch, received at its delivery time."""
    events = {event.event_id: event for event in dataset.events}
    zone = dataset.context.timezone
    with engine.begin() as conn:
        store.ensure_user(conn, user_id, zone)
        revision, received = store.next_revision(conn, user_id, dataset.deliveries[0].delivered_at
                                                 if dataset.deliveries else dataset.context.checkpoints[0].known_at)
        store.insert_coverage(conn, user_id, [
            CoverageWindow(domain=d, start_day=w.start_day, end_day=w.end_day, timezone=zone,
                           status=getattr(w.domains, d)) for w in dataset.context.coverage for d in DOMAINS],
            revision, received)
        for batch in dataset.deliveries:
            revision, received = store.next_revision(conn, user_id, batch.delivered_at)
            for event_id in batch.event_ids:
                event = events[event_id]
                digest = store.content_sha256(event)
                if store.find_version(conn, user_id, store.identity(event), digest) is None:
                    store.insert_version(conn, user_id, event, digest, revision, utc(batch.delivered_at))
    return user_id
