import AppKit
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance = "外观与编辑", storage = "存储与备份", ai = "AI 助手", mcp = "MCP 连接", voice = "语音操作", about = "关于"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .appearance: "paintpalette"
        case .storage: "externaldrive"
        case .ai: "sparkles"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .voice: "mic"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var services: ApplicationServices
    @State private var section: SettingsSection = .appearance
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accentColor") private var accent = "indigo"
    @AppStorage("editorFontSize") private var editorFontSize = 17.0
    @AppStorage("codeFontSize") private var codeFontSize = 13.0
    @AppStorage("codeLineNumbers") private var codeLineNumbers = true
    @AppStorage("codeLineCount") private var codeLineCount = true
    @AppStorage("automaticBackup") private var automaticBackup = false
    @AppStorage("aiEnabled") private var aiEnabled = false
    @AppStorage("aiShareContent") private var shareContent = false
    @AppStorage("mcpEnabled") private var mcpEnabled = false
    @AppStorage("mcpAllowWrites") private var mcpAllowWrites = false
    @AppStorage("mcpPort") private var mcpPort = 18427
    @AppStorage("voiceEnabled") private var voiceEnabled = false
    @AppStorage("voiceLocale") private var voiceLocale = "zh-CN"
    @AppStorage("voiceOnDevice") private var voiceOnDevice = true
    @State private var showingWorkspaces = false

    private var scheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.tr("Velora 设置")).font(.headline).padding(.horizontal, 20).padding(.top, 24)
                List(SettingsSection.allCases, selection: $section) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white).frame(width: 26, height: 26)
                            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 7))
                        Text(L10n.text(item.rawValue)).font(.system(size: 13, weight: .medium))
                    }.tag(item).padding(.vertical, 3)
                }.listStyle(.sidebar)
            }.frame(width: 220).background(.bar)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: section.symbol).font(.title2).foregroundStyle(Color.accentColor)
                    Text(L10n.text(section.rawValue)).font(.system(size: 24, weight: .semibold))
                    Spacer()
                }.padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 8)
                Form {
                    switch section {
                    case .appearance: appearanceSettings
                    case .storage: storageSettings
                    case .ai: aiSettings
                    case .mcp: mcpSettings
                    case .voice: voiceSettings
                    case .about: aboutSettings
                    }
                }.formStyle(.grouped).id(appLanguage)
                    .toggleStyle(.switch).controlSize(.regular)
                if !services.status.isEmpty {
                    Text(services.status).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).padding(.horizontal, 24).padding(.bottom, 14)
                }
            }
        }
        .frame(minWidth: 880, idealWidth: 920, minHeight: 620, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent == "blue" ? .blue : accent == "green" ? .green : accent == "orange" ? .orange : .indigo)
        .preferredColorScheme(scheme)
        .sheet(isPresented: $showingWorkspaces) { WorkspaceManagerView(services: services) }

    }

    private var appearanceSettings: some View {
        Group {
            Section(L10n.tr("语言")) {
                Picker(L10n.tr("界面语言"), selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text(L10n.tr("语言切换即时生效，不会更改文档内容。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.tr("主题")) {
                Picker(L10n.tr("外观"), selection: $appearance) {
                    Text(L10n.tr("跟随系统")).tag("system")
                    Text(L10n.tr("浅色")).tag("light")
                    Text(L10n.tr("深色")).tag("dark")
                }.pickerStyle(.segmented)
                Picker(L10n.tr("强调色"), selection: $accent) {
                    Text(L10n.tr("鸢尾紫")).tag("indigo"); Text(L10n.tr("海洋蓝")).tag("blue")
                    Text(L10n.tr("森林绿")).tag("green"); Text(L10n.tr("暖橙")).tag("orange")
                }
            }
            Section(L10n.tr("编辑器")) {
                Slider(value: $editorFontSize, in: 14...22, step: 1) { Text(L10n.tr("正文字号 · \(Int(editorFontSize)) pt")) }
                Slider(value: $codeFontSize, in: 11...18, step: 1) { Text(L10n.tr("代码字号 · \(Int(codeFontSize)) pt")) }
                Toggle(L10n.tr("显示代码行号"), isOn: $codeLineNumbers)
                Toggle(L10n.tr("显示代码行数"), isOn: $codeLineCount)
                Text(L10n.tr("更改即时生效；内容在输入后自动保存。")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var storageSettings: some View {
        Group {
            Section(L10n.tr("工作空间")) {
                LabeledContent(L10n.tr("当前空间"), value: services.currentWorkspace?.name ?? L10n.tr("未加载"))
                if let workspace = services.currentWorkspace, !workspace.summary.isEmpty {
                    Text(workspace.summary).font(.caption).foregroundStyle(.secondary)
                }
                Button(L10n.tr("管理工作空间…")) { showingWorkspaces = true }.disabled(services.busy)
            }
            Section(L10n.tr("当前工作空间存储")) {
                pathRow(services.storagePath)
                HStack {
                    Button(L10n.tr("更改位置…")) { services.chooseStorage() }.disabled(services.busy)
                    Button(L10n.tr("在 Finder 中显示")) { reveal(services.storagePath) }
                }
                Text(L10n.tr("切换时迁移完整数据库并立即生效，保留原位置副本；不会覆盖目标位置已有数据库。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.tr("备份")) {
                pathRow(services.backupPath)
                HStack {
                    Button(L10n.tr("更改位置…")) { services.chooseBackup() }.disabled(services.busy)
                    Button(L10n.tr("打开备份文件夹")) { reveal(services.backupPath) }
                    Spacer()
                    Button { Task { await services.backup() } } label: {
                        if services.busy { ProgressView().controlSize(.small) }
                        else { Text(L10n.tr("立即备份")) }
                    }.disabled(services.busy).buttonStyle(.borderedProminent)
                }
                Button(L10n.tr("从 ZIP 备份恢复…")) { services.chooseRestore() }.disabled(services.busy)
                Text(L10n.tr("恢复会创建并切换到新工作空间，现有工作空间不会被覆盖。")).font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.tr("应用运行时每天自动备份"), isOn: $automaticBackup)
                if let last = UserDefaults.standard.object(forKey: services.lastBackupKey) as? Date {
                    LabeledContent(L10n.tr("上次备份"), value: last.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.language.locale)))
                }
                Text(L10n.tr("ZIP 压缩备份包含当前工作空间信息、页面、块、回收箱及内嵌图片和 PDF。不包含外部链接文件、应用设置或钥匙串密钥；上限 512 MB，不自动删除历史备份。")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var aiSettings: some View {
        Group {
            Section(L10n.tr("AI 功能")) {
                Toggle(L10n.tr("启用 AI 助手"), isOn: $aiEnabled)
            }
            AIModelsSettings(models: services.aiModels)
            Section(L10n.tr("应用操作")) {
                Toggle(L10n.tr("将当前页面正文加入 AI 上下文"), isOn: $shareContent)
                Text(L10n.tr("默认仅发送当前指令、页面标题和层级。正文共享开启后，额外发送当前页最多 30,000 字符。模型先生成预览，你确认后才修改页面。")).font(.caption).foregroundStyle(.secondary)
                Text(L10n.tr("支持新建、打开、重命名、移动、移入回收箱、恢复和追加正文；不向模型开放永久删除。")).font(.caption).foregroundStyle(.secondary)
                Text(L10n.tr("从主窗口工具栏打开助手，快捷键 ⌘J。")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var mcpSettings: some View {
        Group {
            Section(L10n.tr("本机 MCP 服务")) {
                Toggle(L10n.tr("允许 MCP 客户端连接 Velora"), isOn: $mcpEnabled)
                    .onChange(of: mcpEnabled) { _, _ in services.configureMCP() }
                TextField(L10n.tr("监听端口"), value: $mcpPort, format: .number.grouping(.never))
                    .onSubmit { services.configureMCP() }
                HStack {
                    Text(services.mcpStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("应用端口")) { services.configureMCP() }
                }
                Toggle(L10n.tr("允许外部客户端修改页面"), isOn: $mcpAllowWrites).disabled(!mcpEnabled)
                Text(L10n.tr("默认只读。开启修改后，持有令牌的客户端可新建、重命名、移动、追加正文和移入回收箱；不提供永久删除。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.tr("客户端接入")) {
                Text("http://127.0.0.1:\(mcpPort)/mcp").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button(L10n.tr("复制连接配置")) { services.copyMCPConfig() }
                    Button(L10n.tr("更新访问令牌")) { services.rotateMCPToken() }
                }
                Text(L10n.tr("使用 Streamable HTTP 和 Bearer 令牌，仅监听本机。将连接配置导入支持 HTTP MCP 的客户端；客户端的具体配置字段可能不同。启用或更改读写权限后，请在客户端重新连接。")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var voiceSettings: some View {
        Group {
            Section(L10n.tr("语音指令")) {
                Toggle(L10n.tr("启用语音操作"), isOn: $voiceEnabled)
                Picker(L10n.tr("识别语言"), selection: $voiceLocale) {
                    Text(L10n.tr("简体中文")).tag("zh-CN"); Text("English (US)").tag("en-US")
                    Text(L10n.tr("繁體中文")).tag("zh-TW"); Text(L10n.tr("日本語")).tag("ja-JP")
                }
                Toggle(L10n.tr("仅在设备上识别"), isOn: $voiceOnDevice)
                Text(L10n.tr("在助手面板点击麦克风开始，最长约 55 秒，点击结束后可编辑文字。语音不会直接执行操作，也不会在后台持续录音。")).font(.caption).foregroundStyle(.secondary)
                Text(L10n.tr("首次使用请求麦克风与语音识别权限。离线能力取决于系统和语言；关闭仅设备识别后，Apple 可能通过联网服务处理音频。")).font(.caption).foregroundStyle(.secondary)
                Button(L10n.tr("打开系统隐私设置")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
                }
            }
            Section(L10n.tr("无需 AI 的本地指令")) {
                Text(L10n.tr("新建页面 会议记录\n打开 项目计划\n移出当前页面\n立即备份\n切换深色主题\n切换浅色主题"))
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text(L10n.tr("更灵活的自然语言操作需要在 AI 设置中配置模型。")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var aboutSettings: some View {
        Section("Velora") {
            LabeledContent(L10n.tr("版本"), value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
            Text(L10n.tr("本地优先的原生知识工作台")).foregroundStyle(.secondary)
            Text(L10n.tr("页面和内容存储在本机。AI 和语音联网能力由你的设置决定。MCP 服务关闭时不开放端口。")).font(.caption).foregroundStyle(.secondary)
            Link(L10n.tr("MCP 协议文档"), destination: URL(string: "https://modelcontextprotocol.io/specification/2025-11-25/basic/transports")!)
        }
    }

    private func pathRow(_ path: String) -> some View {
        Text(path.isEmpty ? L10n.tr("正在读取…") : path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
    }
    private func reveal(_ path: String) {
        guard !path.isEmpty else { return }
        do {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch { services.status = error.localizedDescription }
    }
}

struct AssistantPanel: View {
    @ObservedObject var services: ApplicationServices
    @ObservedObject private var models: AIModelStore
    @State private var showingMultimodal = false

    init(services: ApplicationServices) {
        self.services = services
        self.models = services.aiModels
    }
    @StateObject private var voice = VoiceInput()
    @Environment(\.dismiss) private var dismiss
    @AppStorage("voiceEnabled") private var voiceEnabled = false
    @State private var input = ""
    @State private var plan: AssistantPlan?
    @State private var working = false
    @State private var status = ""
    @State private var operation: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(L10n.tr("Velora 助手"), systemImage: "sparkles").font(.title3.bold())
                Spacer()
                Button(L10n.tr("关闭")) { operation?.cancel(); voice.stop(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker(L10n.tr("操作模型"), selection: Binding<UUID?>(get: { models.selected(for: .chat)?.id }, set: {
                    if let id = $0 { models.select(id, for: .chat) }
                })) {
                    Text(L10n.tr("本地指令 / 未配置")).tag(Optional<UUID>.none)
                    ForEach(models.profiles(for: .chat)) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(working)
                Button(L10n.tr("多模态工具…"), systemImage: "photo.on.rectangle.angled") { showingMultimodal = true }.disabled(working)
            }
            Text(L10n.tr("输入或说出指令，先预览，再执行。")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $input).font(.system(size: 15)).frame(height: 110)
                .padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .disabled(working || voice.recording)
                .onChange(of: input) { _, _ in plan = nil }
            HStack {
                if voiceEnabled {
                    Button {
                        if voice.recording { voice.finish() }
                        else { Task { await voice.start() } }
                    } label: { Label(voice.recording ? L10n.tr("结束录音") : L10n.tr("语音输入"), systemImage: voice.recording ? "stop.circle.fill" : "mic") }
                        .disabled(working || voice.starting)
                }
                Spacer()
                Button(working ? L10n.tr("处理中…") : L10n.tr("生成操作预览")) { generate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || voice.recording || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !voice.status.isEmpty { Text(voice.status).font(.caption).foregroundStyle(.secondary) }
            if let plan {
                Divider()
                Text(plan.message).font(.callout).textSelection(.enabled)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(plan.actions.enumerated()), id: \.offset) { index, action in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(index + 1). \(action.summary)").fontWeight(.medium)
                                ForEach(action.arguments.keys.sorted(), id: \.self) { key in
                                    Text("\(argumentLabel(key)): \(argumentValue(key, action.arguments[key] ?? ""))")
                                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(maxHeight: 210)
                if !plan.actions.isEmpty {
                    HStack {
                        Text(L10n.tr("执行前请核对目标页面和内容")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.tr("执行以上操作")) { execute(plan) }.buttonStyle(.borderedProminent).disabled(working)
                    }
                }
            }
            if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            Spacer(minLength: 0)
            Text(L10n.tr("可直接试试：新建页面 会议记录、移出当前页面、立即备份。⌘J 打开助手。"))
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24).frame(width: 650, height: 620)
        .onChange(of: voice.transcript) { _, value in if !working { input = value } }
        .onDisappear { voice.stop(); operation?.cancel() }
        .onChange(of: services.currentWorkspace?.id) { _, _ in
            operation?.cancel(); voice.stop(); plan = nil; status = L10n.tr("工作空间已切换，请重新生成操作预览。")
        }
        .sheet(isPresented: $showingMultimodal) { MultimodalPanel(services: services) }
        .onChange(of: models.configuration.defaults) { _, _ in plan = nil }
        .onChange(of: models.profiles) { _, _ in plan = nil }
        .interactiveDismissDisabled(working)
    }

    private func argumentLabel(_ key: String) -> String {
        ["page_id": L10n.tr("页面"), "parent_id": L10n.tr("目标位置"), "title": L10n.tr("标题"), "text": L10n.tr("正文"), "theme": L10n.tr("主题")][key] ?? key
    }

    private func argumentValue(_ key: String, _ value: String) -> String {
        if key == "page_id" || key == "parent_id" {
            if key == "parent_id" && value.isEmpty { return L10n.tr("工作区顶层") }
            if let page = services.model?.pages.first(where: { $0.id.uuidString == value }) {
                return page.title.isEmpty ? L10n.tr("未命名") : page.title
            }
            return L10n.tr("目标页面已不存在")
        }
        if key == "theme" { return ["dark": L10n.tr("深色"), "light": L10n.tr("浅色"), "system": L10n.tr("跟随系统")][value] ?? value }
        return value
    }

    private func generate() {
        guard let model = services.model else { return }
        working = true; status = ""; plan = nil
        operation = Task {
            defer { working = false }
            do {
                await model.refreshPages()
                let result = try await AssistantService.plan(input, model: model, profile: models.selected(for: .chat))
                try Task.checkCancellation()
                plan = result
            } catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }

    private func execute(_ plan: AssistantPlan) {
        guard let model = services.model else { return }
        working = true; self.plan = nil
        operation = Task {
            defer { working = false }
            var completed = 0
            do {
                for action in plan.actions {
                    try Task.checkCancellation()
                    switch action.name {
                    case "backup":
                        await services.backup()
                        status = services.status
                    case "set_theme":
                        guard let theme = action.arguments["theme"], ["light", "dark", "system"].contains(theme) else { throw AppError.message(L10n.tr("无效主题")) }
                        UserDefaults.standard.set(theme, forKey: "appearance")
                    default: _ = try await model.executeTool(action.name, arguments: action.arguments)
                    }
                    completed += 1
                }
                if status.isEmpty { status = L10n.tr("已完成 \(completed) 项操作") }
            } catch { status = L10n.tr("已完成 \(completed) 项，后续操作停止：\(error.localizedDescription)") }
        }
    }
}
