"""WidgetState: what a surface needs to render right now (plan_G1.md
sections 45-46). It's flat and has no health-calculation vocabulary, because
the widget decodes it directly and must never re-derive meaning from it.
"""
from __future__ import annotations

from typing import Literal

from pydantic import AwareDatetime

from app.contracts._types import Frozen, NonEmptyStr
from app.contracts.avatar_state import AvatarState


class Presentation(Frozen):
    icon: NonEmptyStr
    headline: NonEmptyStr
    detail: NonEmptyStr | None = None
    secondary: NonEmptyStr | None = None


class PrimaryTrait(Frozen):
    id: NonEmptyStr
    explainable: bool


class Freshness(Frozen):
    last_updated_at: AwareDatetime


class WidgetState(Frozen):
    # 0.2.0 adds `avatar` (G2). The widget still reads 0.1.x caches.
    version: Literal["widget-state@0.2.0"] = "widget-state@0.2.0"
    effective_at: AwareDatetime

    presentation: Presentation
    primary_trait: PrimaryTrait
    freshness: Freshness
    avatar: AvatarState
