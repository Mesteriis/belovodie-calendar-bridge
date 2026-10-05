import Foundation
import Observation
import CryptoKit
import BridgeCore

@MainActor public final class SyncCancellation {
    public private(set) var cancelled = false
    private var task: Task<Void, Never>?
    public init() {}
    func attach(_ task: Task<Void, Never>) { self.task = task }
    public func cancel() { cancelled = true; task?.cancel(); task = nil }
}
@MainActor public protocol SyncClock {
    var now: Date { get }
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> SyncCancellation
}
@MainActor public final class SystemSyncClock: SyncClock {
    public init() {}
    public var now: Date { Date() }
    public func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> SyncCancellation {
        let token = SyncCancellation()
        token.attach(Task { [weak token] in
            do { try await Task.sleep(for: .seconds(max(0, seconds))) } catch { return }
            guard let token, !token.cancelled else { return }
            action()
        })
        return token
    }
}
@MainActor public protocol SnapshotTransport { func send(snapshot: CalendarSnapshot) async throws }
public enum SyncReason { case eventChanged, manual, wake, startup, repair }
public enum SyncCoordinatorError: Error { case reviewRequired, incompleteRead, busy, invalidMode }
/// Bounded diagnostics only: never expose error descriptions or associated provider data.
public enum ReadSnapshotFailureCode: String, Sendable {
    case snapshotInvalidWindow, snapshotInvalidObservation, snapshotDuplicatePolicy, snapshotDuplicateCalendar
    case snapshotInvalidTimeZone, snapshotInvalidEventInterval, snapshotInvalidAllDayBoundary, snapshotAmbiguousEventIdentity
    case calendarPermissionRequired, calendarDuplicateCalendar, calendarMissingCalendar, calendarIncompleteRead
    case calendarNotWritable, calendarBusyUnsupported, calendarWritesDisabled, calendarInvalidOwnership
    case calendarStalePlan, calendarProviderWriteFailed, unknownReadOrSnapshotFailure

    static func classify(_ error: any Error) -> Self {
        if let error = error as? SnapshotError {
            switch error {
            case .invalidWindow: return .snapshotInvalidWindow
            case .invalidObservation: return .snapshotInvalidObservation
            case .duplicatePolicy: return .snapshotDuplicatePolicy
            case .duplicateCalendar: return .snapshotDuplicateCalendar
            case .invalidTimeZone: return .snapshotInvalidTimeZone
            case .invalidEventInterval: return .snapshotInvalidEventInterval
            case .invalidAllDayBoundary: return .snapshotInvalidAllDayBoundary
            case .ambiguousEventIdentity: return .snapshotAmbiguousEventIdentity
            }
        }
        if let error = error as? EventKitAdapterError {
            switch error {
            case .permissionRequired: return .calendarPermissionRequired
            case .duplicateCalendar: return .calendarDuplicateCalendar
            case .missingCalendar: return .calendarMissingCalendar
            case .incompleteRead: return .calendarIncompleteRead
            case .notWritable: return .calendarNotWritable
            case .busyUnsupported: return .calendarBusyUnsupported
            case .writesDisabled: return .calendarWritesDisabled
            case .invalidOwnership: return .calendarInvalidOwnership
            case .stalePlan: return .calendarStalePlan
            case .providerWriteFailed: return .calendarProviderWriteFailed
            }
        }
        return .unknownReadOrSnapshotFailure
    }
}
private struct WriteIntent: Codable {
    let version: Int
    let installationID: UUID
    let settingsDigest: String?
}

/// Owns one serial read/plan/apply/export run. No event cache or second ownership journal.
@Observable @MainActor public final class SyncCoordinator {
    public private(set) var running = false
    public private(set) var writesEnabled = false
    public private(set) var failed = false
    public private(set) var lastSuccessfulSync: Date?
    public private(set) var readSnapshotFailureCode: ReadSnapshotFailureCode?
    public private(set) var publicationStatus = "Передача ещё не запускалась"
    public private(set) var reconciliationStatus = "Запись выключена"
    public private(set) var status = "Фоновая синхронизация ещё не запущена"
    private let adapter: EventKitAdapter
    private var settings: BridgeSettings
    private let intentStore: AtomicStore
    private let transport: any SnapshotTransport
    private let clock: any SyncClock
    private var review: (BridgeSettings, BusyPlan)?
    private var debounce: SyncCancellation?
    private var repair: SyncCancellation?
    private var pending = false
    private var started = false
    private var stopped = false
    private var retryDelay: TimeInterval = 5
    private var revision = 0

    public init(adapter: EventKitAdapter, settings: BridgeSettings, directoryURL: URL,
                transport: any SnapshotTransport, clock: any SyncClock = SystemSyncClock()) {
        self.adapter = adapter; self.settings = settings; self.transport = transport; self.clock = clock
        intentStore = AtomicStore(fileURL: directoryURL.appendingPathComponent("write-intent.json"))
        do {
            if let data = try intentStore.load() {
                let intent = try JSONDecoder().decode(WriteIntent.self, from: data)
                guard intent.version == 1, intent.installationID == settings.installationID else { throw SyncCoordinatorError.invalidMode }
                writesEnabled = intent.settingsDigest == (try Self.digest(settings))
            }
        } catch { status = "Приватный режим записи недоступен. Запись выключена."; failed = true }
    }
    private static func digest(_ settings: BridgeSettings) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(settings)).map { String(format: "%02x", $0) }.joined()
    }
    public func start() {
        guard !started else { return }
        started = true; stopped = false
        requestSync(reason: .startup); scheduleRepair()
    }
    public func stop() {
        started = false; stopped = true; pending = false
        debounce?.cancel(); debounce = nil; repair?.cancel(); repair = nil
        // An already submitted SSH payload may finish; no subsequent work is launched.
    }
    private func scheduleRepair() {
        repair?.cancel()
        repair = clock.schedule(after: 300) { [weak self] in
            guard let self, self.started else { return }
            self.requestSync(reason: .repair); self.scheduleRepair()
        }
    }
    public func requestSync(reason: SyncReason) {
        guard !stopped else { return }
        debounce?.cancel()
        if reason != .eventChanged {
            debounce = nil
            if running { pending = true } else { launchRun() }
            return
        }
        debounce = clock.schedule(after: 5) { [weak self] in
            guard let self, !self.stopped else { return }
            self.debounce = nil
            if self.running { self.pending = true; return }
            self.launchRun()
        }
    }
    private func launchRun() {
        running = true
        Task { await run() }
    }
    public func updateSettings(_ settings: BridgeSettings) throws {
        if self.settings != settings && writesEnabled { try disableWrites() }
        self.settings = settings; review = nil; revision += 1
    }
    public func disableWrites() throws {
        // Always revoke in memory, including if the durable write fails. Report failure to caller.
        writesEnabled = false; review = nil; revision += 1
        try intentStore.save(JSONEncoder().encode(WriteIntent(version: 1, installationID: settings.installationID, settingsDigest: nil)))
    }
    public func previewInitialPlan() throws -> BusyPlan {
        guard !running else { throw SyncCoordinatorError.busy }
        review = nil
        let slice = try readSlice()
        let plan = try buildPlan(slice)
        guard slice.reads.allSatisfy(\.complete), !plan.cleanupSuppressed else { throw SyncCoordinatorError.incompleteRead }
        review = (settings, plan)
        return plan
    }
    public func enableReviewedWrites() throws {
        guard !running, let review, review.0 == settings else { throw SyncCoordinatorError.reviewRequired }
        // Re-read immediately before persisting operator opt-in. A changed plan needs another review.
        let slice = try readSlice()
        let plan = try buildPlan(slice)
        guard slice.reads.allSatisfy(\.complete), plan == review.1, !plan.cleanupSuppressed else { throw SyncCoordinatorError.reviewRequired }
        try intentStore.save(JSONEncoder().encode(WriteIntent(version: 1, installationID: settings.installationID, settingsDigest: try Self.digest(settings))))
        writesEnabled = true; self.review = nil
        status = "Запись включена для проверенных активных настроек"
    }
    private typealias ReadSlice = (reads: [SourceReadResult], window: QueryWindow)
    private func readSlice() throws -> ReadSlice {
        adapter.beginReadTransaction()
        guard adapter.access == .fullAccess else { throw EventKitAdapterError.permissionRequired }
        let calendar = Calendar.current; let today = calendar.startOfDay(for: clock.now)
        guard let start = calendar.date(byAdding: .day, value: -settings.lookbackDays, to: today),
              let end = calendar.date(byAdding: .day, value: settings.lookaheadDays, to: today) else { throw SyncCoordinatorError.incompleteRead }
        let window = QueryWindow(start: start, end: end)
        let reads = try settings.policies.filter { adapter.requiresRead($0) }.map { try adapter.read(policy: $0, window: window) }
        return (reads, window)
    }
    private func buildPlan(_ slice: ReadSlice) throws -> BusyPlan {
        try BusyPlanner(installationID: settings.installationID).plan(events: slice.reads.flatMap(\.events), policies: settings.policies, existing: slice.reads.flatMap(\.blocks), window: slice.window, completeSources: Set(slice.reads.filter(\.complete).map { $0.descriptor.identity }))
    }
    private func run() async {
        let runRevision = revision
        var needsRetry = false
        do {
            let slice = try readSlice()
            let snapshot = try SnapshotBuilder(installationID: settings.installationID).build(events: slice.reads.flatMap(\.events), policies: settings.policies, inventory: slice.reads.map(\.descriptor), window: slice.window, observedAt: clock.now)
            readSnapshotFailureCode = nil
            publicationStatus = "Снимок проверен. Передача выполняется."
            do {
                try await transport.send(snapshot: snapshot)
                lastSuccessfulSync = clock.now
                publicationStatus = "Снимок передан в HA. Состояние облака неизвестно."
            } catch {
                needsRetry = true
                publicationStatus = "Передача не завершена. Последний успешный результат сохранён."
            }
            if writesEnabled && runRevision == revision && !stopped {
                do {
                    // Sending suspends this actor: UI reads may replace adapter evidence meanwhile.
                    // Obtain fresh evidence for apply rather than using a pre-send plan/evidence pair.
                    let current = try readSlice()
                    let plan = try buildPlan(current)
                    guard current.reads.allSatisfy(\.complete), !plan.cleanupSuppressed else { throw SyncCoordinatorError.incompleteRead }
                    try adapter.authorizeReviewedPlan(plan); try adapter.apply(plan)
                    reconciliationStatus = "План занятости применён"
                } catch {
                    needsRetry = true
                    reconciliationStatus = "Запись не завершена. Повторное чтение и проверка обязательны."
                }
            } else { reconciliationStatus = writesEnabled ? "Настройки изменились; запись отложена" : "Запись выключена" }
        } catch {
            needsRetry = true
            let code = ReadSnapshotFailureCode.classify(error)
            readSnapshotFailureCode = code
            publicationStatus = "Чтение или снимок недоступны [\(code.rawValue)]. Успешные данные сохранены."
            reconciliationStatus = "Запись не выполнялась"
        }
        failed = needsRetry
        status = publicationStatus + " · " + reconciliationStatus
        if needsRetry && !stopped {
            debounce?.cancel()
            debounce = clock.schedule(after: retryDelay) { [weak self] in
                guard let self, !self.stopped else { return }
                self.debounce = nil
                if self.running { self.pending = true } else { self.launchRun() }
            }
            retryDelay = min(300, retryDelay * 2)
        } else if !needsRetry { retryDelay = 5 }
        running = false
        if pending && !stopped { pending = false; launchRun() }
    }
}
