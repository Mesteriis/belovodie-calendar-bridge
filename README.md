# Belovodie Calendar Bridge

A macOS 14+ utility and Home Assistant integration for local Calendar originals
and independent busy-time mirroring. It uses EventKit accounts already configured
in macOS Calendar; no new Google project or cloud credentials are required on the Mac.

Each calendar has three independent choices, all **off for newly discovered calendars**:

| Choice | Result |
| --- | --- |
| Export to HA | Exports that calendar's originals to a native read-only `calendar.*` entity. |
| Busy source | Contributes busy intervals to other selected targets. |
| Busy target | Receives managed blocks for foreign busy intervals not covered by its own originals. |

Blocks have only the title `Занято`, Busy availability, boundaries and an opaque
ownership marker. Original titles, locations and attendees are never copied into
blocks. Managed blocks from every installation are excluded from HA export and
from busy inputs. The app clears EventKit alarms, but providers can apply their
own default reminders or calendar-level email notifications. Suppression is **not
guaranteed**; verify the actual target provider before enabling automatic writes.

The default export window is 7 days back and 90 days ahead. Event changes debounce
for 5 seconds; launch, wake and the 5-minute repair scan trigger synchronization.
Local EventKit success does not prove cloud freshness. HA retains each source's
last successful originals on incomplete reads and exposes stale, health and
coverage attributes. Queries outside that source's exported window raise an error.

Install the receiver through [HACS](https://hacs.xyz/), then configure the private
Mac-to-HA SSH transport and review the native settings. See [installation and
migration](docs/install.md), [native app](docs/native-app.md), [HA receiver](docs/home-assistant.md)
and [boundary contract](docs/core-contract.md). The optional
[Belovodie Calendar Card](https://github.com/Mesteriis/belovodie-calendar-card)
is a separate package supporting day/week/month views and bounded snapshot status.

## Version 0.1.2 (native build 3)

This source prepares the next immutable release; publication is a separate step.
It scopes write evidence to each fresh read/plan transaction and fixes native
all-day create/update configuration. Durable pending receipts and exact ownership
checks remain required. Unsaved EventKit regressions verify local classification
and bounds; actual Google/iCloud all-day persistence still needs live acceptance.

## Source checks

```sh
swift test
python3 -m unittest discover -s Tests -p 'test_*.py'
./scripts/build-app.sh
python3 scripts/package-integration.py
```

Native HA tests require a separate Python 3.14 environment with
`homeassistant==2026.9.4` and `pytest==8.4.2`:

```sh
PYTHONPATH=. python -m pytest -q Tests/ha
```

CI runs native Swift tests, Python tools/packaging tests, the ad-hoc signed app
build and isolated native HA tests with synthetic events. A version tag matching
the integration manifest produces a manual-install ZIP with
`custom_components/belovodie_calendar_bridge/` and a SHA-256 sidecar after checks.
HACS uses the conventional source tree. Release assets do not contain a signed
Mac distribution, account settings, host bindings, private keys or calendar data.
Stable local Calendar permission requires a consistent private signing identity
and an explicit macOS access grant. Developer ID distribution and notarization
are not provided.
