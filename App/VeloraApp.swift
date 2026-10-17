import SwiftUI

@main
@MainActor
struct VeloraApp: App {
    @StateObject private var services = ApplicationServices()

    var body: some Scene {
        WindowGroup {
            if let model = services.model {
                WorkspaceView(services: services, model: model)
                    .id(ObjectIdentifier(model))
                    .disabled(services.busy)
            } else {
                ContentUnavailableView("无法打开 Velora", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text(services.startupError ?? "未知错误"))
                    .frame(minWidth: 700, minHeight: 500)
            }
        }
        .defaultSize(width: 1100, height: 760)
        Settings { SettingsView(services: services) }
    }
}
