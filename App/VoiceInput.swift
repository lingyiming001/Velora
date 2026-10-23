import AVFoundation
import Speech
import SwiftUI

@MainActor
final class VoiceInput: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var starting = false
    @Published private(set) var transcript = ""
    @Published private(set) var status = ""
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var hasTap = false
    private var stopTask: Task<Void, Never>?
    private var sessionID: UUID?

    func start() async {
        guard !recording, !starting else { return }
        stop()
        starting = true
        defer { starting = false }
        let attempt = UUID(); sessionID = attempt
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard sessionID == attempt else { return }
        guard speech == .authorized else { status = L10n.tr("请在系统设置中允许 Velora 使用语音识别"); return }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard sessionID == attempt else { return }
        guard microphone else { status = L10n.tr("请在系统设置中允许 Velora 使用麦克风"); return }
        let defaults = UserDefaults.standard
        let locale = defaults.string(forKey: "voiceLocale") ?? "zh-CN"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            status = L10n.tr("当前语言的语音识别不可用"); return
        }
        let localOnly = defaults.object(forKey: "voiceOnDevice") as? Bool ?? true
        if localOnly && !recognizer.supportsOnDeviceRecognition { status = L10n.tr("当前设备或语言不支持离线识别，可在设置中允许在线识别"); return }
        transcript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = localOnly
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { status = L10n.tr("麦克风没有可用的音频输入"); return }
        let id = attempt
        self.request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        hasTap = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if result?.isFinal == true || error != nil {
                    self.stop()
                    if let error { self.status = L10n.tr("语音识别已停止：\(error.localizedDescription)") }
                }
            }
        }
        do {
            engine.prepare(); try engine.start()
            recording = true; status = L10n.tr("正在聆听，结束后可编辑识别结果")
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(55))
                if !Task.isCancelled { self?.finish() }
            }
        } catch { stop(); status = error.localizedDescription }
    }

    func finish() {
        if engine.isRunning { engine.stop() }
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio(); recording = false
        stopTask?.cancel(); stopTask = nil
        status = L10n.tr("识别结果可编辑；生成操作预览后再执行")
    }

    func stop() {
        sessionID = nil
        if engine.isRunning { engine.stop() }
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio(); task?.cancel(); task = nil; request = nil
        stopTask?.cancel(); stopTask = nil; recording = false
    }
}
