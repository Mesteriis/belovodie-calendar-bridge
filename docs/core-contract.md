# BridgeCore boundary contract

`BridgeCore` requires macOS 14 or later and is a SwiftPM library using Apple's Foundation, CryptoKit and native Darwin file APIs for private storage. It neither reads calendars nor writes events. Run `swift test` to check its rules.

## Calendar identity and reads

Persist policies by both `sourceID` and `calendarID`; names, owners and labels are display data. `CalendarPolicy.identity` is the length-delimited per-calendar key accepted by `completeSources`. An account/source ID alone is not a complete-calendar key. New policies default all three flags to false. Export selection does not affect busy planning.

Only include a key in `completeSources` after a complete successful read of that calendar's originals **and managed blocks for the query window**. A missing calendar/account, permission error, failed query, or partial result is incomplete. Keep saved selected policies when their provider calendars disappear; do not silently convert absence to `busySource = false` or `busyTarget = false`.

An explicitly present disabled source policy permits cleanup of its owned contributions after a reviewed plan. An omitted former source policy is not evidence of a disable: opaque contributing-calendar hashes in existing markers preserve its blocks until a trustworthy read or explicit disable. A missing target policy is always untouched. An incomplete active source suppresses all updates/deletes; additive creates may still be proposed for targets with complete reads. An incomplete target suppresses all of its writes.

## Event instances and dates

Provide one consistent `SourceEvent` per instance. `eventID` and `occurrenceID` must be stable across moves. Recurring events require distinct original occurrence anchors, not their current/moved start dates. Identical duplicate rows are tolerated; inconsistent rows with the same instance identity cause `ambiguousEventIdentity`, so no partial plan is returned.

Dates are absolute, half-open boundaries (`start < end`). Resolve provider time zones and daylight saving changes before calling the planner, including all-day midnight boundaries; never manufacture a 24-hour duration for a calendar day. The core preserves 23/25-hour and multi-day spans. Unmodified all-day merged spans remain all-day; clipped or partially uncovered spans become timed spans. The EventKit adapter must translate absolute boundaries correctly into each target calendar's timezone and set Busy availability where supported.

Cancelled events, declined participation, Free availability and valid bridge ownership markers from any installation are excluded. Accepted, tentative, organizer, pending/unknown participation and other availability values contribute conservatively. An ordinary title `Занято` does not determine ownership. Foreign source busy spans merge, then real target busy coverage is subtracted without dropping uncovered remainders.

## Ownership and reconciliation

Persist a random installation UUID before any write and reuse it across runs. `Ownership.decode` accepts only an entire versioned marker, ignoring whitespace inserted or normalized by providers. Providers must preserve its non-whitespace ASCII characters. `encode` throws on malformed link digests or empty contributing-source sets. Notes contain the installation UUID and SHA-256 hashes; no provider/calendar/event identifier, label or original title is serialized into them.

Markers bind to the installation **and target calendar hash**; a marker copied to another calendar does not authorize mutation there. The source hashes let cleanup verify former dependencies without exposing their IDs. These markers are an ownership convention for provider events, not cryptographic authentication against an attacker who can edit the same calendar.

Desired link hashes use target identity, contributing stable event-instance identities and uncovered-fragment index; they exclude times and titles. Moves with unchanged contributors update a block in place. When overlap membership changes, reconciliation may create a new block and delete superseded owned blocks. Fully applied plans are idempotent; duplicate owned blocks are removed after complete reads. User originals and foreign-installation blocks never appear in mutations.

Reconciliation only mutates existing owned blocks entirely inside the query window. Blocks wholly outside or crossing its boundary remain untouched. Their same-link coverage is subtracted before reconciling the desired in-window interval, so preserved blocks cannot suppress uncovered moved-instance time or cause duplicate covered spans. The adapter must review the plan, revalidate current IDs/markers immediately before writes, and apply serially. Execute creates/updates before stale deletes so interrupted writes do not leave uncovered time. `BusyPlan.cleanupSuppressed` signals missing required read evidence; it does not indicate whether out-of-window blocks exist.

## Filtered snapshot v1

`SnapshotBuilder(installationID:)` builds `CalendarSnapshot` through
`build(events:policies:inventory:window:observedAt:)`. It is pure; it does not cache,
read a provider, infer cloud authentication, or write events. Use the UUID from
`SettingsStore.load()` before constructing the builder or ownership codec.
`SourceEvent.timeZoneID` is optional for compatibility with busy planning; export
uses its timezone when present, otherwise the descriptor's calendar timezone.

`CalendarDescriptor.localRead` records **local** evidence: `.complete(window:)`,
`.failed`, `.missing`, or `.confirmedRemoved`. Only an exact complete read for the
requested query window can replace events. The adapter must report failed/partial
queries, unavailable permissions, missing accounts/calendars, and uncertain
inventory disappearance as incomplete. `confirmedRemoved` requires separate
trustworthy confirmation of removal; a missing inventory entry never provides it.
EventKit local query success does not establish remote account health.

JSON uses the following camelCase fields (the ordinary `JSONEncoder` suffices):

```json
{
  "version": 1,
  "observedAt": "2026-03-29T10:00:00.000Z",
  "window": {"start": "2026-03-22T00:00:00.000Z", "end": "2026-06-27T00:00:00.000Z"},
  "calendars": [{
    "id": "<64 lowercase hex characters>",
    "owner": "Owner label",
    "label": "Display label",
    "localHealth": "complete",
    "remoteHealth": "unknown",
    "observedAt": "2026-03-29T10:00:00.000Z",
    "lastSuccessfulObservedAt": "2026-03-29T10:00:00.000Z",
    "events": [{
      "id": "<64 lowercase hex characters>",
      "title": "Original event",
      "start": "2026-03-29T00:00:00.000+01:00",
      "end": "2026-03-30T00:00:00.000+02:00",
      "isAllDay": true,
      "timeZoneID": "Europe/Madrid",
      "startDate": "2026-03-29",
      "endDate": "2026-03-30"
    }]
  }],
  "removals": []
}
```

Calendar and instance IDs are SHA-256 hashes of length-delimited fields salted by
the installation UUID with separate `calendar` and `instance` domains. They remain
stable across rename, title edits and instance moves. Recurrence anchors remain
the stable instance discriminator. Raw source/calendar/event/occurrence IDs and
ownership markers are private local data, never wire fields. Original titles and
chosen owner/display labels are exported only for enabled calendars. Cancelled
originals are omitted; Free originals are exported, because busy selection is an
independent flag. Valid ownership markers from **any** installation are filtered
before export and encoding; the ordinary title `Занято` remains an original.

Instants are RFC3339 strings with explicit UTC/offset and fractional seconds.
All-day events additionally carry Gregorian `YYYY-MM-DD` dates with an exclusive
end and `timeZoneID`; boundaries must be actual midnight boundaries in that zone.
Timed events omit `startDate` and `endDate`. DST intervals preserve their absolute
23/25-hour durations. Events intersecting the half-open query window retain their
full original boundaries; out-of-window events are omitted. Invalid intervals,
invalid zones, duplicate policies/descriptors and inconsistent duplicate instance
rows fail the entire build instead of emitting a partial replacement.

A complete calendar carries `events` (including an authoritative empty `[]`) and
`lastSuccessfulObservedAt`. A failed or missing calendar carries health and
observation only: **both fields are omitted, never replaced by an empty array**.
`localHealth` is `complete`, `failed` or `missing`; `remoteHealth` is always
`unknown`. The HA receiver must merge each calendar independently:

- For `complete`, replace that calendar's events, successful timestamp and query
  window using the root `window`.
- For health-only updates, retain its prior successful events, prior successful
  timestamp **and prior query window**; update health-observation time only.
- Apply only explicit `removals` entries (`id` plus `reason` of `exportDisabled` or
  `confirmedRemoved`). Disabled calendars emit no events, owner or label.
- Omission of a former policy/calendar from either array is not a removal signal.

The receiver owns the last-successful event cache and stale-data presentation.
A failed snapshot build does not authorize replacing any cached data. The
transport/receiver must validate version and payload before applying any changes;
provider reads, authentication, sending and HA integration are separate tasks.

## Private settings and atomic files

`SettingsStore(directoryURL:)` exposes `load()` and `save(_:)` for versioned
`BridgeSettings` (`version`, `installationID`, `policies`). First load persists a
random UUID before returning. Subsequent loads reuse it. Corrupt/unsupported data
throws visibly without creating a new UUID or overwriting the file. Duplicate
policy identities are invalid. Mutate loaded settings rather than constructing a
fresh installation on each run.

`BridgeSettings.discover(_:)` adds newly observed calendars with all flags off and
initial owner/name labels. Existing choices and customized labels survive provider
renames; missing entries and confirmed-removal observations do not silently erase
persisted policies. Initial three-calendar enablement remains an explicit adapter
or UI decision after access verification.

`AtomicStore(fileURL:)` provides `load() throws -> Data?` and `save(_:) throws` for
future settings/journal use. It creates private 0700 directories and writes 0600
files with native Darwin file operations, using an exclusive same-directory temp
file, file fsync, atomic rename and directory fsync. A leftover interrupted temp
file is ignored; the previous complete destination stays readable before rename.
Symlinks, special files and hard-linked destination files are rejected. Existing
directory/file modes are tightened when accessed. Callers serialize store access;
this is not a multi-process lock or provider transaction journal. No file values
are logged. Actual EventKit/HA credentials and host bindings stay outside Git.

## Native foreground boundary

The macOS adapter and settings utility are documented in `docs/native-app.md`.
`BridgeSettings` v1 additionally persists `lookbackDays` and `lookaheadDays`; older
files default to 7/90. Bounds are 0–365 back and 1–365 ahead. Invalid values are
rejected without replacing existing settings. `BridgeModel.settings` is a UI draft;
`activeSettings` changes only after a matching count-only preview and successful
atomic save. Native event writes remain inaccessible from the foreground UI.

Managed blocks carry observed `availability`; missing legacy values decode as unknown.
Only Busy availability satisfies the desired block or protected boundary coverage;
other values require a Busy update after complete reads, or remain untouched outside
the window while an uncovered in-window Busy block is proposed. Adapters must pass
observed availability and require Busy when accepting a repeated create.
