# Home Assistant receiver

The HACS integration requires Home Assistant 2026.9.4 or newer and has no Python
package dependencies. Add **Belovodie Calendar Bridge** in Settings → Devices &
services after installation. One receiver config entry serves all exported
calendars; it asks for no credentials. Calendar names default to `owner · label`;
Home Assistant's entity registry can override their display names.

Publish the exact [Snapshot v1 contract](core-contract.md#filtered-snapshot-v1)
as the `snapshot` field of the authenticated administrator service
`belovodie_calendar_bridge.publish`. The native SSH helper posts
`{"snapshot": ...}` to `/api/services/belovodie_calendar_bridge/publish` and
expects Home Assistant's ordinary HTTP 200 state-list response. Invalid schemas
return HTTP 400. Publication/storage errors are errors, never empty replacements.
Older observations and identical retries leave the stored state unchanged;
different payloads with the same observation are rejected. Observation ordering
is global to this single snapshot stream and persists through restarts.

Each complete source replaces only its own originals, success time and exported
window. Failed/missing sources retain their previous successful copy and window.
Only explicit `exportDisabled` or `confirmedRemoved` removals delete cached
sources and their entities/registry rows. Omitted sources survive. Re-enabling
an explicitly removed source creates a new registry row, so custom entity names
for that removed row do not survive. Snapshots persist privately in HA's native
`.storage/belovodie_calendar_bridge` using atomic writes; HA owns this cache.

Calendar entities expose `owner`, `local_health`, `remote_health`, `observed_at`,
`last_successful_sync`, `stale`, `range_start`, `range_end` and
`in_exported_window`. Remote health remains `unknown`: successful local EventKit
reads do not establish cloud account health. A copy ages to stale at 15 minutes;
entity state refreshes every 30 seconds even when the Mac stops publishing.
Cached stale originals remain readable. Sources without any successful copy are
unavailable and event queries raise an error. Queries extending beyond the
exported window also raise an error (HA's calendar REST endpoint reports HTTP
500), so lack of coverage is distinguishable from a trustworthy empty result.
All-day API events use exclusive Gregorian end dates; timed events preserve
aware original boundaries. Overlap queries use half-open intervals.

This integration is read-only: it adds no event create/update/delete features,
public static snapshots or unauthenticated webhooks. Service publication requires
an administrator; calendar reads follow normal Home Assistant authentication.
Installation, actual account/provider checks and initial live publication are
separate controller gates. The source regression suite in `Tests/ha` runs against
native HA with synthetic events, temporary config entries/auth/storage and an
isolated local HTTP test server. It does not establish production installation
or real provider parity.
