"""Native HA cache, calendar and service regressions using temporary state."""

import asyncio
from copy import deepcopy
from datetime import UTC, datetime, timedelta

import homeassistant  # noqa: F401 - initialize HA's validation runtime before component imports
import pytest
from custom_components.belovodie_calendar_bridge.calendar import BridgeCalendar
from custom_components.belovodie_calendar_bridge.store import SnapshotStore
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import HomeAssistantError
from test_snapshot import A, B, C, payload

NOW = datetime(2026, 3, 29, 10, tzinfo=UTC)


def native(test):
    def run(tmp_path):
        async def execute():
            hass = HomeAssistant(str(tmp_path))
            try:
                await test(hass)
            finally:
                await hass.async_stop(force=True)

        asyncio.run(execute())

    return run


def failed(observed="2026-03-29T10:05:00.000Z"):
    data = payload(observed)
    row = data["calendars"][0]
    row["localHealth"] = "failed"
    del row["events"], row["lastSuccessfulObservedAt"]
    data["window"]["end"] = "2026-07-27T00:00:00.000Z"
    return data


@native
async def test_health_only_retains_successful_window_and_persists(hass):
    store = SnapshotStore(hass)
    await store.async_load()
    await store.async_publish(payload())
    await store.async_publish(failed())
    cached = store.calendars[A]
    assert cached.calendar.local_health == "failed"
    assert cached.events[0].title == "Synthetic original"
    assert cached.last_successful_observed_at == NOW
    assert cached.range_end == datetime(2026, 6, 27, tzinfo=UTC)
    reopened = SnapshotStore(hass)
    await reopened.async_load()
    assert reopened.calendars[A] == cached
    path = __import__("pathlib").Path(hass.config.path(".storage", "belovodie_calendar_bridge"))
    assert path.exists()
    assert path.stat().st_mode & 0o077 == 0


@native
async def test_omission_preserves_and_only_confirmed_removal_deletes(hass):
    store = SnapshotStore(hass)
    await store.async_publish(payload())
    data = payload("2026-03-29T10:05:00.000Z")
    data["calendars"] = []
    await store.async_publish(data)
    assert A in store.calendars
    data = payload("2026-03-29T10:06:00.000Z")
    data["calendars"] = []
    data["removals"] = [{"id": A, "reason": "confirmedRemoved"}]
    await store.async_publish(data)
    assert A not in store.calendars
    await store.async_publish(payload())
    assert A not in store.calendars
    reopened = SnapshotStore(hass)
    await reopened.async_load()
    await reopened.async_publish(payload())
    assert A not in reopened.calendars


@native
async def test_invalid_publish_and_storage_failure_never_replace_cache(hass):
    store = SnapshotStore(hass)
    await store.async_publish(payload())
    original = store.calendars[A]
    invalid = failed()
    invalid["calendars"][0]["events"] = []
    with pytest.raises(ValueError):
        await store.async_publish(invalid)
    assert store.calendars[A] == original

    # Simulate the actual disk failure boundary, retaining all merge logic.
    async def fail_write(data):
        raise OSError("synthetic disk failure")

    store._storage.async_save = fail_write
    with pytest.raises(OSError):
        await store.async_publish(failed())
    assert store.calendars[A] == original


@native
async def test_retries_conflicts_and_concurrent_ordering(hass):
    store = SnapshotStore(hass)
    assert await store.async_publish(payload()) is True
    assert await store.async_publish(payload()) is False
    changed = payload()
    changed["calendars"][0]["events"] = []
    with pytest.raises(ValueError):
        await store.async_publish(changed)
    newest = payload("2026-03-29T10:10:00.000Z")
    newest["calendars"][0]["events"] = []
    await asyncio.gather(store.async_publish(newest), store.async_publish(failed()))
    assert store.calendars[A].events == ()
    assert store.calendars[A].calendar.local_health == "complete"


@native
async def test_partial_failure_updates_other_source_and_empty_is_authoritative(hass):
    store = SnapshotStore(hass)
    data = payload()
    other = deepcopy(data["calendars"][0])
    other["id"] = C
    data["calendars"].append(other)
    await store.async_publish(data)
    data = failed()
    other = deepcopy(payload(data["observedAt"])["calendars"][0])
    other["id"] = C
    other["events"] = []
    data["calendars"].append(other)
    await store.async_publish(data)
    assert len(store.calendars[A].events) == 1
    assert store.calendars[C].events == ()


@native
async def test_calendar_names_overlaps_and_coverage_errors(hass):
    store = SnapshotStore(hass)
    await store.async_publish(payload())
    entity = BridgeCalendar(store, A)
    assert entity.name == "Owner · Personal"
    events = await entity.async_get_events(hass, NOW, NOW + timedelta(minutes=30))
    assert len(events) == 1 and events[0].summary == "Synthetic original"
    assert events[0].uid == B
    assert (
        await entity.async_get_events(hass, NOW + timedelta(hours=1), NOW + timedelta(hours=2))
        == []
    )
    with pytest.raises(HomeAssistantError):
        await entity.async_get_events(hass, NOW, datetime(2027, 1, 1, tzinfo=UTC))
    attrs = entity.extra_state_attributes
    assert attrs["range_end"] == "2026-06-27T00:00:00+00:00"
    assert attrs["last_successful_sync"] == "2026-03-29T10:00:00+00:00"
    assert attrs["remote_health"] == "unknown"


@native
async def test_uncached_is_unavailable_and_distinct_from_empty(hass):
    store = SnapshotStore(hass)
    await store.async_publish(failed())
    entity = BridgeCalendar(store, A)
    assert entity.available is False
    assert entity.extra_state_attributes["stale"] is True
    assert entity.extra_state_attributes["range_start"] is None
    with pytest.raises(HomeAssistantError):
        await entity.async_get_events(hass, NOW, NOW + timedelta(hours=1))


@native
async def test_all_day_calendar_uses_dates_and_stale_threshold(hass):
    store = SnapshotStore(hass)
    data = payload()
    data["calendars"][0]["events"][0].update(
        start="2026-03-29T00:00:00.000+01:00",
        end="2026-03-30T00:00:00.000+02:00",
        isAllDay=True,
        startDate="2026-03-29",
        endDate="2026-03-30",
    )
    await store.async_publish(data)
    entity = BridgeCalendar(store, A)
    result = await entity.async_get_events(hass, NOW, NOW + timedelta(hours=1))
    assert result[0].start.isoformat() == "2026-03-29"
    assert result[0].end.isoformat() == "2026-03-30"
    assert store.calendars[A].stale_at(NOW + timedelta(minutes=14, seconds=59)) is False
    assert store.calendars[A].stale_at(NOW + timedelta(minutes=15)) is True


async def setup_bridge(hass):
    import shutil
    from pathlib import Path

    from homeassistant import loader
    from homeassistant.auth import auth_manager_from_config
    from homeassistant.config_entries import ConfigEntries
    from homeassistant.setup import async_setup_component

    shutil.copytree(
        Path.cwd() / "custom_components", Path(hass.config.config_dir) / "custom_components"
    )
    from homeassistant.helpers import (
        area_registry,
        device_registry,
        entity_registry,
        floor_registry,
        label_registry,
    )

    device_registry.async_setup(hass)
    for registry in (
        floor_registry,
        area_registry,
        label_registry,
        device_registry,
        entity_registry,
    ):
        await registry.async_load(hass)
    hass.auth = await auth_manager_from_config(hass, [], [])
    from homeassistant.components.http import HomeAssistantHTTP

    server = HomeAssistantHTTP(hass, None, None, None, ["127.0.0.1"], 0, [], "modern")
    hass.http = server
    await server.async_initialize(
        cors_origins=[],
        use_x_forwarded_for=False,
        login_threshold=-1,
        is_ban_enabled=False,
        use_x_frame_options=True,
    )
    hass.config.components.add("http")
    hass.config_entries = ConfigEntries(hass, {})
    loader.async_setup(hass)
    assert await async_setup_component(hass, "belovodie_calendar_bridge", {})
    result = await hass.config_entries.flow.async_init(
        "belovodie_calendar_bridge", context={"source": "user"}
    )
    assert result["type"] == "form"
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {})
    assert result["type"] == "create_entry"
    await hass.async_block_till_done()
    return result["result"]


@native
async def test_native_flow_singleton_dynamic_inventory_and_unload(hass):
    from homeassistant.config_entries import ConfigEntryState

    entry = await setup_bridge(hass)
    assert entry.state == ConfigEntryState.LOADED
    repeat = await hass.config_entries.flow.async_init(
        "belovodie_calendar_bridge", context={"source": "user"}
    )
    assert repeat["type"] == "abort" and repeat["reason"] == "single_instance_allowed"
    await hass.services.async_call(
        "belovodie_calendar_bridge", "publish", {"snapshot": payload()}, blocking=True
    )
    await hass.async_block_till_done()
    states = hass.states.async_all("calendar")
    assert len(states) == 1
    assert states[0].attributes["friendly_name"] == "Owner · Personal"
    data = payload("2026-03-29T10:05:00.000Z")
    data["calendars"] = []
    data["removals"] = [{"id": A, "reason": "exportDisabled"}]
    await hass.services.async_call(
        "belovodie_calendar_bridge", "publish", {"snapshot": data}, blocking=True
    )
    await hass.async_block_till_done()
    assert hass.states.async_all("calendar") == []
    assert await hass.config_entries.async_unload(entry.entry_id)
    assert not hass.services.has_service("belovodie_calendar_bridge", "publish")


@native
async def test_authenticated_rest_publish_and_calendar_api(hass):
    from aiohttp.test_utils import TestClient, TestServer
    from homeassistant.auth.const import GROUP_ID_ADMIN, GROUP_ID_READ_ONLY
    from homeassistant.components import api
    from homeassistant.util import dt as dt_util

    entry = await setup_bridge(hass)
    server = hass.http
    assert await api.async_setup(hass, {})
    async with TestClient(TestServer(server.app)) as client:
        endpoint = "/api/services/belovodie_calendar_bridge/publish"
        assert (await client.post(endpoint, json={"snapshot": payload()})).status == 401
        admin = await hass.auth.async_create_user("Synthetic admin", group_ids=[GROUP_ID_ADMIN])
        viewer = await hass.auth.async_create_user(
            "Synthetic reader", group_ids=[GROUP_ID_READ_ONLY]
        )
        token = await hass.auth.async_create_refresh_token(
            viewer, client_id="http://synthetic.local"
        )
        viewer_headers = {"Authorization": "Bearer " + hass.auth.async_create_access_token(token)}
        assert (
            await client.post(endpoint, json={"snapshot": payload()}, headers=viewer_headers)
        ).status == 401
        assert entry.runtime_data.calendars == {}
        token = await hass.auth.async_create_refresh_token(
            admin, client_id="http://synthetic.local"
        )
        admin_headers = {"Authorization": "Bearer " + hass.auth.async_create_access_token(token)}
        response = await client.get("/api/services", headers=admin_headers)
        descriptions = await response.json()
        bridge_services = next(
            item for item in descriptions if item["domain"] == "belovodie_calendar_bridge"
        )
        field = bridge_services["services"]["publish"]["fields"]["snapshot"]
        assert field["required"] is True
        assert "object" in field["selector"]
        # Use current synthetic observation so timer expiry can be observed live.
        now = dt_util.utcnow()
        data = payload(now.isoformat(timespec="milliseconds"))
        data["window"] = {
            "start": (now - timedelta(days=1)).isoformat(timespec="milliseconds"),
            "end": (now + timedelta(days=1)).isoformat(timespec="milliseconds"),
        }
        data["calendars"][0]["events"][0].update(
            start=now.isoformat(timespec="milliseconds"),
            end=(now + timedelta(hours=1)).isoformat(timespec="milliseconds"),
        )
        from unittest.mock import patch

        scheduled = []
        call_at = hass.loop.call_at

        def record_timer(when, action, *args, **kwargs):
            handle = call_at(when, action, *args, **kwargs)
            if getattr(getattr(action, "__self__", None), "seconds", None) == 30:
                scheduled.append((handle, action, args))
            return handle

        with patch.object(hass.loop, "call_at", side_effect=record_timer):
            response = await client.post(endpoint, json={"snapshot": data}, headers=admin_headers)
            assert response.status == 200
            assert isinstance(await response.json(), list)
            await hass.async_block_till_done()
        entity_id = hass.states.async_all("calendar")[0].entity_id
        assert hass.states.get(entity_id).state == "on"
        assert hass.states.get(entity_id).attributes["stale"] is False
        response = await client.get(
            "/api/calendars/" + entity_id,
            params={"start": now.isoformat(), "end": (now + timedelta(hours=2)).isoformat()},
            headers=admin_headers,
        )
        assert response.status == 200
        assert (await response.json())[0]["summary"] == "Synthetic original"
        invalid = deepcopy(data)
        invalid["version"] = 2
        assert (
            await client.post(endpoint, json={"snapshot": invalid}, headers=admin_headers)
        ).status == 400
        assert len(entry.runtime_data.calendars[A].events) == 1
        response = await client.get(
            "/api/calendars/" + entity_id,
            params={"start": now.isoformat(), "end": (now + timedelta(days=2)).isoformat()},
            headers=admin_headers,
        )
        assert response.status == 500
        # Fire the real HA timer callback captured at its scheduling boundary.
        assert len(scheduled) == 1
        handle, action, args = scheduled[0]
        handle.cancel()
        future = now + timedelta(minutes=16)
        with patch("homeassistant.util.dt.utcnow", return_value=future):
            action(*args)
            await hass.async_block_till_done()
        assert hass.states.get(entity_id).attributes["stale"] is True


@native
async def test_concurrent_inventory_changes_cannot_remove_newer_entity(hass):
    from unittest.mock import patch

    from homeassistant.helpers import entity_registry as er

    await setup_bridge(hass)
    await hass.services.async_call(
        "belovodie_calendar_bridge", "publish", {"snapshot": payload()}, blocking=True
    )
    await hass.async_block_till_done()
    started, release = asyncio.Event(), asyncio.Event()
    remove = BridgeCalendar.async_remove

    async def delayed_remove(entity, **kwargs):
        started.set()
        await release.wait()
        await remove(entity, **kwargs)

    data = payload("2026-03-29T10:05:00.000Z")
    data["calendars"] = []
    data["removals"] = [{"id": A, "reason": "exportDisabled"}]
    with patch.object(BridgeCalendar, "async_remove", new=delayed_remove):
        await hass.services.async_call(
            "belovodie_calendar_bridge", "publish", {"snapshot": data}, blocking=True
        )
        await asyncio.wait_for(started.wait(), timeout=2)
        await hass.services.async_call(
            "belovodie_calendar_bridge",
            "publish",
            {"snapshot": payload("2026-03-29T10:06:00.000Z")},
            blocking=True,
        )
        await asyncio.sleep(0)
        release.set()
        await hass.async_block_till_done()
    entity_id = er.async_get(hass).async_get_entity_id("calendar", "belovodie_calendar_bridge", A)
    assert entity_id is not None
    assert hass.states.get(entity_id).state != "unavailable"
