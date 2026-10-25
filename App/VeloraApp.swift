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
                StartupRecoveryView(services: services)
            }
        }
        .defaultSize(width: 1100, height: 760)
        .commands { WorkspaceMenuCommands() }
        Settings { SettingsView(services: services)
            .environment(\.locale, (AppLanguage(rawValue: appLanguage) ?? .system).locale) }
    }
}

struct StartupRecoveryView: View {
    @ObservedObject var services: ApplicationServices
    @State private var error: String?

    var body: some View {
        ContentUnavailableView {
            Label(L10n.tr("无法打开 Velora"), systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            VStack(spacing: 12) {
                Text(error ?? services.startupError ?? L10n.tr("未知错误")).textSelection(.enabled)
                if services.catalog != nil {
                    Text(L10n.tr("文件已删除？可以创建空白工作空间继续书写，原工作空间记录会保留。"))
                        .foregroundStyle(.secondary)
                }
            }.frame(maxWidth: 600)
        } actions: {
            HStack {
                Button(L10n.tr("重新尝试")) { perform { try await services.retryStartup() } }
                if !services.availableStartupWorkspaces.isEmpty {
                    Menu(L10n.tr("打开其他工作空间")) {
                        ForEach(services.availableStartupWorkspaces) { workspace in
                            Button(workspace.name) { perform { try await services.retryStartup(opening: workspace.id) } }
                        }
                    }
                }
                if services.catalog != nil {
                    Button(L10n.tr("创建空白工作空间")) { perform { try await services.createStartupWorkspace() } }
                        .buttonStyle(.borderedProminent).disabled(!services.canCreateStartupWorkspace)
                }
                if services.busy { ProgressView().controlSize(.small) }
            }.fixedSize(horizontal: true, vertical: false).disabled(services.busy)
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        error = nil
        Task { do { try await action() } catch { self.error = error.localizedDescription } }
    }
}
