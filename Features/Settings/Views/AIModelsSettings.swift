import AppKit
import AVFoundation
import SwiftUI

struct AIModelsSettings: View {
    @ObservedObject var models: AIModelStore
    @State private var editing: AIModelProfile?
    @State private var deleting: AIModelProfile?
    @State private var error = ""
    var body: some View {
        Group {
            Section(L10n.tr("模型配置")) {
                HStack {
                    Text(L10n.tr("按用途配置多个模型和独立密钥"))
                    Spacer()
                    Button(L10n.tr("新增模型"), systemImage: "plus") { editing = AIModelProfile() }
                }
                if let error = models.error { Text(error).foregroundStyle(.red) }
                if models.profiles.isEmpty { Text(L10n.tr("尚未添加模型。点击“新增模型”开始配置。")).foregroundStyle(.secondary) }
                ForEach(models.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name).fontWeight(.medium)
                            Text("\(profile.provider) · \(profile.model) · \(profile.capability.label)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.tr("编辑 / 测试")) { editing = profile }
                        Button(L10n.tr("删除"), role: .destructive) { deleting = profile }
                    }
                }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                Text(L10n.tr("使用 OpenAI 兼容协议，可分别配置通义千问、DeepSeek、OpenAI、本机服务或兼容网关。各服务支持的模型和能力以服务商为准；非兼容原生接口需通过兼容网关接入。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.tr("默认模型")) {
                ForEach(AICapability.allCases) { capability in
                    Picker(capability.label, selection: Binding<UUID?>(get: { models.selected(for: capability)?.id }, set: {
                        if let id = $0 { models.select(id, for: capability) }
                    })) {
                        Text(L10n.tr("未配置")).tag(Optional<UUID>.none)
                        ForEach(models.profiles(for: capability)) { profile in Text(profile.name).tag(Optional(profile.id)) }
                    }.disabled(models.profiles(for: capability).isEmpty)
                }
                Text(L10n.tr("从助手面板打开“多模态工具”，可进行图片理解、语音转写、图片生成和语音朗读。模型配置在工作空间之间共享。")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editing) { AIModelEditor(models: models, profile: $0) }
        .alert(L10n.tr("删除模型配置？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.tr("取消"), role: .cancel) { deleting = nil }
            Button(L10n.tr("删除"), role: .destructive) {
                if let deleting { do { try models.remove(deleting) } catch { self.error = error.localizedDescription } }
                deleting = nil
            }
        } message: { Text(L10n.tr("此配置及其钥匙串密钥将被移除，不影响其他模型配置。")) }
    }
}

private struct AIModelEditor: View {
    @ObservedObject var models: AIModelStore
    @Environment(\.dismiss) private var dismiss
    @State var profile: AIModelProfile
    @State private var key = ""
    @State private var keyLoaded = false
    @State private var status = ""
    @State private var testing = false
    @State private var operation: Task<Void, Never>?
    @State private var choosingImage = false
    @State private var testImage = ""
    @State private var resultImage = ""
    @State private var playback: AVAudioPlayer?
    @State private var testAudio: AIAudioFile?
    @State private var audioName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("模型配置")).font(.title2.bold())
            ScrollView {
                Form {
                    TextField(L10n.tr("配置名称"), text: $profile.name, prompt: Text(L10n.tr("例如：通义文字、视觉助手、语音转写")))
                    TextField(L10n.tr("服务商"), text: $profile.provider)
                    Picker(L10n.tr("用途"), selection: $profile.capability) {
                        ForEach(AICapability.allCases) { Text($0.label).tag($0) }
                    }
                    TextField(L10n.tr("接口 URL"), text: $profile.endpoint, prompt: Text(L10n.tr("https://服务地址/v1")))
                    TextField(L10n.tr("模型 ID"), text: $profile.model, prompt: Text(L10n.tr("服务商提供的模型名称")))
                    SecureField(L10n.tr("API 密钥"), text: $key)
                    if profile.capability == .speech {
                        TextField(L10n.tr("音色 ID"), text: $profile.voice, prompt: Text(L10n.tr("服务商支持的音色名称")))
                    }
                    Text(L10n.tr("基础地址支持 /v1 自动补全；自定义地址请填写完整路径：/\(profile.capability.path)。密钥仅保存在系统钥匙串。")).font(.caption).foregroundStyle(.secondary)
                }.disabled(testing)
                VStack(alignment: .leading, spacing: 10) {
                    if profile.capability == .vision {
                        Button(testImage.isEmpty ? L10n.tr("选择测试图片…") : L10n.tr("更换测试图片…")) { choosingImage = true }.disabled(testing)
                    }
                    if profile.capability == .transcription {
                        Button(audioName.isEmpty ? L10n.tr("选择测试音频…") : audioName) { chooseAudio() }.disabled(testing)
                    }
                    HStack {
                        Button(testing ? L10n.tr("测试中…") : testLabel) { test() }
                            .disabled(testing || !keyLoaded || (profile.capability == .vision && testImage.isEmpty) || (profile.capability == .transcription && testAudio == nil))
                        if testing { Button(L10n.tr("取消测试")) { operation?.cancel() } }
                    }
                    Text(L10n.tr("测试会向当前服务地址发送测试文字或你选中的图片/音频；生成类接口可能产生服务商费用。")).font(.caption).foregroundStyle(.secondary)
                    if !status.isEmpty { Text(status).font(.callout).textSelection(.enabled) }
                    if !resultImage.isEmpty { MediaImageView(source: resultImage).frame(height: 160) }
                }.padding(.top, 12)
            }
            HStack {
                Spacer()
                Button(L10n.tr("取消")) { operation?.cancel(); playback?.stop(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("保存配置")) { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(testing || !keyLoaded)
            }
        }.padding(24).frame(width: 610, height: 600)
        .task {
            do { key = try SecretStore.read(profile.keyAccount); keyLoaded = true }
            catch { status = error.localizedDescription }
        }
        .sheet(isPresented: $choosingImage) { ImageSourcePicker { testImage = $0 } }
        .onChange(of: profile.capability) { _, _ in status = ""; resultImage = ""; playback?.stop() }
        .onDisappear { operation?.cancel(); playback?.stop() }
        .interactiveDismissDisabled(testing)
    }
    private var testLabel: String {
        switch profile.capability {
        case .chat: L10n.tr("测试连接")
        case .vision: L10n.tr("测试图片理解")
        case .transcription: L10n.tr("测试音频转写")
        case .imageGeneration: L10n.tr("生成测试图片")
        case .speech: L10n.tr("生成并播放测试语音")
        }
    }
    private func save() {
        do {
            let validated = try models.validate(profile)
            try SecretStore.save(key, account: validated.keyAccount)
            try models.upsert(validated)
            dismiss()
        } catch { status = error.localizedDescription }
    }
    private func chooseAudio() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio, .movie]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { testAudio = try AIAudioFile.load(url); audioName = url.lastPathComponent; status = "" }
        catch { status = error.localizedDescription }
    }
    private func test() {
        testing = true; status = L10n.tr("正在发送测试请求…"); resultImage = ""; playback?.stop()
        let snapshot = profile; let secret = key
        operation = Task {
            defer { testing = false }
            do {
                let validated = try models.validate(snapshot)
                let client = AIClient(readKey: { _ in secret })
                switch validated.capability {
                case .chat, .vision:
                    let reply = try await client.chat(profile: validated, messages: [AIClient.userMessage(validated.capability == .chat ? "Reply OK." : L10n.tr("请简要描述图片内容。"), image: validated.capability == .vision ? testImage : nil)])
                    try Task.checkCancellation(); status = L10n.tr("连接成功\n模型回复：") + reply
                case .transcription:
                    guard let audio = testAudio else { throw AppError.message(L10n.tr("请先选择音频")) }
                    let reply = try await client.transcribe(profile: validated, audio: audio)
                    try Task.checkCancellation(); status = L10n.tr("转写成功\n") + reply
                case .imageGeneration:
                    let image = try await client.generateImage(profile: validated, prompt: "A small green leaf on a white background.")
                    try Task.checkCancellation(); resultImage = image; status = L10n.tr("图片生成成功")
                case .speech:
                    let bytes = try await client.speech(profile: validated, text: L10n.tr("你好，这是 Velora 的语音朗读测试。"))
                    try Task.checkCancellation(); playback = try AVAudioPlayer(data: bytes)
                    guard playback?.play() == true else { throw AppError.message(L10n.tr("语音已返回，但无法播放此音频格式")) }
                    status = L10n.tr("连接成功，正在播放 AI 生成的测试语音")
                }
            } catch { status = Task.isCancelled ? L10n.tr("测试已取消") : L10n.tr("测试失败\n") + error.localizedDescription }
        }
    }
}
