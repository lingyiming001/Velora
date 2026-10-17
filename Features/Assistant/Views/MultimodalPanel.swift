import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct MultimodalPanel: View {
    @ObservedObject var services: ApplicationServices
    @ObservedObject private var models: AIModelStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @AppStorage("aiEnabled") private var enabled = false
    @State private var capability: AICapability = .chat
    @State private var prompt = ""
    @State private var image = ""
    @State private var choosingImage = false
    @State private var audio: AIAudioFile?
    @State private var audioName = ""
    @State private var reply = ""
    @State private var generatedImage = ""
    @State private var speechData: Data?
    @State private var playback: AVAudioPlayer?
    @State private var status = ""
    @State private var working = false
    @State private var inserting = false
    @State private var operation: Task<Void, Never>?
    @State private var requestID: UUID?

    init(services: ApplicationServices) { self.services = services; self.models = services.aiModels }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("多模态工具", systemImage: "sparkles").font(.title2.bold())
                Spacer()
                Button("配置模型…") { openSettings() }
                Button("关闭") { cancel(); dismiss() }.keyboardShortcut(.cancelAction).disabled(inserting)
            }
            Picker("用途", selection: $capability) {
                ForEach(AICapability.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).disabled(working || inserting)
            HStack {
                Picker("使用模型", selection: Binding<UUID?>(get: { models.selected(for: capability)?.id }, set: {
                    if let id = $0 { models.select(id, for: capability) }
                })) {
                    Text("未配置此类模型").tag(Optional<UUID>.none)
                    ForEach(models.profiles(for: capability)) { Text($0.name + " · " + $0.model).tag(Optional($0.id)) }
                }
                if working { ProgressView().controlSize(.small) }
            }.disabled(working || inserting)
            if !enabled { Text("请在设置 → AI 助手中启用 AI 功能。").font(.callout).foregroundStyle(.secondary) }
            if capability != .transcription {
                TextEditor(text: $prompt).font(.body).frame(height: 95)
                    .padding(8).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        if prompt.isEmpty { Text(promptHint).foregroundStyle(.tertiary).padding(13).allowsHitTesting(false) }
                    }.disabled(working || inserting)
            }
            if capability == .vision {
                HStack {
                    Button(image.isEmpty ? "选择图片（URL / 本地）…" : "更换图片…") { choosingImage = true }
                    if !image.isEmpty { Label("已选择一张图片", systemImage: "checkmark.circle") }
                }.disabled(working)
            }
            if capability == .transcription {
                HStack {
                    Button("选择音频文件…") { chooseAudio() }
                    Text(audioName.isEmpty ? "支持 MP3 / M4A / WAV 等，最大 25 MB" : audioName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.disabled(working)
            }
            HStack {
                Text("仅发送当前输入和所选附件，不自动发送页面内容。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if working { Button("取消请求") { cancel() } }
                else { Button(actionLabel) { run() }.buttonStyle(.borderedProminent).disabled(!canRun || inserting) }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !reply.isEmpty { Text(reply).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    if !generatedImage.isEmpty { MediaImageView(source: generatedImage).frame(height: 240) }
                    if let data = speechData {
                        HStack {
                            Button("播放语音") { play(data) }
                            Button("停止") { playback?.stop() }
                            Button("保存音频…") { saveAudio(data) }
                        }
                        Text("此语音由 AI 生成。").font(.caption).foregroundStyle(.secondary)
                    }
                    if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            if !reply.isEmpty || !generatedImage.isEmpty {
                HStack {
                    if !reply.isEmpty { Button("复制文字") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(reply, forType: .string) } }
                    Spacer()
                    Button(inserting ? "正在插入…" : "插入当前页面") { insertResult() }
                        .disabled(services.model?.selectedPage == nil || working || inserting)
                }
            }
        }.padding(24).frame(width: 760, height: 680)
        .sheet(isPresented: $choosingImage) { ImageSourcePicker(initialValue: image) { image = $0 } }
        .onChange(of: capability) { _, _ in clearResult() }
        .onChange(of: services.currentWorkspace?.id) { _, _ in clearResult(); status = "工作空间已切换，请重新生成。" }
        .onDisappear { cancel() }
        .interactiveDismissDisabled(inserting)
    }

    private var promptHint: String {
        switch capability {
        case .vision: "输入你想了解的图片内容，例如：提取图片中的文字"
        case .imageGeneration: "描述你希望生成的图片"
        case .speech: "输入要朗读的文字"
        default: "输入问题或指令"
        }
    }
    private var actionLabel: String {
        switch capability {
        case .transcription: "转写音频"
        case .imageGeneration: "生成图片"
        case .speech: "生成并播放语音"
        default: "发送"
        }
    }
    private var canRun: Bool {
        enabled && models.selected(for: capability) != nil && (capability == .transcription ? audio != nil : !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (capability != .vision || !image.isEmpty)
    }
    private func cancel() {
        operation?.cancel(); operation = nil; requestID = nil; working = false; playback?.stop()
    }
    private func clearResult() {
        cancel(); reply = ""; generatedImage = ""; speechData = nil; status = ""
    }
    private func chooseAudio() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio, .movie]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { audio = try AIAudioFile.load(url); audioName = url.lastPathComponent; status = "" }
        catch { status = error.localizedDescription }
    }
    private func run() {
        guard canRun, let profile = models.selected(for: capability) else { return }
        clearResult(); working = true; status = "正在请求「\(profile.name)」…"
        let token = UUID(); requestID = token
        let text = prompt; let selectedImage = image; let selectedAudio = audio
        operation = Task {
            defer { if requestID == token { working = false } }
            do {
                let client = AIClient()
                switch profile.capability {
                case .chat, .vision:
                    let result = try await client.chat(profile: profile, messages: [AIClient.userMessage(text, image: profile.capability == .vision ? selectedImage : nil)])
                    try Task.checkCancellation(); reply = result
                case .transcription:
                    guard let selectedAudio else { throw AppError.message("请先选择音频") }
                    let result = try await client.transcribe(profile: profile, audio: selectedAudio)
                    try Task.checkCancellation(); reply = result
                case .imageGeneration:
                    let result = try await client.generateImage(profile: profile, prompt: text)
                    try Task.checkCancellation(); generatedImage = result
                case .speech:
                    let result = try await client.speech(profile: profile, text: text)
                    try Task.checkCancellation(); speechData = result; play(result)
                }
                if profile.capability != .speech { status = "已完成，可查看结果后选择是否插入页面。" }
            } catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }
    private func play(_ data: Data) {
        do {
            playback?.stop(); playback = try AVAudioPlayer(data: data)
            guard playback?.play() == true else { throw AppError.message("无法播放服务返回的音频") }
            status = "正在播放 AI 生成的语音"
        } catch { status = error.localizedDescription }
    }
    private func saveAudio(_ data: Data) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mp3]; panel.nameFieldStringValue = "Velora语音.mp3"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); status = "音频已保存" }
        catch { status = error.localizedDescription }
    }
    private func insertResult() {
        guard !inserting, let model = services.model, let pageID = model.selectedPageID else { return }
        let source = generatedImage; let text = reply
        inserting = true
        operation = Task {
            defer { inserting = false }
            do {
                if !source.isEmpty {
                    let stored: String
                    if source.hasPrefix("data:") { stored = source }
                    else { stored = try await AIClient.downloadImage(source) }
                    try Task.checkCancellation()
                    guard services.model === model else { throw AppError.message("工作空间已切换，请重新选择页面") }
                    try await model.insertMedia(.image, text: stored, pageID: pageID)
                } else {
                    _ = try await model.executeTool("append_text", arguments: ["page_id": pageID.uuidString, "text": text])
                }
                status = "结果已插入页面"
            } catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }
}
