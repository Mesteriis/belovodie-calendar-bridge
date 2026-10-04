import Foundation
import Observation
import BridgeCore

@Observable @MainActor public final class BridgeModel {
    /// Draft UI edits are never the configuration consumed by a future background runner.
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
            access = adapter!.access
            status = "Настройки загружены. Чтение запускается вручную."
        } catch {
            settings = nil
            activeSettings = nil
            status = "Не удалось загрузить приватные настройки. Чтение заблокировано."
        }
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
            reviewedSettings = nil
            status = "Локальный список прочитан. Выберите нужные флажки."
        } catch { status = "Не удалось прочитать список. Сохранённый выбор сохранён." }
        dryRunSummary = "Настройки изменились. Рассчитайте план заново."
    }
    public func invalidatePreview() {
        reviewedSettings = nil
        dryRunSummary = "Настройки изменились. Рассчитайте план заново."
    }
    public func applyReviewedSettings() {
        guard let settings, canApplySettings else {
            status = "Сначала рассчитайте план для текущих настроек."
            return
        }
        do {
            try settingsStore.save(settings)
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
