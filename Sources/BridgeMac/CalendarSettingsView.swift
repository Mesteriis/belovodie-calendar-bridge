import SwiftUI
import BridgeCore

public struct CalendarSettingsView: View {
    @Bindable var model: BridgeModel
    public init(model: BridgeModel) { self.model = model }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Календари Belovodie").font(.title2)
            HStack {
                Button("Разрешить доступ") { Task { await model.requestAccess() } }
                Button("Обновить список") { model.refreshInventory() }
                Spacer()
                Toggle("Только выбранные", isOn: $model.onlySelected)
                    .toggleStyle(.checkbox)
            }.disabled(model.reading || model.settings == nil)
            Text("Доступ macOS: \(accessLabel) · Состояние облака: неизвестно").font(.callout)
            Text("EventKit подтверждает локальное чтение. Подключение Google/iCloud проверяется в системном Календаре.")
                .font(.caption).foregroundStyle(.secondary)
            if let settings = model.settings {
                calendarTable(settings)
                HStack(spacing: 20) {
                    Stepper("Назад: \(settings.lookbackDays) дней", value: setting(\.lookbackDays), in: 0...365)
                    Stepper("Вперёд: \(settings.lookaheadDays) дней", value: setting(\.lookaheadDays), in: 1...365)
                }
                Text("Отображение за пределами этого окна требует нового чтения.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Применить настройки") { model.applyReviewedSettings() }.disabled(!model.canApplySettings)
                Button("Рассчитать без записи") { model.dryRun() }.keyboardShortcut("r", modifiers: [.command])
            }.disabled(model.reading || model.settings == nil)
            Text(model.dryRunSummary).monospacedDigit().textSelection(.enabled)
            Text(model.status).foregroundStyle(.secondary)
            if let date = model.lastSuccessfulRead {
                Text("Последнее полное локальное чтение: \(date.formatted(date: .numeric, time: .standard))").font(.caption)
            }
            Text("Автоматическая запись выключена. План показывает только количества.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 1000, minHeight: 520)
    }
    private var accessLabel: String {
        switch model.access {
        case .fullAccess: "полный"
        case .notDetermined: "ещё не запрошен"
        case .denied: "отказано"
        case .restricted: "ограничен"
        case .writeOnly: "только запись — чтение недоступно"
        }
    }
    private func setting(_ key: WritableKeyPath<BridgeSettings, Int>) -> Binding<Int> {
        Binding(get: { model.settings?[keyPath: key] ?? 0 }, set: { model.settings?[keyPath: key] = $0; model.invalidatePreview() })
    }
    private func calendarTable(_ settings: BridgeSettings) -> some View {
        Table(settings.policies.filter { !model.onlySelected || $0.exportToHA || $0.busySource || $0.busyTarget }) {
            TableColumn("Календарь / аккаунт") { policy in
                VStack(alignment: .leading) {
                    Text(model.inventory.first(where: { $0.identity == policy.identity })?.name ?? policy.label)
                    Text(model.inventory.first(where: { $0.identity == policy.identity })?.owner ?? policy.owner).font(.caption).foregroundStyle(.secondary)
                }
            }.width(min: 180, ideal: 210)
            TableColumn("Владелец") { policy in TextField("Владелец", text: binding(policy, \.owner)).accessibilityLabel("Владелец \(policy.label)") }.width(min: 90, ideal: 110)
            TableColumn("Подпись") { policy in TextField("Подпись", text: binding(policy, \.label)).accessibilityLabel("Подпись \(policy.label)") }.width(min: 120, ideal: 150)
            TableColumn("В HA") { policy in Toggle("В HA", isOn: binding(policy, \.exportToHA)).labelsHidden().accessibilityLabel("Передавать \(policy.label) в HA") }.width(55)
            TableColumn("Занятость") { policy in Toggle("Занятость", isOn: binding(policy, \.busySource)).labelsHidden().accessibilityLabel("Учитывать занятость \(policy.label)") }.width(80)
            TableColumn("Блоки") { policy in Toggle("Блоки", isOn: binding(policy, \.busyTarget)).labelsHidden().accessibilityLabel("Получать блоки \(policy.label)") }.width(65)
            TableColumn("Локальное состояние") { policy in
                VStack(alignment: .leading) {
                    Text(model.localHealth(policy))
                    if let limitation = model.targetLimitation(policy) { Text(limitation).foregroundStyle(.secondary) }
                }.font(.caption)
            }.width(min: 140, ideal: 160)
        }.toggleStyle(.checkbox)
    }
    private func binding<Value>(_ policy: CalendarPolicy, _ key: WritableKeyPath<CalendarPolicy, Value>) -> Binding<Value> {
        Binding(get: { model.settings?.policies.first(where: { $0.identity == policy.identity })?[keyPath: key] ?? policy[keyPath: key] },
                set: { value in
                    guard let index = model.settings?.policies.firstIndex(where: { $0.identity == policy.identity }) else { return }
                    model.settings?.policies[index][keyPath: key] = value
                    model.invalidatePreview()
                })
    }
}
// UI identity is the persisted provider/source pair, never the editable title.
extension CalendarPolicy: Identifiable { public var id: String { identity } }
