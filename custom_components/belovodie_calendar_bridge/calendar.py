"""Read-only original calendars with explicit cache coverage."""

import asyncio
from datetime import datetime, timedelta

from homeassistant.components.calendar import CalendarEntity, CalendarEvent
from homeassistant.core import callback
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers import entity_registry as er
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.helpers.event import async_track_time_interval
from homeassistant.util import dt as dt_util

from .store import SIGNAL_UPDATED, SnapshotStore


async def async_setup_entry(hass, entry, async_add_entities):
    store = entry.runtime_data
    entities = {}
    inventory_lock = asyncio.Lock()
    registry = er.async_get(hass)
    for registered in er.async_entries_for_config_entry(registry, entry.entry_id):
        if (
            registered.platform == "belovodie_calendar_bridge"
            and registered.unique_id not in store.calendars
        ):
            registry.async_remove(registered.entity_id)

    async def sync_inventory():
        async with inventory_lock:
            for cid in set(entities) - store.calendars.keys():
                entity = entities.pop(cid)
                await entity.async_remove(force_remove=True)
                registry.async_remove(entity.entity_id)
            new = []
            for cid in store.calendars:
                if cid not in entities:
                    entities[cid] = BridgeCalendar(store, cid)
                    new.append(entities[cid])
            if new:
                async_add_entities(new)

    entry.async_on_unload(async_dispatcher_connect(hass, SIGNAL_UPDATED, sync_inventory))
    await sync_inventory()


class BridgeCalendar(CalendarEntity):
    _attr_should_poll = False
    _attr_supported_features = 0
    _attr_has_entity_name = False

    def __init__(self, store: SnapshotStore, calendar_id: str):
        self._store = store
        self._calendar_id = calendar_id
        self._attr_unique_id = calendar_id

    @property
    def name(self):
        row = self._store.calendars.get(self._calendar_id)
        if row is None:
            return None
        return " · ".join(part for part in (row.calendar.owner, row.calendar.label) if part)

    @property
    def available(self):
        row = self._store.calendars.get(self._calendar_id)
        return row is not None and row.events is not None

    @property
    def event(self):
        row = self._store.calendars.get(self._calendar_id)
        now = dt_util.utcnow()
        if row is None or row.events is None or not row.range_start <= now < row.range_end:
            return None
        upcoming = sorted(
            (event for event in row.events if event.end > now),
            key=lambda event: (event.start, event.end, event.id),
        )
        return self._ha_event(upcoming[0]) if upcoming else None

    @property
    def extra_state_attributes(self):
        row = self._store.calendars.get(self._calendar_id)
        if row is None:
            return {}
        now = dt_util.utcnow()
        return {
            "owner": row.calendar.owner,
            "local_health": row.calendar.local_health,
            "remote_health": "unknown",
            "observed_at": row.calendar.observed_at.isoformat(),
            "last_successful_sync": row.last_successful_observed_at.isoformat()
            if row.last_successful_observed_at
            else None,
            "stale": row.stale_at(now),
            "range_start": row.range_start.isoformat() if row.range_start else None,
            "range_end": row.range_end.isoformat() if row.range_end else None,
            "in_exported_window": row.range_start is not None
            and row.range_start <= now < row.range_end,
        }

    async def async_added_to_hass(self):
        await super().async_added_to_hass()
        self.async_on_remove(async_dispatcher_connect(self.hass, SIGNAL_UPDATED, self._refresh))
        self.async_on_remove(
            async_track_time_interval(self.hass, self._refresh, timedelta(seconds=30))
        )

    @callback
    def _refresh(self, *_):
        self.async_write_ha_state()

    @staticmethod
    def _ha_event(event):
        return CalendarEvent(
            start=event.start_date if event.is_all_day else event.start,
            end=event.end_date if event.is_all_day else event.end,
            summary=event.title,
            uid=event.id,
        )

    async def async_get_events(self, hass, start_date: datetime, end_date: datetime):
        row = self._store.calendars.get(self._calendar_id)
        if start_date.tzinfo is None or end_date.tzinfo is None or start_date >= end_date:
            raise HomeAssistantError("Calendar query requires aware, increasing dates")
        if row is None or row.events is None:
            raise HomeAssistantError("No successful calendar snapshot is cached")
        if start_date < row.range_start or end_date > row.range_end:
            raise HomeAssistantError("Calendar query is outside the exported window")
        return [
            self._ha_event(event)
            for event in sorted(row.events, key=lambda event: (event.start, event.end, event.id))
            if event.start < end_date and event.end > start_date
        ]
