"""Stream limits do not require a database or buffering the remaining body."""
import asyncio

import pytest
from starlette.requests import Request

from app.main import BodyTooLarge, bounded_body


def request(chunks, consumed):
    pending = iter(chunks)

    async def receive():
        chunk = next(pending)
        consumed.append(chunk)
        return {"type": "http.request", "body": chunk, "more_body": bool(chunk)}

    return Request({"type": "http", "headers": []}, receive)


def test_exact_limit_keeps_the_original_bytes():
    consumed = []
    assert asyncio.run(bounded_body(request([b"abc", b"def", b""], consumed), 6)) == b"abcdef"


def test_oversize_stream_stops_before_receiving_the_remaining_body():
    consumed = []
    with pytest.raises(BodyTooLarge):
        asyncio.run(bounded_body(request([b"abc", b"defg", b"never read", b""], consumed), 6))
    assert consumed == [b"abc", b"defg"]


def test_empty_stream_is_allowed():
    assert asyncio.run(bounded_body(request([b""], []), 6)) == b""
