# Install and migrate

The bridge requires macOS 14+, Swift 6 to build the utility, and Home Assistant
2026.9.4+ (Python 3.14). Keep account, calendar, SSH and signing bindings private.
Installation does not enable event writes. Each new calendar starts with export,
busy-source and busy-target flags off; automatic writes require a separate review.

## Receiver

1. In HACS, add `https://github.com/Mesteriis/belovodie-calendar-bridge` as a custom
   **Integration** repository. Download the reviewed release and follow HACS's
   restart instruction. Run `ha core check` first where the HA CLI is available.
2. Add **Belovodie Calendar Bridge** in Settings → Devices & services. One entry
   receives the snapshot stream; it asks for no credentials. Entities appear after
   a valid authenticated snapshot publishes an enabled source.
3. For a manual install, download the release ZIP and its `.zip.sha256` sidecar,
   verify with `shasum -a 256 -c belovodie-calendar-bridge-VERSION.zip.sha256`, and
   extract the `custom_components/belovodie_calendar_bridge` directory into the
   HA configuration directory. Back up an existing integration before replacement.
   Verify the exact tag/commit, CI result and downloaded contents before restarting.

The service `belovodie_calendar_bridge.publish` accepts a `snapshot` field and
requires an authenticated administrator. HA owns the last-successful event cache
in `.storage`; it does not publish a public snapshot, ICS feed or webhook.

## Stable native app and Calendar access

1. Review source and run the checks in the README. Build with
   `./scripts/build-app.sh`; the default ad-hoc signature is for source/CI checks.
   For repeated local use, supply your own consistent private Apple Development
   identity through `CODE_SIGN_IDENTITY` and use the same app installation path.
   Keep signing identity details outside Git. This is not a Developer ID or
   notarized distribution.
2. Place the reviewed signed `BelovodieCalendarBridge.app` at a stable local path.
   Open it and grant full Calendar access through its settings. The verified
   signed Calendar entitlement declares the requested scope; it does not grant
   macOS privacy permission. Add/check your accounts in Apple's Calendar app.
3. Refresh the list and inspect each actual source/calendar pair. Saved rows are
   unverified before inventory is read; disappearance never erases saved choices.
   Owner and display label are editable presentation data, never identity.
4. Select only the intended flags and window (defaults 7/90 days). Calculate the
   count-only plan, then apply that exact reviewed draft. The running coordinator
   consumes saved active settings, not unapplied draft changes. Applying a changed
   draft or editing it revokes automatic write intent.

Blocks use `Занято`, absolute bounds, all-day state where appropriate, Busy
availability and opaque hashed notes. Calendar/event identifiers and original
text are not embedded in notes. Markers and durable receipts must agree before
mutation; uncertain reads suppress destructive cleanup. The app clears alarms,
location, URL and recurrence data when writing eligible blocks. Attendees are
never copied; existing attendee-bearing or recurring rows are not mutated.
Providers may subsequently add default reminders, including a default 10-minute
reminder, and calendar-level email notifications may still apply. Clearing EventKit
alarms does not disable those provider settings. Decide and verify reminder/email
behavior on the actual target calendars before enabling automatic writes.

## Private SSH transport

The Mac sends one filtered JSON snapshot on SSH stdin to a constant HA-side helper.
The helper authenticates to HA using the existing HA-local credential resolver;
no HA token moves to the Mac. This adapter currently requires a Docker container
named `homeassistant` and an HA-local
`/config/_tools/ai_ollama/common.py:_get_ha_config` resolver returning `(url, token)`.
That resolver is an operator-provided dependency, not bundled with this package.
Deploy the reviewed `adapters/ha_ssh_receiver.py` at
`/config/_tools/belovodie_calendar_bridge/ha_ssh_receiver.py` inside that container.
Review remote account/container access and the existing resolver separately.
Do not substitute a public or unauthenticated receiver.

Private `ssh.json` belongs under the app's Application Support directory. Replace
all placeholders with reviewed local paths and bindings; these examples are not
usable credentials or machine settings:

```json
{
  "hostAlias": "HA_BRIDGE_HOST",
  "identityFile": "/PRIVATE/PATH/bridge-key",
  "knownHostsFile": "/PRIVATE/PATH/known-hosts",
  "configFile": "/PRIVATE/PATH/ssh-config",
  "port": 22
}
```

Example private SSH config:

```sshconfig
Host HA_BRIDGE_HOST
    HostName HA_HOST_PLACEHOLDER
    User HA_USER_PLACEHOLDER
```

Review the remote host key through a trusted channel and populate the dedicated
known-hosts file before use. Protect the config, key and application data with
private permissions. Transport uses strict host verification, batch mode and a
30-second deadline. Neither process stream is logged. The constant command is:

```sh
docker exec -i homeassistant python /config/_tools/belovodie_calendar_bridge/ha_ssh_receiver.py
```

A successful transfer is distinct from Calendar/cloud health. The repair scan is
every 5 minutes and EventKit change debounce is 5 seconds. Failed/missing source
reads send health only, preserving HA's prior successful events and window. HA
marks copies stale after 15 minutes and refreshes that state every 30 seconds.

## User LaunchAgent

Generate and review before installing, using the same stable signed app:

```sh
python3 scripts/install-agent.py generate --app /ABSOLUTE/PATH/BelovodieCalendarBridge.app --output /PRIVATE/PATH/agent.plist
python3 scripts/install-agent.py install --app /ABSOLUTE/PATH/BelovodieCalendarBridge.app
```

The agent runs as the current logged-in user, uses the bundle executable and
never prompts for Calendar permission. Use `stop`, `start`, `restart`, or
`uninstall` with the same script to manage that agent. KeepAlive restarts a quit
app while the agent is loaded; use `stop` for persistent shutdown and quit any
separately launched owner. Installation never changes calendar selections or
enables writes. Only one process can own EventKit operations for this installation.

## Consumer migration and live acceptance

Audit actual entity-registry IDs, provider inventory and every affected dashboard
before changing consumers. Back up the targeted configuration and retain rollback
bindings. Source hashes become native HA entities; do not guess their entity IDs
from names. HA names default to `owner · label`; use registry names or card `name`
overrides for the intended display label. No personal names are built into the
package.

First run with automatic writes off. Compare each original source against its
new entity over the same aware start/end range, including titles, boundaries,
all-day events and recurrence instances. Confirm managed blocks from any
installation are absent. Verify day/week/month views and filters in each affected
dashboard. Bounded sources must show partial/no coverage beyond their exported
window and retain stale/failed originals with their last-successful timestamp;
an uncovered date must not be accepted as an empty calendar.

Only after equivalence is proven, migrate selected consumers to the observed new
IDs. Disable duplicate direct entities after confirming no remaining references.
Keep unrelated/provider/academic calendars intact. Run `ha core check` before a
required restart, then repeat the affected UI and source checks.

Before automatic busy writes, use a dedicated test original in the selected
provider calendars to verify create → move → delete. Check exact Busy-only
content, marker preservation, reminder/email behavior, repeat-scan idempotency,
no managed blocks in HA, and source/transport failure behavior. A transport
failure alone does not disable separately reviewed local writes; incomplete
source evidence prevents destructive cleanup. Delete only verification objects
created by this check using the ordinary recoverable calendar UI. Use the native
active-plan review and explicit enable control only after these checks and
provider notification choices are complete. Source tests and CI do not prove
these live gates.
