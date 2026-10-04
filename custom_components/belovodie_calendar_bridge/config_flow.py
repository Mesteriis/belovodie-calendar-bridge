"""One credential-free receiver per Home Assistant instance."""

import voluptuous as vol
from homeassistant import config_entries

from .store import DOMAIN


class ConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    VERSION = 1

    async def async_step_user(self, user_input=None):
        if self._async_current_entries():
            return self.async_abort(reason="single_instance_allowed")
        await self.async_set_unique_id(DOMAIN)
        self._abort_if_unique_id_configured()
        if user_input is not None:
            return self.async_create_entry(title="Belovodie Calendar Bridge", data={})
        return self.async_show_form(step_id="user", data_schema=vol.Schema({}))
