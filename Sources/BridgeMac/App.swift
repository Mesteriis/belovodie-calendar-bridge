import SwiftUI
import AppKit
import BridgeMac

@MainActor final class BridgeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
@main struct BridgeApp: App {
    @NSApplicationDelegateAdaptor(BridgeAppDelegate.self) private var delegate
    @State private var model = BridgeModel()
    var body: some Scene {
        WindowGroup("Belovodie Calendar Bridge", id: "main") {
            CalendarSettingsView(model: model)
        }
        Settings { CalendarSettingsView(model: model) }
        MenuBarExtra("Calendar Bridge", systemImage: "calendar.badge.clock") {
            SettingsLink { Text("Настройки календарей") }
            Button("Рассчитать без записи") { model.dryRun() }
            Divider()
            Button("Завершить") { NSApp.terminate(nil) }
        }
    }
}
