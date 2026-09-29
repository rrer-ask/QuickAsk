import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var profiles: [ProviderProfile] = []
    @Published var activeProfileID: UUID?
    @Published var hotKey: StoredHotKey
    @Published var systemPrompt: String
    @Published var historyLimit: Int
    @Published var history: [HistoryEntry] = []
    /// Current panel thread (multi-turn).
    @Published var turns: [ConversationTurn] = []
    /// Top field when starting fresh; also used as first question.
    @Published var question: String = ""
    /// Follow-up field after there is at least one answer.
    @Published var followUp: String = ""
    @Published var answer: String = ""
    @Published var isLoading: Bool = false
    @Published var errorText: String?
    @Published var isPanelVisible: Bool = false
    /// Cached model IDs per profile, from /v1/models.
    @Published var remoteModels: [UUID: [String]] = [:]
    @Published var modelsLoadingProfileID: UUID?
    @Published var modelsError: String?
    /// One web search + streamed answer (fast, OpenCode-like).
    @Published var webSearchEnabled: Bool
    @Published var statusText: String?
    /// Clear question/answer each time the panel is opened.
    @Published var clearOnOpen: Bool

    var hasConversation: Bool { !turns.isEmpty }

    private let chat = ChatClient()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let profiles = "quickask.profiles"
        static let active = "quickask.activeProfile"
        static let hotKey = "quickask.hotKey"
        static let systemPrompt = "quickask.systemPrompt"
        static let history = "quickask.history"
        static let historyLimit = "quickask.historyLimit"
        static let webSearch = "quickask.webSearch"
        static let clearOnOpen = "quickask.clearOnOpen"
    }

    private init() {
        if let data = defaults.data(forKey: Keys.hotKey),
           let decoded = try? JSONDecoder().decode(StoredHotKey.self, from: data) {
            hotKey = decoded
        } else {
            hotKey = StoredHotKey(
                keyCode: HotKeyDefaults.keyCode,
                carbonModifiers: HotKeyDefaults.carbonModifiers
            )
        }

        systemPrompt = defaults.string(forKey: Keys.systemPrompt)
            ?? "You are a concise, accurate assistant. Answer briefly when possible. Use the user's language."

        if defaults.object(forKey: Keys.webSearch) == nil {
            // migrate old key if present
            if defaults.object(forKey: "quickask.liveLookups") != nil {
                webSearchEnabled = defaults.bool(forKey: "quickask.liveLookups")
            } else {
                webSearchEnabled = true
            }
        } else {
            webSearchEnabled = defaults.bool(forKey: Keys.webSearch)
        }

        if defaults.object(forKey: Keys.clearOnOpen) == nil {
            clearOnOpen = true
        } else {
            clearOnOpen = defaults.bool(forKey: Keys.clearOnOpen)
        }

        let savedLimit = defaults.object(forKey: Keys.historyLimit) as? Int
        historyLimit = min(500, max(10, savedLimit ?? 100))

        if let data = defaults.data(forKey: Keys.history),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = decoded
        }

        if let data = defaults.data(forKey: Keys.profiles),
           let decoded = try? JSONDecoder().decode([ProviderProfile].self, from: data),
           !decoded.isEmpty {
            profiles = decoded.map { profile in
                var p = profile
                p.hasAPIKey = SecretStore.load(account: p.id.uuidString) != nil
                return p
            }
        } else {
            profiles = [
                .preset(.openCodeGo),
                .preset(.deepSeek)
            ]
            persistProfiles()
        }

        if let idString = defaults.string(forKey: Keys.active),
           let id = UUID(uuidString: idString),
           profiles.contains(where: { $0.id == id }) {
            activeProfileID = id
        } else {
            activeProfileID = profiles.first?.id
        }

        installHotKey()
    }

    var activeProfile: ProviderProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Keys.profiles)
        }
        if let activeProfileID {
            defaults.set(activeProfileID.uuidString, forKey: Keys.active)
        }
    }

    func setActiveProfile(_ id: UUID) {
        activeProfileID = id
        persistProfiles()
    }

    func upsertProfile(_ profile: ProviderProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        persistProfiles()
    }

    func deleteProfile(_ id: UUID) {
        SecretStore.delete(account: id.uuidString)
        profiles.removeAll { $0.id == id }
        remoteModels[id] = nil
        if activeProfileID == id {
            activeProfileID = profiles.first?.id
        }
        persistProfiles()
    }

    func saveAPIKey(for profileID: UUID, key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            SecretStore.delete(account: profileID.uuidString)
            if let idx = profiles.firstIndex(where: { $0.id == profileID }) {
                profiles[idx].hasAPIKey = false
            }
        } else {
            try SecretStore.save(account: profileID.uuidString, secret: trimmed)
            if let idx = profiles.firstIndex(where: { $0.id == profileID }) {
                profiles[idx].hasAPIKey = true
            }
        }
        persistProfiles()
    }

    func setWebSearchEnabled(_ enabled: Bool) {
        webSearchEnabled = enabled
        defaults.set(enabled, forKey: Keys.webSearch)
    }

    func setClearOnOpen(_ enabled: Bool) {
        clearOnOpen = enabled
        defaults.set(enabled, forKey: Keys.clearOnOpen)
    }

    func updateHotKey(_ newValue: StoredHotKey) {
        hotKey = newValue
        if let data = try? JSONEncoder().encode(newValue) {
            defaults.set(data, forKey: Keys.hotKey)
        }
        installHotKey()
    }

    func updateSystemPrompt(_ text: String) {
        systemPrompt = text
        defaults.set(text, forKey: Keys.systemPrompt)
    }

    func updateHistoryLimit(_ limit: Int) {
        historyLimit = min(500, max(10, limit))
        defaults.set(historyLimit, forKey: Keys.historyLimit)
        trimHistory()
        persistHistory()
    }

    func clearHistory() {
        history = []
        persistHistory()
    }

    func deleteHistoryEntry(_ id: UUID) {
        history.removeAll { $0.id == id }
        persistHistory()
    }

    func reuseHistoryEntry(_ entry: HistoryEntry) {
        clearConversation()
        turns = [ConversationTurn(question: entry.question, answer: entry.answer)]
        answer = entry.answer
        errorText = nil
        if let profileID = entry.profileID,
           profiles.contains(where: { $0.id == profileID }) {
            setActiveProfile(profileID)
        }
        // Don't clearOnOpen wipe when reopening from history
        isPanelVisible = true
        AskPanelController.shared.show()
    }

    func installHotKey() {
        HotKeyManager.shared.register(
            keyCode: hotKey.keyCode,
            carbonModifiers: hotKey.carbonModifiers
        ) { [weak self] in
            Task { @MainActor in
                self?.togglePanel()
            }
        }
    }

    func togglePanel() {
        if isPanelVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        if clearOnOpen {
            clearConversation()
        }
        isPanelVisible = true
        AskPanelController.shared.show()
    }

    func hidePanel() {
        isPanelVisible = false
        AskPanelController.shared.hide()
    }

    func clearConversation() {
        question = ""
        followUp = ""
        answer = ""
        turns = []
        errorText = nil
        statusText = nil
    }

    func submit() async {
        let isFollowUp = hasConversation
        let q = (isFollowUp ? followUp : question)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard let profile = activeProfile else {
            errorText = "No provider selected. Open Settings."
            return
        }

        isLoading = true
        errorText = nil
        statusText = webSearchEnabled ? "Working…" : "Writing…"

        var pending = ConversationTurn(question: q, answer: "")
        turns.append(pending)
        if isFollowUp {
            followUp = ""
        } else {
            question = ""
        }

        var messages: [ChatMessage] = []
        for turn in turns {
            messages.append(.user(turn.question))
            if !turn.answer.isEmpty {
                messages.append(.assistant(turn.answer))
            }
        }

        do {
            let result = try await chat.ask(
                messages: messages,
                profile: profile,
                systemPrompt: systemPrompt,
                webSearchEnabled: webSearchEnabled,
                onStatus: { [weak self] status in
                    Task { @MainActor in self?.statusText = status }
                },
                onDelta: { [weak self] piece in
                    Task { @MainActor in
                        guard let self else { return }
                        if let idx = self.turns.indices.last {
                            self.turns[idx].answer += piece
                            self.answer = self.turns[idx].answer
                        }
                    }
                }
            )
            if let idx = turns.indices.last {
                turns[idx].answer = result
                answer = result
                pending = turns[idx]
            }
            appendHistory(
                HistoryEntry(
                    question: q,
                    answer: result,
                    providerName: profile.name,
                    model: profile.model,
                    profileID: profile.id
                )
            )
        } catch {
            errorText = error.localizedDescription
            if let idx = turns.indices.last, turns[idx].answer.isEmpty {
                turns.remove(at: idx)
            }
        }

        statusText = nil
        isLoading = false
    }

    func refreshModels(for profileID: UUID) async {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        modelsLoadingProfileID = profileID
        modelsError = nil
        do {
            let models = try await chat.listModels(profile: profile)
            remoteModels[profileID] = models
            if !models.contains(profile.model), let first = models.first,
               let idx = profiles.firstIndex(where: { $0.id == profileID }) {
                // Keep current model if still valid; otherwise leave as typed custom id.
                _ = first
            }
        } catch {
            modelsError = error.localizedDescription
        }
        modelsLoadingProfileID = nil
    }

    func models(for profile: ProviderProfile) -> [String] {
        if let remote = remoteModels[profile.id], !remote.isEmpty {
            return remote
        }
        return profile.kind.defaultModels
    }

    private func appendHistory(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        trimHistory()
        persistHistory()
    }

    private func trimHistory() {
        if history.count > historyLimit {
            history = Array(history.prefix(historyLimit))
        }
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Keys.history)
        }
    }
}
