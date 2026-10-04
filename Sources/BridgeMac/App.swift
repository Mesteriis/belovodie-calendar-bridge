import SwiftUI
import AppKit
import BridgeMac

@MainActor final class BridgeAppDelegate: NSObject, NSApplicationDelegate {
    private var settingsObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let background = CommandLine.arguments.contains("--background")
        NSApp.setActivationPolicy(background ? .accessory : .regular)
        if background { NSApp.hide(nil) } else { NSApp.activate(ignoringOtherApps: true) }
        settingsObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.belovodie.calendar-bridge.show-settings"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeMain { window.makeKeyAndOrderFront(nil) }
            }
        }
    }
}
@main struct BridgeApp: App {
    @NSApplicationDelegateAdaptor(BridgeAppDelegate.self) private var delegate
    private let ownership: ProcessOwnership
    @State private var model: BridgeModel
    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BelovodieCalendarBridge", isDirectory: true)
        do { ownership = try ProcessOwnership(directoryURL: directory) }
        catch ProcessOwnershipError.alreadyRunning {
            // Bring the existing owner's editable settings forward; never construct a second provider.
            if !CommandLine.arguments.contains("--background") {
                DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.belovodie.calendar-bridge.show-settings"), object: nil, userInfo: nil, deliverImmediately: true)
            }
            exit(0)
        } catch { exit(1) }
        _model = State(initialValue: BridgeModel(directoryURL: directory))
    }
    var body: some Scene {
        WindowGroup("Belovodie Calendar Bridge", id: "main") {
            CalendarSettingsView(model: model).task { model.startBackground() }
        }
        Settings { CalendarSettingsView(model: model) }
        MenuBarExtra("Calendar Bridge", systemImage: "calendar.badge.clock") {
            SettingsLink { Text("Настройки календарей") }
            Text(model.coordinator?.status ?? "Фоновый режим недоступен")
            Button("Передать снимок в HA сейчас") { model.syncNow() }
            Button("Рассчитать без записи") { model.dryRun() }
            Divider()
            Button("Завершить") { model.stopBackground(); NSApp.terminate(nil) }
        }
    }
}
