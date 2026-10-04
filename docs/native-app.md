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

The app has no action that authorizes or applies event writes. No background agent,
HA transmission, or automatic permission prompt is installed by this task. Event
write APIs require explicit one-shot review of the exact `BusyPlan`, complete local
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
only a matching Busy row. Pending creates are persisted before writes; exact returned
markers recover
commit-before-error. An unresolved pending create quarantines its target until its exact
marker is observed or a separately reviewed recovery resolves the uncertainty. There is
no automatic repair by title/time, and no manual receipt-reset tool in this stage.
