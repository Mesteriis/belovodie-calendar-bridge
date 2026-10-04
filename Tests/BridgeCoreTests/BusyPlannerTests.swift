import Foundation
import XCTest
@testable import BridgeCore

final class BusyPlannerTests: XCTestCase {
    let installation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let otherInstallation = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let window = QueryWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 10_000))

    func policy(_ calendar: String, source: String = "account", export: Bool = false,
                busySource: Bool = false, target: Bool = false) -> CalendarPolicy {
        CalendarPolicy(sourceID: source, calendarID: calendar, owner: "Owner", label: "Label",
                       exportToHA: export, busySource: busySource, busyTarget: target)
    }

    func event(_ id: String, calendar: String = "a", source: String = "account",
               start: Double = 100, end: Double = 200, title: String = "Private",
               status: ParticipationStatus = .accepted, availability: EventAvailability = .busy,
               cancelled: Bool = false, marker: String? = nil, occurrence: String? = nil,
               allDay: Bool = false) -> SourceEvent {
        SourceEvent(sourceID: source, calendarID: calendar, eventID: id, occurrenceID: occurrence,
                    title: title, interval: EventInterval(start: Date(timeIntervalSince1970: start),
                                                        end: Date(timeIntervalSince1970: end)),
                    isAllDay: allDay, participation: status, availability: availability,
                    isCancelled: cancelled, ownershipMarker: marker)
    }

    func plan(_ events: [SourceEvent], policies: [CalendarPolicy]? = nil,
              existing: [ManagedBlock] = [], complete: Set<String>? = nil,
              in query: QueryWindow? = nil) throws -> BusyPlan {
        let selected = policies ?? [policy("a", busySource: true), policy("b", target: true)]
        return try BusyPlanner(installationID: installation).plan(
            events: events, policies: selected, existing: existing, window: query ?? window,
            completeSources: complete ?? Set(selected.map(\.identity)))
    }

    func stored(_ desired: DesiredBlock, id: String = "managed") -> ManagedBlock {
        ManagedBlock(id: id, sourceID: desired.sourceID, calendarID: desired.calendarID,
                     title: desired.title, interval: desired.interval, isAllDay: desired.isAllDay,
                     ownershipMarker: desired.ownershipMarker)
    }

    func testNewPoliciesAreDisabledAndDoNotCreateBlocks() throws {
        let a = CalendarPolicy(sourceID: "account", calendarID: "a", owner: "Owner", label: "Label")
        let b = CalendarPolicy(sourceID: "account", calendarID: "b", owner: "Owner", label: "Label")
        XCTAssertFalse(a.exportToHA)
        XCTAssertFalse(a.busySource)
        XCTAssertFalse(a.busyTarget)
        XCTAssertTrue(try plan([event("one")], policies: [a, b]).creates.isEmpty)
    }

    func testExportFlagDoesNotControlBusySourceOrTarget() throws {
        let busy = try plan([event("one")], policies: [policy("a", busySource: true), policy("b", target: true)])
        XCTAssertEqual(busy.creates.count, 1)
        let exporting = try plan([event("one")], policies: [policy("a", export: true), policy("b", target: true)])
        XCTAssertTrue(exporting.creates.isEmpty)
        let noTarget = try plan([event("one")], policies: [policy("a", busySource: true), policy("b", export: true)])
        XCTAssertTrue(noTarget.creates.isEmpty)
    }

    func testNoSelfMirroringAndIdentityIsPerCalendar() throws {
        let a = policy("a", busySource: true, target: true)
        XCTAssertTrue(try plan([event("one")], policies: [a]).creates.isEmpty)
        XCTAssertEqual(try plan([event("one")], policies: [a, policy("b", target: true)]).creates.count, 1)
        let renamed = CalendarPolicy(sourceID: "account", calendarID: "a", owner: "New", label: "Renamed")
        XCTAssertEqual(a.identity, renamed.identity)
        XCTAssertNotEqual(a.identity, policy("a", source: "other").identity)
        XCTAssertNotEqual(policy("bc", source: "a").identity, policy("c", source: "ab").identity)
    }

    func testParticipationCancellationAndFreeFiltering() throws {
        let events = [event("accepted", start: 100, end: 200),
                      event("tentative", start: 300, end: 400, status: .tentative),
                      event("own", start: 500, end: 600, status: .organizer),
                      event("declined", start: 700, end: 800, status: .declined),
                      event("cancelled", start: 900, end: 1000, cancelled: true),
                      event("free", start: 1100, end: 1200, availability: .free)]
        let result = try plan(events)
        XCTAssertEqual(result.creates.map { $0.interval.start.timeIntervalSince1970 }, [100, 300, 500])
    }

    func testOwnedAndForeignMarkersNeverBecomeSourcesButNormalBusyTitleDoes() throws {
        let codec = Ownership(installationID: installation)
        let own = try codec.encode(linkID: String(repeating: "a", count: 64), targetIdentity: policy("a").identity, sourceIdentities: [policy("b").identity])
        let foreign = try Ownership(installationID: otherInstallation).encode(linkID: String(repeating: "b", count: 64), targetIdentity: policy("a").identity, sourceIdentities: [policy("b").identity])
        let result = try plan([event("normal", title: "Занято"),
                               event("own", start: 300, end: 400, marker: own),
                               event("foreign", start: 500, end: 600, marker: foreign)])
        XCTAssertEqual(result.creates.count, 1)
        XCTAssertEqual(result.creates.first?.interval.start.timeIntervalSince1970, 100)
        XCTAssertEqual(result.creates.first?.title, "Занято")
    }

    func testOverlapsAndDuplicateIntervalsMerge() throws {
        let result = try plan([event("first", start: 100, end: 300),
                               event("second", start: 200, end: 500),
                               event("duplicate", start: 100, end: 300)])
        XCTAssertEqual(result.creates.count, 1)
        XCTAssertEqual(result.creates.first?.interval, EventInterval(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 500)))
    }

    func testTargetOwnExactBusyCoverageSuppressesBlockEvenWithoutBusySourceFlag() throws {
        XCTAssertTrue(try plan([event("remote"), event("local", calendar: "b")]).creates.isEmpty)
    }

    func testPartialOwnOverlapLeavesBothUncoveredRemainders() throws {
        let result = try plan([event("remote", start: 100, end: 500),
                               event("local", calendar: "b", start: 200, end: 300)])
        XCTAssertEqual(result.creates.map { $0.interval.start.timeIntervalSince1970 }, [100, 300])
        XCTAssertEqual(result.creates.map { $0.interval.end.timeIntervalSince1970 }, [200, 500])
    }

    func testMovedEventUpdatesOwnedBlockAndRerunIsIdempotent() throws {
        let initial = try XCTUnwrap(plan([event("stable")]).creates.first)
        let result = try plan([event("stable", start: 300, end: 400)], existing: [stored(initial)])
        XCTAssertTrue(result.creates.isEmpty)
        XCTAssertTrue(result.deletes.isEmpty)
        XCTAssertEqual(result.updates.count, 1)
        XCTAssertEqual(result.updates.first?.existingID, "managed")
        XCTAssertEqual(result.updates.first?.replacement.interval.start.timeIntervalSince1970, 300)
        let updated = try XCTUnwrap(result.updates.first?.replacement)
        let rerun = try plan([event("stable", start: 300, end: 400)], existing: [stored(updated)])
        XCTAssertTrue(rerun.creates.isEmpty)
        XCTAssertTrue(rerun.updates.isEmpty)
        XCTAssertTrue(rerun.deletes.isEmpty)
    }

    func testRecurringInstancesHaveDistinctLinksAndOneMovedInstanceUpdates() throws {
        let original = [event("series", occurrence: "instance-1"),
                        event("series", start: 300, end: 400, occurrence: "instance-2")]
        let initial = try plan(original)
        XCTAssertEqual(initial.creates.count, 2)
        let first = try XCTUnwrap(initial.creates.first)
        let second = try XCTUnwrap(initial.creates.dropFirst().first)
        XCTAssertNotEqual(first.ownershipMarker, second.ownershipMarker)
        let existing = initial.creates.enumerated().map { stored($0.element, id: "block-\($0.offset)") }
        let result = try plan([original[0], event("series", start: 500, end: 600, occurrence: "instance-2")], existing: existing)
        XCTAssertEqual(result.updates.count, 1)
        XCTAssertEqual(result.updates.first?.existingID, "block-1")
        XCTAssertTrue(result.creates.isEmpty)
        XCTAssertTrue(result.deletes.isEmpty)
    }

    func testOwnershipIsOpaqueAndToleratesProviderWhitespace() throws {
        let result = try XCTUnwrap(plan([event("secret-event", calendar: "private-calendar", source: "private-account")],
                                       policies: [policy("private-calendar", source: "private-account", busySource: true), policy("b", target: true)]).creates.first)
        for secret in ["secret-event", "private-calendar", "private-account", "Owner", "Label", "Private"] {
            XCTAssertFalse(result.ownershipMarker.contains(secret))
        }
        let normalized = result.ownershipMarker.map(String.init).joined(separator: " \n\t")
        let decoded = try XCTUnwrap(Ownership.decode(normalized))
        XCTAssertEqual(decoded.installationID, installation)
        XCTAssertEqual(decoded.linkID.count, 64)
        let managed = ManagedBlock(id: "normalized", sourceID: "account", calendarID: "b", title: "Занято",
                                   interval: result.interval, isAllDay: false, ownershipMarker: normalized)
        let rerun = try plan([event("secret-event", calendar: "private-calendar", source: "private-account")],
                             policies: [policy("private-calendar", source: "private-account", busySource: true), policy("b", target: true)],
                             existing: [managed])
        XCTAssertTrue(rerun.creates.isEmpty)
        XCTAssertTrue(rerun.updates.isEmpty)
        XCTAssertTrue(rerun.deletes.isEmpty)
        XCTAssertNil(Ownership.decode("ordinary notes"))
        XCTAssertNil(Ownership.decode(result.ownershipMarker + "extra"))
    }

    func testCleanupOnlyDeletesOwnedBlocksAndDisabledTargetsAreCleaned() throws {
        let desired = try XCTUnwrap(plan([event("one")]).creates.first)
        let own = stored(desired, id: "own")
        let foreign = ManagedBlock(id: "foreign", sourceID: "account", calendarID: "b", title: "Занято", interval: desired.interval,
                                   isAllDay: false, ownershipMarker: try Ownership(installationID: otherInstallation).encode(linkID: String(repeating: "c", count: 64), targetIdentity: policy("b").identity, sourceIdentities: [policy("a").identity]))
        let original = ManagedBlock(id: "user-original", sourceID: "account", calendarID: "b", title: "Занято", interval: desired.interval,
                                    isAllDay: false, ownershipMarker: nil)
        let result = try plan([], existing: [own, foreign, original])
        XCTAssertEqual(result.deletes.map(\.id), ["own"])
        let disabled = try plan([], policies: [policy("a"), policy("b")], existing: [own])
        XCTAssertEqual(disabled.deletes.map(\.id), ["own"])
    }

    func testIncompleteSourcesSuppressDeletionAndShrinkingUpdates() throws {
        let desired = try XCTUnwrap(plan([event("one")]).creates.first)
        let completeTarget = Set([policy("b").identity])
        let result = try plan([], existing: [stored(desired)], complete: completeTarget)
        XCTAssertTrue(result.deletes.isEmpty)
        XCTAssertTrue(result.updates.isEmpty)
        XCTAssertTrue(result.cleanupSuppressed)
        let moved = try plan([event("one", start: 300, end: 400)], existing: [stored(desired)], complete: completeTarget)
        XCTAssertTrue(moved.updates.isEmpty)
        // An account identifier is insufficient evidence that this calendar read completed.
        let wrong = try plan([], existing: [stored(desired)], complete: Set(["account"]))
        XCTAssertTrue(wrong.deletes.isEmpty)
    }

    func testIncompleteTargetPreventsDuplicateWritesAndUnknownTargetsAreUntouched() throws {
        let desired = try XCTUnwrap(plan([event("one")]).creates.first)
        let result = try plan([event("one")], complete: Set([policy("a").identity]))
        XCTAssertTrue(result.creates.isEmpty)
        XCTAssertTrue(result.cleanupSuppressed)
        let missingPolicy = try plan([], policies: [policy("a", busySource: true)], existing: [stored(desired)])
        XCTAssertTrue(missingPolicy.deletes.isEmpty)
    }

    func testVanishedSourcePolicyIsNotAnExplicitDisable() throws {
        let desired = try XCTUnwrap(plan([event("one")]).creates.first)
        let absent = try plan([], policies: [policy("b", target: true)], existing: [stored(desired)])
        XCTAssertTrue(absent.deletes.isEmpty)
        XCTAssertTrue(absent.cleanupSuppressed)
        let disabled = try plan([], policies: [policy("a"), policy("b", target: true)],
                                existing: [stored(desired)], complete: [policy("b").identity])
        XCTAssertEqual(disabled.deletes.map(\.id), ["managed"])
    }

    func testCopiedOwnershipMarkerCannotAuthorizeAnotherTarget() throws {
        let desired = try XCTUnwrap(plan([event("one")]).creates.first)
        let copy = ManagedBlock(id: "copied", sourceID: "account", calendarID: "c", title: "Занято",
                                interval: desired.interval, ownershipMarker: desired.ownershipMarker)
        let result = try plan([], policies: [policy("a", busySource: true), policy("c", target: true)], existing: [copy])
        XCTAssertTrue(result.deletes.isEmpty)
    }

    func testDuplicateOwnedBlocksAreReconciled() throws {
        let desired = try XCTUnwrap(plan([event("one")]).creates.first)
        let result = try plan([event("one")], existing: [stored(desired, id: "first"), stored(desired, id: "second")])
        XCTAssertEqual(result.deletes.map(\.id), ["second"])
        XCTAssertTrue(result.creates.isEmpty)
    }

    func testWindowClipsAndLeavesOutsideBlocksUntouched() throws {
        let query = QueryWindow(start: Date(timeIntervalSince1970: 150), end: Date(timeIntervalSince1970: 250))
        let result = try plan([event("clipped", start: 100, end: 300)], in: query)
        XCTAssertEqual(result.creates.first?.interval.start.timeIntervalSince1970, 150)
        XCTAssertEqual(result.creates.first?.interval.end.timeIntervalSince1970, 250)
        let outside = try XCTUnwrap(plan([event("outside", start: 500, end: 600)]).creates.first)
        XCTAssertTrue(try plan([], existing: [stored(outside)], in: query).deletes.isEmpty)
    }

    func testBoundaryCrossingOldBlockDoesNotSuppressMovedCoverage() throws {
        let query = QueryWindow(start: Date(timeIntervalSince1970: 150), end: Date(timeIntervalSince1970: 250))
        let initial = try XCTUnwrap(plan([event("stable", start: 100, end: 200)]).creates.first)
        let old = stored(initial, id: "old-boundary-block")
        let moved = event("stable", start: 210, end: 240)
        let result = try plan([moved], existing: [old], in: query)
        XCTAssertEqual(result.creates.count, 1)
        let addition = try XCTUnwrap(result.creates.first)
        XCTAssertEqual(addition.interval, EventInterval(start: Date(timeIntervalSince1970: 210),
                                                       end: Date(timeIntervalSince1970: 240)))
        XCTAssertTrue(result.updates.isEmpty)
        XCTAssertTrue(result.deletes.isEmpty)
        let rerun = try plan([moved], existing: [old, stored(addition, id: "new-block")], in: query)
        XCTAssertTrue(rerun.creates.isEmpty)
        XCTAssertTrue(rerun.updates.isEmpty)
        XCTAssertTrue(rerun.deletes.isEmpty)
    }

    func testProtectedBoundaryCoverageCreatesOnlyItsUncoveredRemainder() throws {
        let query = QueryWindow(start: Date(timeIntervalSince1970: 150), end: Date(timeIntervalSince1970: 250))
        let initial = try XCTUnwrap(plan([event("stable", start: 100, end: 200)]).creates.first)
        let old = stored(initial, id: "old-boundary-block")
        let moved = event("stable", start: 180, end: 240)
        let result = try plan([moved], existing: [old], in: query)
        let addition = try XCTUnwrap(result.creates.first)
        XCTAssertEqual(result.creates.count, 1)
        XCTAssertEqual(addition.interval, EventInterval(start: Date(timeIntervalSince1970: 200),
                                                       end: Date(timeIntervalSince1970: 240)))
        XCTAssertTrue(result.updates.isEmpty)
        XCTAssertTrue(result.deletes.isEmpty)
        let rerun = try plan([moved], existing: [old, stored(addition, id: "new-block")], in: query)
        XCTAssertTrue(rerun.creates.isEmpty)
        XCTAssertTrue(rerun.updates.isEmpty)
        XCTAssertTrue(rerun.deletes.isEmpty)
        let unchanged = try plan([event("stable", start: 100, end: 200)], existing: [old], in: query)
        XCTAssertTrue(unchanged.creates.isEmpty)
        XCTAssertTrue(unchanged.updates.isEmpty)
        XCTAssertTrue(unchanged.deletes.isEmpty)
    }

    func testAllDaySpanAcrossDSTUsesAbsoluteProviderBoundaries() throws {
        let parser = ISO8601DateFormatter()
        let start = parser.date(from: "2026-03-28T23:00:00Z")! // Madrid midnight
        let end = parser.date(from: "2026-03-29T22:00:00Z")! // next midnight, 23-hour day
        let original = event("all-day", start: start.timeIntervalSince1970, end: end.timeIntervalSince1970, allDay: true)
        let query = QueryWindow(start: start.addingTimeInterval(-86_400), end: end.addingTimeInterval(86_400))
        let result = try XCTUnwrap(plan([original], in: query).creates.first)
        XCTAssertEqual(result.interval, original.interval)
        XCTAssertTrue(result.isAllDay)
        XCTAssertEqual(result.interval.end.timeIntervalSince(result.interval.start), 23 * 3600)
        let autumnStart = parser.date(from: "2026-10-24T22:00:00Z")!
        let autumnEnd = parser.date(from: "2026-10-25T23:00:00Z")!
        let autumn = event("autumn", start: autumnStart.timeIntervalSince1970, end: autumnEnd.timeIntervalSince1970, allDay: true)
        let autumnResult = try XCTUnwrap(plan([autumn], in: QueryWindow(start: autumnStart, end: autumnEnd)).creates.first)
        XCTAssertEqual(autumnResult.interval.end.timeIntervalSince(autumnResult.interval.start), 25 * 3600)
        let multiDay = event("multi-day", start: start.timeIntervalSince1970, end: end.addingTimeInterval(86_400).timeIntervalSince1970, allDay: true)
        XCTAssertEqual(try plan([multiDay], in: QueryWindow(start: start, end: multiDay.interval.end)).creates.first?.interval, multiDay.interval)
    }

    func testInvalidMarkerEncodingFailsWithoutProducingUnrecognizableNotes() throws {
        let ownership = Ownership(installationID: installation)
        XCTAssertThrowsError(try ownership.encode(linkID: "bad", targetIdentity: policy("b").identity,
                                                  sourceIdentities: [policy("a").identity]))
    }

    func testEmptyMarkerSourcesFailClosed() throws {
        let ownership = Ownership(installationID: installation)
        XCTAssertThrowsError(try ownership.encode(linkID: String(repeating: "a", count: 64),
                                                  targetIdentity: policy("b").identity, sourceIdentities: []))
    }

    func testInconsistentDuplicateInstancesFailClosedInsteadOfCollidingLinks() throws {
        XCTAssertThrowsError(try plan([event("same"), event("same", start: 300, end: 400)]))
        XCTAssertEqual(try plan([event("same"), event("same")]).creates.count, 1)
    }

    func testInvalidWindowIntervalsAndDuplicatePoliciesFailClosed() throws {
        XCTAssertThrowsError(try plan([], in: QueryWindow(start: window.end, end: window.start)))
        XCTAssertThrowsError(try plan([event("invalid", start: 200, end: 100)]))
        XCTAssertThrowsError(try plan([], policies: [policy("a"), policy("a", target: true)]))
    }
}
