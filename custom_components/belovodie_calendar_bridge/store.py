"""Serialized, durable last-successful cache; no transport credentials."""

import asyncio
import hashlib
import json
from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime, timedelta
from types import MappingProxyType

from homeassistant.core import HomeAssistant
from homeassistant.helpers.dispatcher import async_dispatcher_send
from homeassistant.helpers.storage import Store

from .models import Calendar, Event, instant, validate_snapshot

DOMAIN = "belovodie_calendar_bridge"
SIGNAL_UPDATED = f"{DOMAIN}_updated"


@dataclass(frozen=True)
class CachedCalendar:
    calendar: Calendar
    events: tuple[Event, ...] | None
    last_successful_observed_at: datetime | None
    range_start: datetime | None
    range_end: datetime | None

    def stale_at(self, now: datetime) -> bool:
        return (
            self.last_successful_observed_at is None
            or now - self.last_successful_observed_at >= timedelta(minutes=15)
        )


def _decode(records):
    calendars = {}
    for cid, record in records.items():
        observation = validate_snapshot(record["observation"])
        if (
            len(observation.calendars) != 1
            or observation.removals
            or observation.calendars[0].id != cid
        ):
            raise ValueError("Invalid cached calendar observation")
        current = observation.calendars[0]
        success = observation if current.local_health == "complete" else None
        if record["successful"] is not None:
            success = validate_snapshot(record["successful"])
            if (
                len(success.calendars) != 1
                or success.removals
                or success.calendars[0].id != cid
                or success.calendars[0].local_health != "complete"
                or success.observed_at > observation.observed_at
            ):
                raise ValueError("Invalid successful calendar cache")
        calendars[cid] = CachedCalendar(
            current,
            success.calendars[0].events if success else None,
            success.calendars[0].last_successful_observed_at if success else None,
            success.range_start if success else None,
            success.range_end if success else None,
        )
    return MappingProxyType(calendars)


class SnapshotStore:
    """Commit disk before exposing memory, including ordering across restarts."""

    def __init__(self, hass: HomeAssistant):
        self.hass = hass
        self._storage = Store(hass, 1, DOMAIN, private=True, atomic_writes=True)
        self._lock = asyncio.Lock()
        self._state = {"observedAt": None, "digest": None, "records": {}}
        self.calendars = MappingProxyType({})

    async def async_load(self):
        async with self._lock:
            state = await self._storage.async_load()
            if state is None:
                return
            if (
                type(state) is not dict
                or set(state) != {"observedAt", "digest", "records"}
                or type(state["records"]) is not dict
            ):
                raise ValueError("Invalid stored snapshot state")
            observed = instant(state["observedAt"])
            if not isinstance(state["digest"], str) or len(state["digest"]) != 64:
                raise ValueError("Invalid stored snapshot fingerprint")
            calendars = _decode(state["records"])
            if any(row.calendar.observed_at > observed for row in calendars.values()):
                raise ValueError("Invalid stored observation ordering")
            self._state, self.calendars = state, calendars

    async def async_publish(self, data: dict) -> bool:
        data = deepcopy(data)
        snapshot = validate_snapshot(data)
        digest = hashlib.sha256(
            json.dumps(data, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
        ).hexdigest()
        async with self._lock:
            previous_time = self._state["observedAt"]
            if previous_time is not None:
                previous = instant(previous_time)
                if snapshot.observed_at < previous:
                    return False
                if snapshot.observed_at == previous:
                    if digest != self._state["digest"]:
                        raise ValueError("Conflicting snapshot observation")
                    return False
            records = dict(self._state["records"])
            for row in data["calendars"]:
                single = {**data, "calendars": [row], "removals": []}
                successful = None
                if row["localHealth"] != "complete" and row["id"] in records:
                    old = records[row["id"]]
                    successful = (
                        old["observation"]
                        if old["observation"]["calendars"][0]["localHealth"] == "complete"
                        else old["successful"]
                    )
                records[row["id"]] = {"observation": single, "successful": successful}
            for cid in snapshot.removals:
                records.pop(cid, None)
            state = {"observedAt": data["observedAt"], "digest": digest, "records": records}
            calendars = _decode(records)
            await self._storage.async_save(state)
            self._state, self.calendars = state, calendars
            async_dispatcher_send(self.hass, SIGNAL_UPDATED)
            return True
