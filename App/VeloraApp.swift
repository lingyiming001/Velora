import SwiftUI

@main
@MainActor
struct VeloraApp: App {
    @AppStorage("appLanguage") private var appLanguage = "system"
    @StateObject private var services = ApplicationServices()

    var body: some Scene {
        WindowGroup {
            if let model = services.model {
                WorkspaceView(services: services, model: model)
                    .environment(\.locale, (AppLanguage(rawValue: appLanguage) ?? .system).locale)
                    .id("\(ObjectIdentifier(model))-\(appLanguage)")
                    .disabled(services.busy)
            } else {
                ContentUnavailableView(L10n.text("无法打开 Velora"), systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text(services.startupError ?? L10n.text("未知错误")))
                    .frame(minWidth: 700, minHeight: 500)
            }
        }
        .defaultSize(width: 1100, height: 760)
        .commands { WorkspaceMenuCommands() }
        Settings { SettingsView(services: services)
            .environment(\.locale, (AppLanguage(rawValue: appLanguage) ?? .system).locale) }
    }
}
