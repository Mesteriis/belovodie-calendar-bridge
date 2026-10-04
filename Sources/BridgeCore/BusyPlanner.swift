import Foundation

/// Pure reconciliation. A plan authorizes no writes by itself; the adapter must review/apply it serially.
public struct BusyPlanner: Sendable {
    public let installationID: UUID

    public init(installationID: UUID) {
        self.installationID = installationID
    }

    public func plan(events: [SourceEvent], policies: [CalendarPolicy], existing: [ManagedBlock],
                     window: QueryWindow, completeSources: Set<String>) throws -> BusyPlan {
        guard Self.valid(start: window.start, end: window.end) else { throw BusyPlannerError.invalidWindow }
        guard events.allSatisfy({ Self.valid(start: $0.interval.start, end: $0.interval.end) }) else {
            throw BusyPlannerError.invalidEventInterval
        }
        guard Set(policies.map(\.identity)).count == policies.count else {
            throw BusyPlannerError.duplicateCalendarPolicy
        }

        var instances: [String: SourceEvent] = [:]
        for event in events {
            if let previous = instances[event.instanceIdentity], previous != event {
                throw BusyPlannerError.ambiguousEventIdentity
            }
            instances[event.instanceIdentity] = event
        }

        let ownership = Ownership(installationID: installationID)
        let busySources = Set(policies.filter(\.busySource).map(\.identity))
        let sourcesComplete = busySources.isSubset(of: completeSources)
        let completeDigests = Set(completeSources.map(ownership.calendarDigest))
        // Only an explicit saved policy disable permits cleanup without another source read.
        let disabledDigests = Set(policies.filter { !$0.busySource }.map { ownership.calendarDigest($0.identity) })
        let originals = events.filter {
            !$0.isCancelled && $0.participation != .declined && $0.availability != .free
                && Ownership.decode($0.ownershipMarker) == nil
        }
        var creates: [DesiredBlock] = []
        var updates: [BlockUpdate] = []
        var deletes: [ManagedBlock] = []
        var suppressed = !sourcesComplete

        for target in policies.sorted(by: { $0.identity < $1.identity }) {
            let owned = existing.compactMap { block -> OwnedBlock? in
                guard block.calendarIdentity == target.identity,
                      let marker = Ownership.decode(block.ownershipMarker),
                      marker.installationID == installationID,
                      marker.targetID == ownership.calendarDigest(target.identity) else { return nil }
                return OwnedBlock(block: block, marker: marker)
            }.sorted { $0.block.id < $1.block.id }

            guard completeSources.contains(target.identity) else {
                if target.busyTarget || !owned.isEmpty { suppressed = true }
                continue
            }

            let desired = target.busyTarget
                ? try desiredBlocks(originals: originals, target: target, busySources: busySources,
                                window: window, ownership: ownership)
                : []
            var consumed: Set<Int> = []

            for plannedBlock in desired {
                let marker = Ownership.decode(plannedBlock.ownershipMarker)!
                let sameLink = owned.indices.filter { owned[$0].marker.linkID == marker.linkID }
                let protected = sameLink.filter { !Self.contained(owned[$0].block.interval, in: window) }
                var uncovered = [plannedBlock.interval]
                for index in protected where owned[index].block.availability == .busy {
                    let interval = owned[index].block.interval
                    if Self.valid(start: interval.start, end: interval.end) {
                        uncovered = uncovered.flatMap { Self.subtract(interval, from: $0) }
                    }
                }
                // Valid protected spans can only cover the window's prefix/suffix, leaving at most one gap.
                guard let interval = uncovered.first else { continue }
                let block = DesiredBlock(sourceID: plannedBlock.sourceID, calendarID: plannedBlock.calendarID,
                                         title: plannedBlock.title, interval: interval,
                                         isAllDay: plannedBlock.isAllDay && interval == plannedBlock.interval,
                                         ownershipMarker: plannedBlock.ownershipMarker)
                // Preserved boundary blocks cannot be updated, or suppress a moved instance's uncovered time.
                let matches = sameLink.filter { Self.contained(owned[$0].block.interval, in: window) }
                guard let index = matches.first(where: { Self.matches(owned[$0].block, block) }) ?? matches.first else {
                    creates.append(block)
                    continue
                }
                consumed.insert(index)
                if !Self.matches(owned[index].block, block) {
                    if sourcesComplete && owned[index].marker.sourceIDs.isSubset(of: completeDigests.union(disabledDigests)) {
                        updates.append(BlockUpdate(existingID: owned[index].block.id, replacement: block))
                    } else {
                        suppressed = true
                    }
                }
            }

            for index in owned.indices where !consumed.contains(index) {
                let candidate = owned[index]
                guard Self.contained(candidate.block.interval, in: window) else { continue }
                if sourcesComplete && candidate.marker.sourceIDs.isSubset(of: completeDigests.union(disabledDigests)) {
                    deletes.append(candidate.block)
                } else {
                    suppressed = true
                }
            }
        }
        return BusyPlan(creates: creates, updates: updates, deletes: deletes, cleanupSuppressed: suppressed)
    }

    private struct OwnedBlock {
        let block: ManagedBlock
        let marker: Ownership.Marker
    }

    private struct Span {
        var interval: EventInterval
        var eventIdentities: Set<String>
        var sourceIdentities: Set<String>
        var isAllDay: Bool
    }

    private func desiredBlocks(originals: [SourceEvent], target: CalendarPolicy, busySources: Set<String>,
                               window: QueryWindow, ownership: Ownership) throws -> [DesiredBlock] {
        let foreign = originals.filter { $0.calendarIdentity != target.identity && busySources.contains($0.calendarIdentity) }
        let spans = foreign.compactMap { event -> Span? in
            guard let clipped = Self.clip(event.interval, to: window) else { return nil }
            return Span(interval: clipped, eventIdentities: [event.instanceIdentity], sourceIdentities: [event.calendarIdentity],
                        isAllDay: event.isAllDay && clipped == event.interval)
        }.sorted { lhs, rhs in
            lhs.interval.start == rhs.interval.start ? lhs.interval.end < rhs.interval.end : lhs.interval.start < rhs.interval.start
        }
        var merged: [Span] = []
        for span in spans {
            if let last = merged.last, span.interval.start <= last.interval.end {
                let index = merged.count - 1
                merged[index].interval = EventInterval(start: last.interval.start, end: max(last.interval.end, span.interval.end))
                merged[index].eventIdentities.formUnion(span.eventIdentities)
                merged[index].sourceIdentities.formUnion(span.sourceIdentities)
                merged[index].isAllDay = last.isAllDay && span.isAllDay
            } else {
                merged.append(span)
            }
        }
        let own = originals.filter { $0.calendarIdentity == target.identity }.map(\.interval)
            .sorted { $0.start < $1.start }
        var result: [DesiredBlock] = []
        for span in merged {
            var fragments = [span.interval]
            for coverage in own {
                fragments = fragments.flatMap { Self.subtract(coverage, from: $0) }
            }
            for (index, interval) in fragments.enumerated() {
                let link = ownership.linkDigest(targetIdentity: target.identity, eventIdentities: span.eventIdentities, fragment: index)
                result.append(DesiredBlock(sourceID: target.sourceID, calendarID: target.calendarID, title: "Занято",
                                           interval: interval, isAllDay: span.isAllDay && interval == span.interval,
                                           ownershipMarker: try ownership.encode(linkID: link, targetIdentity: target.identity,
                                                                             sourceIdentities: span.sourceIdentities)))
            }
        }
        return result
    }

    private static func matches(_ existing: ManagedBlock, _ desired: DesiredBlock) -> Bool {
        existing.title == desired.title && existing.interval == desired.interval && existing.isAllDay == desired.isAllDay
            && existing.availability == .busy
            && Ownership.decode(existing.ownershipMarker) == Ownership.decode(desired.ownershipMarker)
    }

    private static func valid(start: Date, end: Date) -> Bool {
        start.timeIntervalSince1970.isFinite && end.timeIntervalSince1970.isFinite && start < end
    }

    private static func contained(_ interval: EventInterval, in window: QueryWindow) -> Bool {
        valid(start: interval.start, end: interval.end) && interval.start >= window.start && interval.end <= window.end
    }

    private static func clip(_ interval: EventInterval, to window: QueryWindow) -> EventInterval? {
        let start = max(interval.start, window.start)
        let end = min(interval.end, window.end)
        return start < end ? EventInterval(start: start, end: end) : nil
    }

    private static func subtract(_ coverage: EventInterval, from interval: EventInterval) -> [EventInterval] {
        guard coverage.start < interval.end && coverage.end > interval.start else { return [interval] }
        var result: [EventInterval] = []
        if coverage.start > interval.start { result.append(EventInterval(start: interval.start, end: coverage.start)) }
        if coverage.end < interval.end { result.append(EventInterval(start: coverage.end, end: interval.end)) }
        return result
    }
}
