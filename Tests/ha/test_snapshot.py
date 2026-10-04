"""Contract regression tests; all payloads use synthetic public data."""

from copy import deepcopy

import homeassistant  # noqa: F401 - initialize HA's validation runtime before component imports
import pytest
from custom_components.belovodie_calendar_bridge.models import validate_snapshot

A = "a" * 64
B = "b" * 64
C = "c" * 64
OBS = "2026-03-29T10:00:00.000Z"


def payload(observed=OBS):
    return {
        "version": 1,
        "observedAt": observed,
        "window": {"start": "2026-03-22T00:00:00.000Z", "end": "2026-06-27T00:00:00.000Z"},
        "calendars": [
            {
                "id": A,
                "owner": "Owner",
                "label": "Personal",
                "localHealth": "complete",
                "remoteHealth": "unknown",
                "observedAt": observed,
                "lastSuccessfulObservedAt": observed,
                "events": [
                    {
                        "id": B,
                        "title": "Synthetic original",
                        "start": "2026-03-29T12:00:00.000+02:00",
                        "end": "2026-03-29T13:00:00.000+02:00",
                        "isAllDay": False,
                        "timeZoneID": "Europe/Madrid",
                    }
                ],
            }
        ],
        "removals": [],
    }


def test_valid_snapshot_retains_originals():
    snapshot = validate_snapshot(payload())
    assert snapshot.calendars[0].events[0].title == "Synthetic original"
    assert snapshot.calendars[0].events[0].start.utcoffset().total_seconds() == 7200


@pytest.mark.parametrize(
    "mutation",
    [
        lambda p: p.update(version=True),
        lambda p: p.update(providerID="private"),
        lambda p: p.update(observedAt="2026-03-29T10:00:00.000"),
        lambda p: p["calendars"].append(deepcopy(p["calendars"][0])),
        lambda p: p["calendars"][0]["events"].append(deepcopy(p["calendars"][0]["events"][0])),
        lambda p: p["calendars"][0].update(accountID="private"),
        lambda p: p["calendars"][0].update(remoteHealth="healthy"),
        lambda p: p["calendars"][0].update(lastSuccessfulObservedAt="2026-03-30T10:00:00.000Z"),
        lambda p: p["calendars"][0]["events"][0].update(eventID="private"),
        lambda p: p["calendars"][0]["events"][0].update(notes="belovodie-busy:v1:private"),
        lambda p: p["calendars"][0]["events"][0].update(start="2026-03-29T12:00:00"),
        lambda p: p["calendars"][0]["events"][0].update(end="2026-03-29T10:00:00.000Z"),
        lambda p: p["calendars"][0]["events"][0].update(timeZoneID="invalid/zone"),
        lambda p: p["calendars"][0]["events"][0].update(startDate="2026-03-29"),
        lambda p: p["calendars"][0]["events"][0].update(
            start="2027-03-29T10:00:00.000Z", end="2027-03-29T11:00:00.000Z"
        ),
        lambda p: p["removals"].append({"id": A, "reason": "confirmedRemoved"}),
        lambda p: p["removals"].append({"id": C, "reason": "missing"}),
        lambda p: p["calendars"][0].update(localHealth="failed"),
    ],
)
def test_invalid_contract_is_rejected(mutation):
    data = payload()
    mutation(data)
    with pytest.raises(ValueError):
        validate_snapshot(data)


def test_all_day_preserves_dst_midnight_boundaries():
    data = payload()
    data["calendars"][0]["events"][0].update(
        start="2026-03-29T00:00:00.000+01:00",
        end="2026-03-30T00:00:00.000+02:00",
        isAllDay=True,
        startDate="2026-03-29",
        endDate="2026-03-30",
    )
    event = validate_snapshot(data).calendars[0].events[0]
    assert (event.end.timestamp() - event.start.timestamp()) == 23 * 3600
    data["calendars"][0]["events"][0]["start"] = "2026-03-29T00:00:00.000Z"
    with pytest.raises(ValueError):
        validate_snapshot(data)


def test_ownership_marker_is_not_an_original_title():
    data = payload()
    data["calendars"][0]["events"][0]["title"] = (
        "belovodie-busy:v1:00000000-0000-0000-0000-000000000000:" + f"{A}:{B}:{C}"
    )
    with pytest.raises(ValueError):
        validate_snapshot(data)
    data["calendars"][0]["events"][0]["title"] = "Занято"
    assert validate_snapshot(data).calendars[0].events[0].title == "Занято"


@pytest.mark.parametrize(
    "offset", ["+01:60", "+01:99", "-01:60", "-01:99", "+24:00", "-24:00", "+99:00", "-99:00"]
)
def test_invalid_timezone_offset_components_are_rejected(offset):
    data = payload()
    data["calendars"][0]["events"][0].update(
        start=f"2026-03-29T12:00:00.000{offset}",
        end=f"2026-03-29T13:00:00.000{offset}",
    )
    with pytest.raises(ValueError):
        validate_snapshot(data)


@pytest.mark.parametrize(
    ("offset", "seconds"),
    [("Z", 0), ("+00:00", 0), ("-00:00", 0), ("+23:59", 86340), ("-23:59", -86340)],
)
def test_valid_timezone_offset_boundaries_are_preserved(offset, seconds):
    data = payload()
    data["calendars"][0]["events"][0].update(
        start=f"2026-03-29T12:00:00.000{offset}",
        end=f"2026-03-29T13:00:00.000{offset}",
    )
    event = validate_snapshot(data).calendars[0].events[0]
    assert event.start.utcoffset().total_seconds() == seconds
    assert event.end.utcoffset().total_seconds() == seconds
