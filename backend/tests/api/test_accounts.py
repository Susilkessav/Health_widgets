"""Device keys and pairing codes (multi-user sign-in)."""
import secrets
from datetime import timedelta
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from tests.api.test_api import KEY, FixedClock, payload, runtime
from tests.db.test_ingest import NOW, USER, hrv

pytestmark = pytest.mark.db


def device(name="iPhone"):
    return {"device_id": str(uuid4()), "token": secrets.token_hex(32), "name": name}


def bearer(registered):
    return {"Authorization": f"Bearer {registered['token']}"}


@pytest.fixture
def production(db_engine):
    clock = FixedClock(NOW)
    with TestClient(create_app(runtime(development=False), clock=clock, engine=db_engine)) as client:
        yield client, clock


def test_enrollment_key_creates_accounts_but_signs_nobody_in(production):
    client, _ = production
    first, second = device(), device()
    assert client.post("/v1/accounts", json=first).status_code == 401  # needs the enrollment key
    one = client.post("/v1/accounts", headers=KEY, json=first).json()
    two = client.post("/v1/accounts", headers=KEY, json=second).json()
    assert one["account_id"] == str(USER)  # the first account keeps the development user's data
    assert two["account_id"] != one["account_id"]  # later ones are separate people
    assert client.get("/v1/account", headers=KEY).status_code == 401  # outside development
    assert client.get("/v1/account", headers=bearer(first)).json() == {"account_id": one["account_id"]}
    # A retry returns the same account; reusing the ID with another token doesn't.
    assert client.post("/v1/accounts", headers=KEY, json=first).json() == one
    assert client.post("/v1/accounts", headers=KEY, json={**first, "token": secrets.token_hex(32)}).status_code == 409


def test_accounts_see_only_their_own_data(production):
    client, _ = production
    first, second = device(), device()
    client.post("/v1/accounts", headers=KEY, json=first)
    client.post("/v1/accounts", headers=KEY, json=second)
    assert client.post("/v1/health/sync", headers=bearer(first), json=payload([hrv()])).status_code == 200
    run = client.get("/v1/state/current", headers=bearer(first)).json()
    assert client.get("/v1/state/current", headers=bearer(second)).json() == {"code": "NO_STATE_YET"}
    assert client.get(f"/v1/state/runs/{run['run_id']}", headers=bearer(second)).status_code == 404


def test_pairing_code_adds_a_device_to_the_same_account_once(production):
    client, clock = production
    phone, ipad, stranger = device("iPhone"), device("iPad"), device("Other")
    account = client.post("/v1/accounts", headers=KEY, json=phone).json()["account_id"]
    code = client.post("/v1/pairing-codes", headers=bearer(phone)).json()["code"]
    assert len(code) == 9 and code[4] == "-"
    paired = client.post("/v1/devices/pair", json={**ipad, "code": code.lower().replace("-", " ")})
    assert paired.json() == {"account_id": account, "device_id": ipad["device_id"]}
    assert client.post("/v1/devices/pair", json={**ipad, "code": code}).json() == paired.json()  # retry
    assert client.post("/v1/devices/pair", json={**stranger, "code": code}).json() == {"code": "INVALID_PAIRING_CODE"}
    listed = client.get("/v1/devices", headers=bearer(ipad)).json()["devices"]
    assert [(d["name"], d["current"]) for d in listed] == [("iPhone", False), ("iPad", True)]

    expired = client.post("/v1/pairing-codes", headers=bearer(phone)).json()["code"]
    clock.now = NOW + timedelta(minutes=11)
    assert client.post("/v1/devices/pair", json={**stranger, "code": expired}).status_code == 401


def test_removing_a_device_signs_it_out_and_revokes_its_widget(production):
    client, _ = production
    phone, lost = device(), device()
    client.post("/v1/accounts", headers=KEY, json=phone)
    code = client.post("/v1/pairing-codes", headers=bearer(phone)).json()["code"]
    client.post("/v1/devices/pair", json={**lost, "code": code})
    widget = secrets.token_hex(32)
    assert client.post("/v1/widget/credentials", headers=bearer(lost), json={
        "operation_id": str(uuid4()), "installation_id": str(uuid4()), "token": widget}).status_code == 200
    assert client.get("/v1/widget/current", headers={"Authorization": f"Bearer {widget}"}).status_code == 200

    assert client.delete(f"/v1/devices/{lost['device_id']}", headers=bearer(phone)).json() == {"revoked": True}
    assert client.get("/v1/account", headers=bearer(lost)).status_code == 401
    assert client.get("/v1/widget/current", headers={"Authorization": f"Bearer {widget}"}).status_code == 401
    assert client.post("/v1/pairing-codes", headers=bearer(lost)).status_code == 401
    assert client.get("/v1/account", headers=bearer(phone)).status_code == 200


def test_a_device_cannot_remove_another_accounts_device(production):
    client, _ = production
    mine, theirs = device(), device()
    client.post("/v1/accounts", headers=KEY, json=mine)
    client.post("/v1/accounts", headers=KEY, json=theirs)
    assert client.delete(f"/v1/devices/{theirs['device_id']}", headers=bearer(mine)).status_code == 404
    assert client.get("/v1/account", headers=bearer(theirs)).status_code == 200


def test_development_key_still_signs_in_as_the_development_user(api):
    client, _ = api
    assert client.get("/v1/account", headers=KEY).json() == {"account_id": str(USER)}
    # ...but it can't mint pairing codes: those belong to a device.
    assert client.post("/v1/pairing-codes", headers=KEY).json() == {"code": "DEVICE_KEY_REQUIRED"}


from tests.api.test_api import api  # noqa: E402,F401  (fixture)
