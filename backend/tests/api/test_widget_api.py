"""Widget reads cannot ingest, expose explanations, or change revisions."""
from uuid import uuid4

from sqlalchemy import func, select, update

from app.db import health_events, recalc_jobs, widget_credentials, users
from tests.api.test_api import api, KEY, payload
from tests.db.test_ingest import USER, hrv, NOW


def provision(client, **overrides):
    body = dict(operation_id=str(uuid4()), installation_id=str(uuid4()), token=uuid4().hex + uuid4().hex)
    body.update(overrides)
    response = client.post('/v1/widget/credentials', headers=KEY, json=body)
    assert response.status_code == 200, response.text
    return body, {'Authorization': 'Bearer ' + body['token']}


def test_identity_provision_idempotency_and_revocation(api, db_engine):
    client, _ = api
    assert client.get('/v1/account', headers=KEY).json() == {'account_id': str(USER)}
    assert client.post('/v1/widget/credentials', json={}).status_code == 401
    body, auth = provision(client)
    assert client.post('/v1/widget/credentials', headers=KEY, json=body).json()['revoked'] is False
    assert client.post('/v1/widget/credentials', headers=KEY, json={**body, 'token': 'b' * 64}).status_code == 409
    with db_engine.connect() as conn:
        row = conn.execute(select(widget_credentials)).one()
        assert row.token_sha256 != body['token']
        assert conn.execute(select(func.count()).select_from(health_events)).scalar_one() == 0
    assert client.get('/v1/widget/current', headers=auth).json()['calculation_status'] == 'no_state'
    assert client.delete('/v1/widget/credentials/' + body['operation_id'], headers=KEY).status_code == 200
    assert client.get('/v1/widget/current', headers=auth).status_code == 401
    assert client.post('/v1/widget/credentials', headers=KEY, json=body).json()['revoked'] is True
    assert client.get('/v1/widget/current', headers=auth).status_code == 401


def test_widget_token_is_read_only_and_reads_do_not_write(api, db_engine):
    client, _ = api
    _, auth = provision(client)
    client.post('/v1/health/sync', headers=KEY, json=payload([hrv()]))
    assert client.post('/v1/health/sync', headers=auth, json=payload()).status_code == 401
    assert client.get('/v1/state/current', headers=auth).status_code == 401
    with db_engine.connect() as conn:
        revision = conn.execute(select(users.c.revision).where(users.c.id == USER)).scalar_one()
        count = conn.execute(select(func.count()).select_from(health_events)).scalar_one()
    for _ in range(3):
        response = client.get('/v1/widget/current', headers=auth)
        assert response.headers['cache-control'] == 'no-store'
        compact = response.json()
        assert compact['accepted_revision'] == revision
        assert compact['published']['widget_state']['presentation']['headline']
        assert 'health_state' not in compact['published']
    with db_engine.connect() as conn:
        assert conn.execute(select(users.c.revision).where(users.c.id == USER)).scalar_one() == revision
        assert conn.execute(select(func.count()).select_from(health_events)).scalar_one() == count
    run_id = compact['published']['run_id']
    exact = client.get(f'/v1/state/runs/{run_id}', headers=KEY)
    assert exact.status_code == 200
    assert exact.json()['run_id'] == run_id
    assert 'health_state' in exact.json() and 'is_today' in exact.json()
    assert client.get(f'/v1/state/runs/{run_id}', headers=auth).status_code == 401
    assert client.get('/v1/state/runs/999999', headers=KEY).status_code == 404


def test_pending_and_failed_same_revision_finalize_is_visible(api, db_engine):
    client, _ = api
    _, auth = provision(client)
    client.post('/v1/health/sync', headers=KEY, json=payload([hrv()]))
    published = client.get('/v1/widget/current', headers=auth).json()
    with db_engine.begin() as conn:
        conn.execute(recalc_jobs.insert().values(user_id=USER, kind='finalize',
            target_revision=published['accepted_revision'], from_day=NOW.date(), status='pending',
            attempts=0, next_attempt_at=NOW, created_at=NOW))
    pending = client.get('/v1/widget/current', headers=auth).json()
    assert pending['calculation_status'] == 'pending'
    assert pending['published'] == published['published']
    with db_engine.begin() as conn:
        conn.execute(update(recalc_jobs).where(recalc_jobs.c.status == 'pending').values(attempts=1))
    assert client.get('/v1/widget/current', headers=auth).json()['calculation_status'] == 'failed'


def test_exact_run_and_revocation_enforce_owner(api, db_engine):
    from dataclasses import replace
    from fastapi.testclient import TestClient
    from app.main import create_app
    from tests.api.test_api import runtime
    client, clock = api
    body, auth = provision(client)
    client.post('/v1/health/sync', headers=KEY, json=payload([hrv()]))
    run_id = client.get('/v1/widget/current', headers=auth).json()['published']['run_id']
    with TestClient(create_app(replace(runtime(), dev_user_id=uuid4()), clock=clock, engine=db_engine)) as other:
        assert other.get(f'/v1/state/runs/{run_id}', headers=KEY).status_code == 404
        other.delete('/v1/widget/credentials/' + body['operation_id'], headers=KEY)
    assert client.get('/v1/widget/current', headers=auth).status_code == 200


def test_app_key_rotation_preserves_account_and_widget_access(api, db_engine):
    from dataclasses import replace
    from fastapi.testclient import TestClient
    from app.main import create_app
    from tests.api.test_api import runtime
    client, clock = api
    _, auth = provision(client)
    with TestClient(create_app(replace(runtime(), api_key='rotated'), clock=clock, engine=db_engine)) as rotated:
        assert rotated.get('/v1/account', headers=KEY).status_code == 401
        assert rotated.get('/v1/account', headers={'X-Homeostat-Key': 'rotated'}).json()['account_id'] == str(USER)
        assert rotated.get('/v1/widget/current', headers=auth).status_code == 200
