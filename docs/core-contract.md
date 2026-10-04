# BridgeCore boundary contract

`BridgeCore` is a pure SwiftPM library using only Apple's Foundation and CryptoKit. It neither reads calendars nor writes events. Run `swift test` to check its rules.

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

Reconciliation only mutates existing owned blocks entirely inside the query window. Blocks wholly outside or crossing its boundary remain untouched. The adapter must review the plan, revalidate current IDs/markers immediately before writes, and apply serially. Execute creates/updates before stale deletes so interrupted writes do not leave uncovered time. `BusyPlan.cleanupSuppressed` signals missing required read evidence; it does not indicate whether out-of-window blocks exist.
