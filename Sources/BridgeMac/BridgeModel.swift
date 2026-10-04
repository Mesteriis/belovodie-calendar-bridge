import Foundation
import Observation
import BridgeCore
import EventKit
import AppKit

@Observable @MainActor public final class BridgeModel {
    /// Draft UI edits are never the configuration consumed by the background runner.
    public var settings: BridgeSettings?
    public private(set) var activeSettings: BridgeSettings?
    private var reviewedSettings: BridgeSettings?
    public var canApplySettings: Bool { reviewedSettings != nil && reviewedSettings == settings }
    public private(set) var targetCapabilities: [String: TargetCapability] = [:]
    public private(set) var inventory: [CalendarDescriptor] = []
    public private(set) var access: CalendarAccess = .notDetermined
    public private(set) var status = "Доступ ещё не проверен"
    public private(set) var lastSuccessfulRead: Date?
    public private(set) var dryRunSummary = "План ещё не рассчитан"
    public private(set) var reading = false
    public var onlySelected = false
    public private(set) var coordinator: SyncCoordinator?
    public private(set) var canEnableWrites = false
    public private(set) var writeReviewSummary = "План для включения записи ещё не проверен"
    private var eventObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private let settingsStore: SettingsStore
    private var adapter: EventKitAdapter?
    public init(directoryURL: URL? = nil, provider: (any CalendarProvider)? = nil) {
        let directory = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BelovodieCalendarBridge", isDirectory: true)
        settingsStore = SettingsStore(directoryURL: directory)
        do {
            let loaded = try settingsStore.load()
            settings = loaded
            activeSettings = loaded
            adapter = EventKitAdapter(provider: provider ?? NativeEventKitProvider(), installationID: loaded.installationID,
                receipts: try OwnershipReceiptStore(directoryURL: directory, installationID: loaded.installationID))
            let transport: any SnapshotTransport
            if let config = try? SSHConfiguration.load(directoryURL: directory) { transport = SSHTransport(configuration: config) } else { transport = UnconfiguredTransport() }
            coordinator = SyncCoordinator(adapter: adapter!, settings: loaded, directoryURL: directory, transport: transport)
            access = adapter!.access
            status = "Настройки загружены. Запись требует отдельного включения."
        } catch {
            settings = nil
            activeSettings = nil
            status = "Не удалось загрузить приватные настройки. Чтение заблокировано."
        }
    }
    public func startBackground() {
        guard let coordinator, eventObserver == nil else { return }
        eventObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak coordinator] _ in
            Task { @MainActor in coordinator?.requestSync(reason: .eventChanged) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak coordinator] _ in
            Task { @MainActor in coordinator?.requestSync(reason: .wake) }
        }
        coordinator.start()
    }
    public func stopBackground() {
        coordinator?.stop()
        if let eventObserver { NotificationCenter.default.removeObserver(eventObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        eventObserver = nil; wakeObserver = nil
    }
    public func syncNow() { coordinator?.requestSync(reason: .manual) }
    public func prepareWriteReview() {
        canEnableWrites = false
        guard settings == activeSettings, let coordinator else { status = "Примените проверенный черновик перед включением записи."; return }
        do {
            let plan = try coordinator.previewInitialPlan()
            writeReviewSummary = "Активный план: создать \(plan.creates.count), изменить \(plan.updates.count), удалить \(plan.deletes.count)."
            canEnableWrites = true
        } catch { writeReviewSummary = "Полное чтение активного плана не подтверждено. Запись не включена." }
    }
    public func enableWrites() {
        guard canEnableWrites, settings == activeSettings else { return }
        do { try coordinator?.enableReviewedWrites(); canEnableWrites = false }
        catch { canEnableWrites = false; writeReviewSummary = "План изменился. Повторите проверку перед включением записи." }
    }
    public func disableWrites() {
        canEnableWrites = false
        do { try coordinator?.disableWrites() }
        catch { status = "Запись выключена в этом процессе; не удалось сохранить отключение. Не перезапускайте до исправления приватного файла." }
    }
    public func requestAccess() async {
        guard let adapter, !reading else { return }
        reading = true
        defer { reading = false; access = adapter.access }
        do {
            let granted = try await adapter.requestAccess()
            status = granted ? "Полный доступ разрешён. Обновите список календарей." : "Полный доступ не разрешён. Пустой снимок не создан."
        } catch { status = "Запрос доступа не завершён. Проверьте разрешения macOS." }
    }
    public func refreshInventory() {
        guard let adapter, var settings, var activeSettings, !reading else { return }
        reading = true
        defer { reading = false; access = adapter.access }
        do {
            inventory = try adapter.inventory()
            targetCapabilities = adapter.targetCapabilities
            settings.discover(inventory)
            activeSettings.discover(inventory)
            try settingsStore.save(activeSettings)
            self.settings = settings
            self.activeSettings = activeSettings
            try coordinator?.updateSettings(activeSettings)
            reviewedSettings = nil
            status = "Локальный список прочитан. Выберите нужные флажки."
        } catch { status = "Не удалось прочитать список. Сохранённый выбор сохранён." }
        dryRunSummary = "Настройки изменились. Рассчитайте план заново."
    }
    public func invalidatePreview() {
        reviewedSettings = nil
        disableWrites()
        dryRunSummary = "Настройки изменились. Рассчитайте план заново."
    }
    public func applyReviewedSettings() {
        guard let settings, canApplySettings else {
            status = "Сначала рассчитайте план для текущих настроек."
            return
        }
        do {
            disableWrites()
            try settingsStore.save(settings)
            try coordinator?.updateSettings(settings)
            activeSettings = settings
            status = "Проверенные настройки применены. Автоматическая запись выключена."
        } catch { status = "Не удалось сохранить настройки. Активные настройки сохранены без изменений." }
    }
    public func dryRun() {
        guard let adapter, let settings, !reading else { return }
        reading = true
        reviewedSettings = nil
        defer { reading = false; access = adapter.access }
        do {
            let today = Calendar.current.startOfDay(for: Date())
            guard let start = Calendar.current.date(byAdding: .day, value: -settings.lookbackDays, to: today),
                  let end = Calendar.current.date(byAdding: .day, value: settings.lookaheadDays, to: today) else { throw EventKitAdapterError.incompleteRead }
            let window = QueryWindow(start: start, end: end)
            // Disabled saved policies still participate in reviewed cleanup safety; no inventory entry
            // enables a flag or silently erases a missing selected policy.
            let reads = try settings.policies.filter { adapter.requiresRead($0) }.map { try adapter.read(policy: $0, window: window) }
            inventory = inventory.filter { descriptor in !reads.contains { $0.descriptor.identity == descriptor.identity } } + reads.map(\.descriptor)
            targetCapabilities = adapter.targetCapabilities
            let plan = try BusyPlanner(installationID: settings.installationID).plan(events: reads.flatMap(\.events),
                policies: settings.policies, existing: reads.flatMap(\.blocks), window: window,
                completeSources: Set(reads.filter(\.complete).map { $0.descriptor.identity }))
            let selected = Set(settings.policies.filter { $0.exportToHA || $0.busySource || $0.busyTarget }.map(\.identity))
            let complete = reads.filter { $0.complete && selected.contains($0.descriptor.identity) }.count
            let total = selected.count
            dryRunSummary = "Создать: \(plan.creates.count) · Изменить: \(plan.updates.count) · Удалить: \(plan.deletes.count)\nВыбранные локальные чтения: \(complete)/\(total). Удаления \(plan.cleanupSuppressed ? "приостановлены" : "разрешены в плане")."
            reviewedSettings = complete == total ? settings : nil
            status = "План без записи рассчитан. События не изменены."
            if total > 0 && complete == total { lastSuccessfulRead = Date() }
            // Never authorize/apply a plan in this foreground stage.
        } catch {
            dryRunSummary = "План недоступен. Неполное чтение не заменяет события пустым снимком."
            status = "Не удалось рассчитать план. Запись остаётся выключена."
        }
    }
    public func targetLimitation(_ policy: CalendarPolicy) -> String? {
        switch targetCapabilities[policy.identity] {
        case .readOnly: "Только чтение"
        case .busyUnsupported: "Busy не поддерживается"
        default: nil
        }
    }
    public func localHealth(_ policy: CalendarPolicy) -> String {
        guard access == .fullAccess else { return "Нет полного доступа" }
        switch inventory.first(where: { $0.identity == policy.identity })?.localRead {
        case .complete: return "Локально прочитан"
        case .failed: return "Чтение не подтверждено"
        default: return "Отсутствует локально"
        }
    }
}
