import Foundation
import SwiftUI

enum AICapability: String, Codable, CaseIterable, Identifiable {
    case chat, vision, transcription, imageGeneration, speech
    var id: String { rawValue }
    var label: String {
        switch self {
        case .chat: "文字对话"
        case .vision: "图片理解"
        case .transcription: "语音转文字"
        case .imageGeneration: "图片生成"
        case .speech: "语音朗读"
        }
    }
    var path: String {
        switch self {
        case .chat, .vision: "chat/completions"
        case .transcription: "audio/transcriptions"
        case .imageGeneration: "images/generations"
        case .speech: "audio/speech"
        }
    }
}

struct AIModelProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var provider = "自定义兼容服务"
    var endpoint = ""
    var model = ""
    var capability: AICapability = .chat
    var voice = "alloy"
    var usesLegacyKey = false
    var keyAccount: String { usesLegacyKey ? "ai-key" : "ai-model-" + id.uuidString }
}

struct AIModelConfiguration: Codable {
    var profiles: [AIModelProfile] = []
    var defaults: [String: UUID] = [:]
}

@MainActor
final class AIModelStore: ObservableObject {
    static let shared = AIModelStore()
    @Published private(set) var configuration = AIModelConfiguration()
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let storageKey = "aiModelConfiguration.v1"
    var profiles: [AIModelProfile] { configuration.profiles }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey) {
            do { configuration = try JSONDecoder().decode(AIModelConfiguration.self, from: data) }
            catch { self.error = "模型配置无法读取，原配置已保留：" + error.localizedDescription }
        } else if let endpoint = defaults.string(forKey: "aiEndpoint"), !endpoint.isEmpty {
            var legacy = AIModelProfile()
            legacy.name = "原有模型"; legacy.endpoint = endpoint
            legacy.model = defaults.string(forKey: "aiModel") ?? ""; legacy.usesLegacyKey = true
            configuration.profiles = [legacy]; configuration.defaults[AICapability.chat.rawValue] = legacy.id
            persist()
        }
    }

    func profiles(for capability: AICapability) -> [AIModelProfile] { profiles.filter { $0.capability == capability } }
    func selected(for capability: AICapability) -> AIModelProfile? {
        let choices = profiles(for: capability)
        return choices.first { $0.id == configuration.defaults[capability.rawValue] } ?? choices.first
    }
    func select(_ id: UUID, for capability: AICapability) {
        guard profiles(for: capability).contains(where: { $0.id == id }) else { return }
        configuration.defaults[capability.rawValue] = id; persist()
    }
    func validate(_ profile: AIModelProfile) throws -> AIModelProfile {
        guard error == nil else { throw AppError.message(error!) }
        var profile = profile
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.endpoint = profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.voice = profile.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty, !profile.model.isEmpty else { throw AppError.message("请填写配置名称和模型 ID") }
        guard !profiles.contains(where: { $0.id != profile.id && $0.name.caseInsensitiveCompare(profile.name) == .orderedSame }) else {
            throw AppError.message("已存在同名模型配置")
        }
        _ = try AIClient.endpoint(profile.endpoint, capability: profile.capability)
        if profile.capability == .speech && profile.voice.isEmpty { throw AppError.message("请填写服务商支持的音色 ID") }
        return profile
    }
    func upsert(_ profile: AIModelProfile) throws {
        let profile = try validate(profile)
        if let index = configuration.profiles.firstIndex(where: { $0.id == profile.id }) { configuration.profiles[index] = profile }
        else { configuration.profiles.append(profile) }
        if selected(for: profile.capability) == nil || configuration.defaults[profile.capability.rawValue] == nil {
            configuration.defaults[profile.capability.rawValue] = profile.id
        }
        persist()
    }
    func remove(_ profile: AIModelProfile) throws {
        guard error == nil else { throw AppError.message(error!) }
        try SecretStore.save("", account: profile.keyAccount)
        configuration.profiles.removeAll { $0.id == profile.id }
        configuration.defaults = configuration.defaults.filter { $0.value != profile.id }
        persist()
    }
    private func persist() {
        do { defaults.set(try JSONEncoder().encode(configuration), forKey: storageKey) }
        catch { self.error = error.localizedDescription }
    }
}
