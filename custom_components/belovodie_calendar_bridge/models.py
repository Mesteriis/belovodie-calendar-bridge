"""Strict, immutable Snapshot v1 wire model."""

import re
from dataclasses import dataclass
from datetime import date, datetime
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

_DIGEST = re.compile(r"[0-9a-f]{64}\Z")
_INSTANT = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+(?:Z|[+-]\d{2}:\d{2})\Z")
_DATE = re.compile(r"\d{4}-\d{2}-\d{2}\Z")


def _fields(value, required, optional=()):
    if (
        type(value) is not dict
        or not set(required) <= value.keys()
        or value.keys() - set(required) - set(optional)
    ):
        raise ValueError("Invalid snapshot fields")


def _text(value):
    if not isinstance(value, str):
        raise ValueError("Invalid snapshot text")  # noqa: TRY004 - all wire rejection uses ValueError
    return value


def _digest(value):
    if not isinstance(value, str) or not _DIGEST.fullmatch(value):
        raise ValueError("Invalid opaque identifier")
    return value


def instant(value):
    if not isinstance(value, str) or not _INSTANT.fullmatch(value):
        raise ValueError("Expected fractional RFC3339 instant with offset")
    return datetime.fromisoformat(value)


def _marker(value):
    parts = "".join(value.split()).split(":")
    if len(parts) != 6 or parts[:2] != ["belovodie-busy", "v1"]:
        return False
    try:
        UUID(parts[2])
    except ValueError:
        return False
    return all(
        re.fullmatch(r"[a-fA-F0-9]{64}", p) for p in [parts[3], parts[4], *parts[5].split(",")]
    )


@dataclass(frozen=True)
class Event:
    id: str
    title: str
    start: datetime
    end: datetime
    is_all_day: bool
    time_zone_id: str
    start_date: date | None = None
    end_date: date | None = None


@dataclass(frozen=True)
class Calendar:
    id: str
    owner: str
    label: str
    local_health: str
    observed_at: datetime
    last_successful_observed_at: datetime | None
    events: tuple[Event, ...] | None


@dataclass(frozen=True)
class Snapshot:
    observed_at: datetime
    range_start: datetime
    range_end: datetime
    calendars: tuple[Calendar, ...]
    removals: tuple[str, ...]


def _event(data, start, end):
    _fields(
        data, ("id", "title", "start", "end", "isAllDay", "timeZoneID"), ("startDate", "endDate")
    )
    event_id, title = _digest(data["id"]), _text(data["title"])
    if _marker(title):
        raise ValueError("Ownership marker is not an original")
    event_start, event_end = instant(data["start"]), instant(data["end"])
    if event_start >= event_end or event_start >= end or event_end <= start:
        raise ValueError("Invalid event interval")
    if type(data["isAllDay"]) is not bool:
        raise ValueError("Invalid all-day flag")
    try:
        zone = ZoneInfo(_text(data["timeZoneID"]))
    except (ZoneInfoNotFoundError, ValueError) as err:
        raise ValueError("Invalid event timezone") from err
    start_date = end_date = None
    if data["isAllDay"]:
        for key in ("startDate", "endDate"):
            if key not in data or not isinstance(data[key], str) or not _DATE.fullmatch(data[key]):
                raise ValueError("Invalid all-day date")
        start_date, end_date = (
            date.fromisoformat(data["startDate"]),
            date.fromisoformat(data["endDate"]),
        )
        if start_date >= end_date:
            raise ValueError("Invalid all-day interval")
        for boundary, day in ((event_start, start_date), (event_end, end_date)):
            local = boundary.astimezone(zone)
            if local.date() != day or any(
                (local.hour, local.minute, local.second, local.microsecond)
            ):
                raise ValueError("All-day boundary must be local midnight")
    elif "startDate" in data or "endDate" in data:
        raise ValueError("Timed event cannot carry all-day dates")
    return Event(
        event_id,
        title,
        event_start,
        event_end,
        data["isAllDay"],
        data["timeZoneID"],
        start_date,
        end_date,
    )


def validate_snapshot(data: dict) -> Snapshot:
    """Reject an entire malformed publication before it can alter stored data."""
    _fields(data, ("version", "observedAt", "window", "calendars", "removals"))
    if type(data["version"]) is not int or data["version"] != 1:
        raise ValueError("Unsupported snapshot version")
    observed = instant(data["observedAt"])
    _fields(data["window"], ("start", "end"))
    start, end = instant(data["window"]["start"]), instant(data["window"]["end"])
    if start >= end or type(data["calendars"]) is not list or type(data["removals"]) is not list:
        raise ValueError("Invalid snapshot interval or inventory")
    seen = set()
    calendars = []
    for row in data["calendars"]:
        _fields(
            row,
            ("id", "owner", "label", "localHealth", "remoteHealth", "observedAt"),
            ("events", "lastSuccessfulObservedAt"),
        )
        cid = _digest(row["id"])
        if cid in seen:
            raise ValueError("Duplicate calendar")
        seen.add(cid)
        health = row["localHealth"]
        row_observed = instant(row["observedAt"])
        if (
            health not in ("complete", "failed", "missing")
            or row["remoteHealth"] != "unknown"
            or row_observed != observed
        ):
            raise ValueError("Invalid source health observation")
        events = successful = None
        if health == "complete":
            if (
                "events" not in row
                or type(row["events"]) is not list
                or "lastSuccessfulObservedAt" not in row
            ):
                raise ValueError("Complete source requires events and successful observation")
            successful = instant(row["lastSuccessfulObservedAt"])
            if successful != row_observed:
                raise ValueError("Invalid successful observation")
            events = tuple(_event(event, start, end) for event in row["events"])
            if len({event.id for event in events}) != len(events):
                raise ValueError("Duplicate event")
        elif "events" in row or "lastSuccessfulObservedAt" in row:
            raise ValueError("Health-only update cannot replace successful data")
        calendars.append(
            Calendar(
                cid,
                _text(row["owner"]),
                _text(row["label"]),
                health,
                row_observed,
                successful,
                events,
            )
        )
    removals = []
    for row in data["removals"]:
        _fields(row, ("id", "reason"))
        cid = _digest(row["id"])
        if cid in seen or row["reason"] not in ("exportDisabled", "confirmedRemoved"):
            raise ValueError("Invalid or duplicate removal")
        seen.add(cid)
        removals.append(cid)
    return Snapshot(observed, start, end, tuple(calendars), tuple(removals))
