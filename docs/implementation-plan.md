# Belovodie Calendar Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Выбранные календари Mac автоматически обмениваются анонимной занятостью, а HA получает только оригинальные события с подписями владельцев.

**Architecture:** Native macOS agent owns EventKit access, settings and sequential reconciliation. A pure Swift core plans busy intervals and filtered snapshots; a separate HA integration accepts authenticated snapshots and exposes calendar entities. The current host adapter uses the existing SSH channel, keeping the HA credential on the HA host.

**Tech Stack:** SwiftPM, SwiftUI, EventKit, CryptoKit, launchd; Python, Home Assistant native calendar/config-flow APIs; no external calendar-provider APIs.

**Spec:** [design.md](design.md), approved by the owner in this chat.

## Global Constraints

- Sources live in `distrib/belovodie-calendar-bridge`; calendar card remains in its existing separate repository.
- macOS 14 or later; no Terminal/Python-wide calendar permission and no root LaunchDaemon.
- Initial set: ITQuick, Personal, «Семья»; other calendars default to three disabled flags.
- Independent flags: export to HA, source of busy intervals, receiver of busy blocks.
- Block title exactly «Занято»; markers disclose no titles, account names, calendar names, URLs or attendee data.
- Debounce 5 seconds; repair scan every 5 minutes and after wake/start; lookback 7 days and lookahead 90 days.
- Provider originals are never modified or deleted. Source failure never permits destructive reconciliation.
- No new Google account/project, public ICS, public `/local` snapshot, credentials or personal bindings in Git.

## Review Focus

- macOS may provide cached events while an account has a sync warning: expose source health, suppress destructive reconciliation when freshness cannot be established.
- A busy marker must survive provider round trips: ownership checks fail closed if markers are stripped; do not identify blocks by their title.
- EventKit identifiers may change and recurring instances may move: rebuild desired intervals without creating loops or removing original events.
- Configuration changes and process crashes can interrupt writes: durable ownership metadata and an idempotent fresh scan recover safely.
- CalDAV can still import busy blocks outside the new transport: verify and migrate every selected HA consumer before disabling duplicate raw entities.

---

### Task 1: Rules, identifiers and busy reconciliation

**Files:** `Package.swift`, `Sources/BridgeCore/Models.swift`, `Sources/BridgeCore/BusyPlanner.swift`, `Sources/BridgeCore/Ownership.swift`, `Tests/BridgeCoreTests/BusyPlannerTests.swift`.

**Interfaces:** `CalendarPolicy(sourceID: String, calendarID: String, owner: String, label: String, exportToHA: Bool, busySource: Bool, busyTarget: Bool)`; `BusyPlanner.plan(events: [SourceEvent], policies: [CalendarPolicy], existing: [ManagedBlock], window: QueryWindow, completeSources: Set<String>) throws -> BusyPlan`.

- [ ] Write tests asserting independent flags; new policies disabled; no self-mirroring; no busy-to-busy propagation; accepted/tentative included and cancelled/declined/Free excluded; ordinary «Занято» retained. Assert merged overlaps leave no uncovered remainder and duplicate intervals produce one block.
- [ ] Run `swift test --filter BusyPlannerTests`, record the initial failure, implement the pure planner and ownership marker codec, then rerun to PASS.
- [ ] Add tests for recurring instances, moved intervals, DST, all-day spans, provider-normalised markers and source failure: no original deletion and no stale-block deletion for incomplete sources. Verify opaque markers contain none of the source's identifying text.
- [ ] Commit the independently tested core.

### Task 2: Filtered export and private storage

**Files:** `Sources/BridgeCore/Snapshot.swift`, `Sources/BridgeCore/SettingsStore.swift`, `Sources/BridgeCore/AtomicStore.swift`, `Tests/BridgeCoreTests/SnapshotTests.swift`, `Tests/BridgeCoreTests/SettingsStoreTests.swift`.

**Interfaces:** `SnapshotBuilder.build(events: [SourceEvent], policies: [CalendarPolicy], inventory: [CalendarDescriptor], window: QueryWindow, observedAt: Date) throws -> CalendarSnapshot`; `SettingsStore.load() throws -> BridgeSettings`, `save(_ settings: BridgeSettings) throws`.

- [ ] Write tests asserting export-disabled sources absent, busy-marked events absent before encoding, original «Занято» retained and owner labels preserved; failed reads cannot become empty authoritative snapshots.
- [ ] Run the two test filters to record failure; implement versioned JSON with explicit window, source health and observation time, opaque IDs and timezone-aware times. Atomic private files use mode 0600 inside a 0700 directory.
- [ ] Test policy persistence on calendar rename, new source defaults, corrupt files failing visibly and crash recovery preserving the previous complete state. Run tests to PASS and commit.

### Task 3: Native EventKit adapter and foreground settings

**Files:** `Sources/BridgeMac/EventKitAdapter.swift`, `Sources/BridgeMac/BridgeModel.swift`, `Sources/BridgeMac/CalendarSettingsView.swift`, `Sources/BridgeMac/App.swift`, `packaging/Info.plist`, `scripts/build-app.sh`, `Tests/BridgeCoreTests/EventKitContractTests.swift`.

**Interfaces:** `EventKitAdapter.inventory() throws -> [CalendarDescriptor]`, `read(policy: CalendarPolicy, window: QueryWindow) throws -> SourceReadResult`, `apply(_ plan: BusyPlan) throws`; settings bind the policies from Tasks 1–2.

- [ ] Write adapter-contract tests for unavailable/duplicate calendars, non-writable targets, stripped markers, incomplete source reads, unsupported Busy availability and repeated writes. Run to FAIL before implementation.
- [ ] Implement EventKit permission handling inside a stable app bundle with `NSCalendarsFullAccessUsageDescription`; cancellation/denial stays visible and never produces an empty successful read. Use supported availability masks, no attendees/locations/alerts on blocks and opaque provenance.
- [ ] Implement the settings table with owner/label and the three independent switches, scope/window controls, access/last-update status and count-only dry-run plan. No source is selected merely because it appears in discovery.
- [ ] Run `swift build`, `swift test` and bundle/signature verification. On real Mac request OS access, verify the selected inventory and dry-run counts; no automatic writes yet. Commit.

### Task 4: Background lifecycle and closed transport

**Files:** `Sources/BridgeMac/SyncCoordinator.swift`, `Sources/BridgeMac/SSHTransport.swift`, `packaging/LaunchAgent.plist`, `scripts/install-agent.py`, `adapters/ha_ssh_receiver.py`, `Tests/BridgeCoreTests/CoordinatorTests.swift`.

**Interfaces:** `SyncCoordinator.requestSync(reason: SyncReason)`, `SSHTransport.send(snapshot: CalendarSnapshot) async throws`; `ha_ssh_receiver.py` reads one JSON snapshot from stdin and invokes the authenticated native HA service from Task 5.

- [ ] Write fake-store/transport tests for 5-second debounce, no concurrent runs, self-write notifications converging, retry after partial apply, restart/wake repair and failed transport retaining the last successful status. Run to FAIL.
- [ ] Implement a user LaunchAgent and menu-bar settings access; regular 5-minute repair and event/wake observation. Dry-run mode never calls store writes; writes become enabled only after the initial verified plan.
- [ ] Implement constant-command SSH transport with a stdin JSON payload, timeout and exit-code validation; no shell interpolation of event text or local copies of HA credentials. Runtime host/identity configuration remains private and untracked.
- [ ] Run coordinator tests to PASS and check generated plist with `plutil -lint`. Verify agent start/stop/restart does not duplicate work or prevent editing settings; commit.

### Task 5: HA calendar receiver

**Files:** `custom_components/belovodie_calendar_bridge/{manifest.json,__init__.py,config_flow.py,calendar.py,models.py,store.py,strings.json}`, `hacs.json`, `tests/ha/test_snapshot.py`, `tests/ha/test_calendar.py`.

**Interfaces:** authenticated service `belovodie_calendar_bridge.publish` accepts `snapshot`; `validate_snapshot(data: dict) -> Snapshot`; `BridgeCalendar.async_get_events(hass, start_date, end_date)` exposes the stored original events and attributes `last_successful_sync`, `stale`, `range_start`, `range_end`.

- [ ] Write tests for invalid schema/naive times/duplicates, marker rejection, partial source failures preserving their old snapshot, confirmed inventory changes, owner names and overlap queries. Run to FAIL.
- [ ] Implement native config flow and calendar platform; serialize updates and persist validated snapshots atomically. Service errors never replace data with an empty snapshot; future dates outside the exported window are distinguishable from no events. A 15-minute age marks a source stale while preserving its last successful copy.
- [ ] Run HA tests against the verified installed HA version, validate HACS packaging and authenticated actual service/API behaviour in a separate test entry; commit. Do not expose the receiver through public static files or unauthenticated webhooks.

### Task 6: Install, migrate and verify

**Files:** `README.md`, `docs/install.md`, private ignored deployment bindings; the existing calendar-card repository only if its status rendering needs the receiver attributes.

**Interfaces:** exported source IDs map to real newly registered HA entity IDs; migration consumes current registry, provider inventory and dashboard bindings, never guessed IDs.

- [ ] Audit current references to selected direct CalDAV calendars; back up affected configuration. Prove the new receiver serves each original source without busy blocks before migrating consumers.
- [ ] Publish generic package source/release in its own repository; validate CI and exact downloaded artifact. Install HA integration through HACS and stable app/LaunchAgent on Mac; local account/host bindings stay private.
- [ ] Migrate selected calendar consumers and disable duplicate direct entities only after verified equivalence; retain Vika/academic sources. Run `ha core check` before any required HA restart.
- [ ] Add meaningful calendar-card status coverage if needed: stale snapshots and dates outside the export window must show their real state. Verify real day/week/month view and owner labels in main and preview dashboards.
- [ ] With a dedicated test original, verify create → move → delete in the chosen calendars, no event details leak, no reminder flood, repeated scan creates no duplicates, HA receives no managed blocks and source/transport failure causes no destructive cleanup.
- [ ] Review diff, results, source scope and documentation; report actual checks and remaining limitations. Remove only test objects created by this verification using the normal recoverable calendar UI.
