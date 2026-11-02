import SwiftUI

@main
@MainActor
struct VeloraApp: App {
    @NSApplicationDelegateAdaptor(VeloraApplicationDelegate.self) private var applicationDelegate
    @AppStorage("appLanguage") private var appLanguage = "system"
    @StateObject private var services = ApplicationServices()

    var body: some Scene {
        WindowGroup(id: "workspace") {
            Group {
            if let model = services.model {
                WorkspaceView(services: services, model: model)
                    .environment(\.locale, (AppLanguage(rawValue: appLanguage) ?? .system).locale)
                    .id("\(ObjectIdentifier(model))-\(appLanguage)")
                    .disabled(services.busy)
            } else {
                StartupRecoveryView(services: services)
            }
            }
            .modifier(WorkspaceWindowActivation(delegate: applicationDelegate))
        }
        .defaultSize(width: 1100, height: 760)
        .commands { WorkspaceMenuCommands() }
        Settings { SettingsView(services: services)
            .environment(\.locale, (AppLanguage(rawValue: appLanguage) ?? .system).locale) }
    }
}

/// Dock reopen is explicit: SwiftUI's default scene handling alone does not
/// reliably raise an existing workspace after utility panels have been used.
@MainActor
final class VeloraApplicationDelegate: NSObject, NSApplicationDelegate {
    private(set) weak var workspaceWindow: NSWindow?
    var openWorkspaceWindow: (() -> Void)?
    private(set) var reopening = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }

    func registerWorkspaceWindow(_ window: NSWindow) {
        workspaceWindow = window
        reopening = false
    }

    @objc private func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === workspaceWindow { workspaceWindow = nil }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = workspaceWindow {
            present(window, in: sender)
            return false
        }
        guard let openWorkspaceWindow else { return true }
        guard !reopening else { return false }
        reopening = true
        sender.activate()
        openWorkspaceWindow()
        return false
    }

    private func present(_ window: NSWindow, in app: NSApplication) {
        app.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.attachedSheet?.makeKeyAndOrderFront(nil)
        app.activate()
    }
}

private struct WorkspaceWindowActivation: ViewModifier {
    let delegate: VeloraApplicationDelegate
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.background(WorkspaceWindowRegistration(delegate: delegate))
            .onAppear { delegate.openWorkspaceWindow = { openWindow(id: "workspace") } }
    }
}

private struct WorkspaceWindowRegistration: NSViewRepresentable {
    let delegate: VeloraApplicationDelegate
    func makeNSView(context: Context) -> WorkspaceWindowRegistrationView {
        let view = WorkspaceWindowRegistrationView()
        view.applicationDelegate = delegate
        return view
    }
    func updateNSView(_ view: WorkspaceWindowRegistrationView, context: Context) {
        view.applicationDelegate = delegate
        if let window = view.window { delegate.registerWorkspaceWindow(window) }
    }
}

private final class WorkspaceWindowRegistrationView: NSView {
    weak var applicationDelegate: VeloraApplicationDelegate?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { applicationDelegate?.registerWorkspaceWindow(window) }
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
