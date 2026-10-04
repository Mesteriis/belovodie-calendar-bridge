# Native foreground utility

Build the macOS 14+ Swift 6 app with `./scripts/build-app.sh`. It invokes SwiftPM,
stages `build/BelovodieCalendarBridge.app`, includes the full Calendar access usage
string, signs with hardened runtime and the Calendar entitlement, lints the plist,
verifies the signature, and reads the actual signed Calendar entitlement. Both ad-hoc
and private development signing use `packaging/Entitlements.plist`, which requests only
`com.apple.security.personal-information.calendars=true`. [Apple documents this entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.calendars)
for Calendar access under hardened runtime. It declares the app's requested scope;
the user must still approve macOS Calendar access. Manual re-signing must preserve
`--options runtime --entitlements packaging/Entitlements.plist`. The default signature
is ad-hoc for build/CI checks. For stable local privacy approval, supply the same
private Apple Development identity in `CODE_SIGN_IDENTITY`; never commit identity
or account details. Developer ID distribution/notarization is outside this stage.

`./script/build_and_run.sh` is the Codex Run entrypoint. It delegates bundling and
supports `--debug`, `--logs`, `--telemetry`, and `--verify`. Ordinary Run opens the
app bundle. None of these modes grants Calendar access. The foreground UI explicitly
requests full access for this bundle; denial/cancellation remains visible.

The settings utility launches with every new calendar's three flags disabled.
Inventory discovery reads metadata only. Draft owner/label/flag/window edits remain
separate from `BridgeModel.activeSettings`. Calculate the count-only plan before
applying the exact reviewed draft. Discovery never persists partially edited flags.
Only selected calendars or calendars with private ownership provenance have their
events read. Missing saved choices remain present. Initial calendar selection is
manual after checking the actual source/calendar pair; names never define identity.

The foreground draft preview remains count-only. The separate background mode below
adds explicit reviewed write controls and HA transmission; no automatic permission
prompt is installed. Event write APIs require explicit one-shot review of the exact `BusyPlan`, complete local
read evidence, unchanged originals, and current target/ownership validation. A native
provider additionally requires durable receipts. Creates/updates precede deletes;
each provider operation commits separately and retries are idempotent. Blocks use
only `Занято`, absolute bounds, all-day state, Busy availability and opaque notes;
location, URL, alarms and recurrence rules are cleared, and attendee-bearing or
recurring existing rows are never mutated.

EventKit reports local calendar data, not remote authentication/synchronization
health. The app always labels Google/iCloud health unknown. A successful synchronous
query with full access and an unchanged calendar identity provides local complete
read evidence; missing inventory, denied access, malformed/ambiguous rows and failed
queries do not provide an authoritative empty snapshot. Busy availability/read-only
limitations are shown separately. EKCalendar exposes no calendar timezone; floating
and all-day events use the system zone. Timed events preserve the provider timezone
where present. Original recurrence identity uses the external series identifier
(local item identifier fallback) and original `occurrenceDate`, including moved
exceptions; all-day recurrence anchors use the local Gregorian date. A full provider
resync may replace fallback local identifiers: EventKit offers no stronger stable
identifier in that case, so provider migrations require review before writes.

Private settings/receipts use `AtomicStore` under Application Support. Settings UUID
is persisted before provider activity. Old v1 settings default to 7 days back/90 ahead;
controls permit 0–365 back and 1–365 ahead. Ownership receipts contain only installation,
private target identity, row ID and opaque expected marker. Known row IDs are checked
across every prior target receipt, so a known row moved into
another selected calendar (including stripped/replaced notes) makes that calendar read
uncertain and never becomes a source/export original. Provider moves or full resyncs
may change local row IDs. If a provider both replaces a row ID and strips all ownership
notes, EventKit supplies no guaranteed identity to correlate that row; this journal
cannot prove its provenance. No title/time guess is used as a substitute. An unchanged
valid marker still excludes the row even when its local ID changes. Managed availability
is preserved into reconciliation: only confirmed Busy blocks satisfy desired coverage;
Free/unknown owned blocks require repair after complete reads. Create replay accepts
only a matching Busy row. Before a create, the adapter separately verifies unchanged
same-link protected boundary rows against the reviewed complete read; they are retained
while uncovered in-window Busy fragments are created. Changed, new or missing boundary
rows invalidate the plan. Pending creates persist the opaque marker, requested bounds
and all-day state before writes; only a safe Busy row with those exact bounds/state
resolves commit-before-error. Existing same-marker boundary rows cannot resolve a new
create. Legacy pending records lacking intent bounds remain quarantined. An unresolved
pending create quarantines its target until its exact intended Busy row is observed or a separately reviewed recovery resolves the uncertainty. There is
no automatic repair by title/time, and no manual receipt-reset tool in this stage.

## Background agent and closed SSH transport

The same app owns foreground settings and the background coordinator. A private
kernel-held `process.lock` is acquired before constructing an EventKit provider.
A second manual launch brings the current owner's settings forward and exits;
a second agent launch exits without reading calendars. The lock is released by
process exit, including crashes. A user LaunchAgent invokes the **signed bundle's
executable** with `--background`, keeps it alive and throttles repeated starts.
Settings remain available through the menu bar. Background launch never prompts
for Calendar permission; the owner grants full access through settings first.

Use `python3 scripts/install-agent.py generate --app /absolute/path/Bridge.app
--output /private/path/agent.plist` to review a generated agent without installing
or starting it. `install --app ...` verifies the existing bundle signature, writes
a private per-user LaunchAgent and bootstraps it. Subsequent `stop`, `start`, and
`restart` operate on that launchd service; `uninstall` removes its plist after
stopping it. Uninstall also accepts an already-unloaded named service (ESRCH);
other launchctl failures preserve the plist and fail visibly. KeepAlive restarts an app quit while installed: use `stop` before
quitting when persistent shutdown is intended. A manual owner can keep syncing
after `stop` because it is independent of launchd; quit that owner explicitly.
Installation never enables event writes or modifies calendar settings.

The coordinator repairs on launch, wake and every five minutes. EventKit changes
are debounced for five seconds; work is serial even while SSH is suspended.
Notifications from managed writes converge through fresh idempotent planning.
Failures retry with 5/10/20-second backoff capped at five minutes. Stop cancels
future scheduled work; an already submitted SSH payload may finish within its
30-second deadline. After publication suspends, local apply obtains fresh complete
read evidence to prevent foreground previews from replacing the adapter's evidence.

The default mode exports originals without writing events. Count-only planning is
explicit; a planner error cannot block an otherwise valid snapshot publication.
With writes enabled, planning errors fail only reconciliation and schedule repair.
The settings action **Проверить активный план записи** reviews the count-only plan
for saved active settings. **Начальная проверка завершена — включить запись**
requires that review and an unchanged, complete fresh plan. The owner uses it only
after the initial real-provider checks. `write-intent.json` records version,
installation UUID and SHA-256 of the exact active settings through `AtomicStore`;
no event data or duplicate ownership journal is stored there. Enabled mode survives
login/restart, but every run must obtain complete reads and one-shot adapter
authorization for its current plan. Legacy/missing/corrupt mode data starts with
writes off; corruption is visible. Draft edits revoke write intent immediately;
applying changed policies/window also revokes it. The OFF action persists revocation.
The OFF action stays available while SSH is in flight and prevents the suspended
run from subsequently applying a plan. A failed revocation leaves writes off in
memory and shows that restart must wait
until private storage is repaired.

**Передать снимок в HA сейчас** is available in settings and the menu. Publication
and busy reconciliation are independent: a failed apply still permits originals /
health publication, and failed SSH does not stop otherwise reviewed local writes.
The displayed last-successful timestamp advances only after successful SSH exit.
Failures never replace it or create a Mac event cache. Incomplete calendars emit
health-only entries according to the shared snapshot contract; HA keeps old events.

Private `ssh.json` in the same Application Support directory contains `hostAlias`,
absolute `identityFile`, absolute `knownHostsFile`, `port` (default 22), and optional
absolute `configFile`. It is loaded through `AtomicStore`; bindings remain outside
Git. Use a private SSH config to bind an alias, remote user and host. The transport
uses native `/usr/bin/ssh`, strict host verification, BatchMode, no multiplexing,
no proxy/local commands, bounded connection/alive checks and a 30-second deadline.
Only JSON stdin carries event text. Its constant remote command is:

```
docker exec -i homeassistant python /config/_tools/belovodie_calendar_bridge/ha_ssh_receiver.py
```

The controller deploys that adapter inside the Home Assistant container separately.
The receiver reads one bounded snapshot, rejects invalid/duplicate JSON roots and
versions, then POSTs `{"snapshot": ...}` to the fixed native service
`belovodie_calendar_bridge.publish`; that service validates the complete contract
before state mutation. The receiver resolves `(url, token)` only through HA-local
`/config/_tools/ai_ollama/common.py:_get_ha_config`. No HA token is copied to the Mac.
Process output is discarded, and the receiver prints only generic success/failure.
No titles, identifiers, credentials or response state attributes enter logs.

The source tests use fake calendars, private temporary files and local child
processes. They do not prove actual signed-app visibility, Calendar/cloud behavior,
launchd/menu settings handoff or SSH-to-HA delivery. Those gates require the
controller's stable signing, launchd start/stop/restart and initial provider checks.

Read/snapshot failures expose only the bounded `readSnapshotFailureCode` enum and
its fixed code in publication/menu status (for example
`snapshotInvalidAllDayBoundary` or `calendarPermissionRequired`). Known
`SnapshotError` / `EventKitAdapterError` cases map exhaustively; other errors map
to `unknownReadOrSnapshotFailure`. Provider counts, error descriptions, titles,
raw identities, zones and payloads are never interpolated. The code clears when
snapshot validation succeeds and the run reaches transport, so a later transport
failure cannot retain a stale validation diagnosis. Codes identify the rejected
contract; they do not establish the underlying native provider cause.
