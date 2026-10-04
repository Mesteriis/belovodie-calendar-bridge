"""Authenticated, read-only calendar snapshot receiver."""

import voluptuous as vol
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant, ServiceCall
from homeassistant.exceptions import ConfigEntryNotReady, ServiceValidationError
from homeassistant.helpers.service import async_register_admin_service

from .models import validate_snapshot
from .store import DOMAIN, SnapshotStore

PLATFORMS = [Platform.CALENDAR]


def _snapshot_schema(data):
    try:
        validate_snapshot(data)
    except (ValueError, TypeError) as err:
        raise vol.Invalid("Invalid calendar snapshot") from err
    return data


async def async_setup(hass: HomeAssistant, config: dict) -> bool:
    return True


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    store = SnapshotStore(hass)
    try:
        await store.async_load()
    except (ValueError, KeyError, TypeError, OSError) as err:
        raise ConfigEntryNotReady("Stored calendar snapshots could not be loaded") from err
    entry.runtime_data = store
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)

    async def publish(call: ServiceCall):
        try:
            await store.async_publish(call.data["snapshot"])
        except (ValueError, TypeError, OSError) as err:
            raise ServiceValidationError(
                "Calendar snapshot rejected or could not be saved"
            ) from err

    async_register_admin_service(
        hass,
        DOMAIN,
        "publish",
        publish,
        schema=vol.Schema({vol.Required("snapshot"): _snapshot_schema}),
    )
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    if await hass.config_entries.async_unload_platforms(entry, PLATFORMS):
        hass.services.async_remove(DOMAIN, "publish")
        return True
    return False
