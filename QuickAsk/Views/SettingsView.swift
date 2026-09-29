import SwiftUI
import Carbon
import AppKit
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedProfileID: UUID?
    @State private var apiKeyDraft: String = ""
    @State private var isRecordingHotKey = false
    @State private var statusMessage: String?
    @State private var selectedHistoryID: HistoryEntry.ID?

    var body: some View {
        TabView {
            providersTab
                .tabItem { Label("Providers", systemImage: "cpu") }

            historyTab
                .tabItem { Label("History", systemImage: "clock") }

            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 620, height: 460)
        .onAppear {
            selectedProfileID = state.activeProfileID ?? state.profiles.first?.id
            refreshKeyDraft()
        }
    }

    // MARK: - Providers

    private var providersTab: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedProfileID) {
                    ForEach(state.profiles) { profile in
                        HStack {
                            Text(profile.name)
                            Spacer()
                            if profile.id == state.activeProfileID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                                    .imageScale(.small)
                            }
                        }
                        .tag(profile.id)
                    }
                }
                .listStyle(.sidebar)

                HStack(spacing: 8) {
                    Menu {
                        Button("OpenCode Go") { addPreset(.openCodeGo) }
                        Button("DeepSeek") { addPreset(.deepSeek) }
                        Button("Custom (OpenAI-compatible)") { addPreset(.openAICompatible) }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                    .help("Add provider")

                    Button {
                        if let id = selectedProfileID {
                            state.deleteProfile(id)
                            selectedProfileID = state.profiles.first?.id
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 28)
                    .disabled(selectedProfileID == nil || state.profiles.count <= 1)
                    .help("Remove provider")

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(minWidth: 160, idealWidth: 180, maxWidth: 220)

            Group {
                if let id = selectedProfileID,
                   let idx = state.profiles.firstIndex(where: { $0.id == id }) {
                    providerEditor(index: idx)
                        .padding()
                } else {
                    ContentUnavailableView(
                        "No provider",
                        systemImage: "cpu",
                        description: Text("Add OpenCode Go or DeepSeek with +")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func providerEditor(index: Int) -> some View {
        let binding = $state.profiles[index]
        let profile = state.profiles[index]
        let modelChoices = state.models(for: profile)

        Form {
            TextField("Name", text: binding.name)

            Picker("Type", selection: binding.kind) {
                ForEach(ProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .onChange(of: state.profiles[index].kind) { _, newKind in
                state.profiles[index].baseURL = newKind.defaultBaseURL
                if let first = newKind.defaultModels.first {
                    state.profiles[index].model = first
                }
                state.remoteModels[profile.id] = nil
                state.persistProfiles()
            }

            TextField("Base URL", text: binding.baseURL)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Model")
                    Spacer()
                    Button {
                        Task { await state.refreshModels(for: profile.id) }
                    } label: {
                        if state.modelsLoadingProfileID == profile.id {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Fetch models", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(!profile.hasAPIKey || state.modelsLoadingProfileID == profile.id)
                    .help(profile.hasAPIKey ? "Load list from /v1/models" : "Save an API key first")
                }

                if !modelChoices.isEmpty {
                    Picker("Model", selection: binding.model) {
                        ForEach(modelChoices, id: \.self) { model in
                            Text(model).tag(model)
                        }
                        if !modelChoices.contains(profile.model), !profile.model.isEmpty {
                            Text(profile.model).tag(profile.model)
                        }
                    }
                    .labelsHidden()
                }

                TextField("Or type model id", text: binding.model)
                    .textFieldStyle(.roundedBorder)

                if let err = state.modelsError, state.modelsLoadingProfileID == nil {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            SecureField(
                profile.hasAPIKey ? "API key (saved — paste to replace)" : "API key",
                text: $apiKeyDraft
            )
            .textFieldStyle(.roundedBorder)

            HStack {
                Button("Save API Key") {
                    do {
                        try state.saveAPIKey(for: profile.id, key: apiKeyDraft)
                        apiKeyDraft = ""
                        statusMessage = "API key saved locally."
                        Task { await state.refreshModels(for: profile.id) }
                    } catch {
                        statusMessage = error.localizedDescription
                    }
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Use as active") {
                    state.setActiveProfile(profile.id)
                    statusMessage = "Active: \(profile.name)"
                }

                Spacer()

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(helpText(for: profile.kind))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Keys are stored in ~/Library/Application Support/QuickAsk/ (not Keychain).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .onChange(of: state.profiles[index]) { _, _ in
            state.persistProfiles()
        }
        .onAppear {
            if profile.hasAPIKey, state.remoteModels[profile.id] == nil {
                Task { await state.refreshModels(for: profile.id) }
            }
        }
    }

    // MARK: - History

    private var historyTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keep last")
                Stepper(value: Binding(
                    get: { state.historyLimit },
                    set: { state.updateHistoryLimit($0) }
                ), in: 10...500, step: 10) {
                    Text("\(state.historyLimit)")
                        .monospacedDigit()
                        .frame(minWidth: 36, alignment: .trailing)
                }
                Spacer()
                Button("Clear all", role: .destructive) {
                    state.clearHistory()
                    selectedHistoryID = nil
                }
                .disabled(state.history.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Text("Stored in UserDefaults → ~/Library/Preferences/com.quickask.app.plist (key quickask.history). Not a separate database file.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            Divider()

            if state.history.isEmpty {
                ContentUnavailableView(
                    "No history yet",
                    systemImage: "clock",
                    description: Text("Answered questions will show up here.")
                )
            } else {
                HSplitView {
                    List(selection: $selectedHistoryID) {
                        ForEach(state.history) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.question)
                                    .lineLimit(2)
                                Text(entry.createdAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(entry.id)
                        }
                        .onDelete { indexSet in
                            for i in indexSet {
                                state.deleteHistoryEntry(state.history[i].id)
                            }
                        }
                    }
                    .frame(minWidth: 200, idealWidth: 240)

                    if let id = selectedHistoryID,
                       let entry = state.history.first(where: { $0.id == id }) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(entry.question)
                                    .font(.headline)
                                    .textSelection(.enabled)

                                Text("\(entry.providerName) · \(entry.model)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(entry.answer)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                HStack {
                                    Button("Ask again") {
                                        state.reuseHistoryEntry(entry)
                                    }
                                    Button("Delete", role: .destructive) {
                                        state.deleteHistoryEntry(entry.id)
                                        selectedHistoryID = nil
                                    }
                                }
                            }
                            .padding()
                        }
                    } else {
                        ContentUnavailableView("Select an entry", systemImage: "text.bubble")
                    }
                }
            }
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Hotkey") {
                HStack {
                    Text(state.hotKey.displayString)
                        .font(.system(.title3, design: .rounded).monospaced())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Button(isRecordingHotKey ? "Press keys…" : "Change…") {
                        isRecordingHotKey.toggle()
                    }

                    Button("Reset ⌥Space") {
                        state.updateHotKey(
                            StoredHotKey(
                                keyCode: HotKeyDefaults.keyCode,
                                carbonModifiers: HotKeyDefaults.carbonModifiers
                            )
                        )
                        isRecordingHotKey = false
                    }
                }

                if isRecordingHotKey {
                    HotKeyRecorder { stored in
                        state.updateHotKey(stored)
                        isRecordingHotKey = false
                    }
                    .frame(height: 1)
                    Text("Hold modifier(s) and press a key. Esc cancels.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("System prompt") {
                TextEditor(text: Binding(
                    get: { state.systemPrompt },
                    set: { state.updateSystemPrompt($0) }
                ))
                .font(.body)
                .frame(minHeight: 120)
            }

            Section("Ask panel") {
                Toggle("Clear panel on each open", isOn: Binding(
                    get: { state.clearOnOpen },
                    set: { state.setClearOnOpen($0) }
                ))
                Text("When on, ⌥Space opens an empty question field. History is still kept under the History tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Web search") {
                Toggle("Enable web search", isOn: Binding(
                    get: { state.webSearchEnabled },
                    set: { state.setWebSearchEnabled($0) }
                ))
                Text("One DuckDuckGo search + streamed answer (faster, like OpenCode). Turn off for pure model answers with no web.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Launch") {
                Toggle("Open at login", isOn: openAtLoginBinding)
            }
        }
        .padding()
        .formStyle(.grouped)
    }

    private var openAtLoginBinding: Binding<Bool> {
        Binding(
            get: { LaunchAtLogin.isEnabled },
            set: { LaunchAtLogin.isEnabled = $0 }
        )
    }

    private func addPreset(_ kind: ProviderKind) {
        let profile = ProviderProfile.preset(kind)
        state.upsertProfile(profile)
        selectedProfileID = profile.id
        refreshKeyDraft()
    }

    private func refreshKeyDraft() {
        apiKeyDraft = ""
        statusMessage = nil
        state.modelsError = nil
    }

    private func helpText(for kind: ProviderKind) -> String {
        switch kind {
        case .openCodeGo:
            return "Key from OpenCode Console (Go). Fetch models after saving the key."
        case .deepSeek:
            return "Key from platform.deepseek.com. Fetch models after saving the key."
        case .openAICompatible:
            return "Any OpenAI-compatible endpoint (OpenRouter, Groq, Ollama /v1, …)."
        }
    }
}

struct HotKeyRecorder: NSViewRepresentable {
    var onRecord: (StoredHotKey) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onRecord = onRecord
    }

    final class RecorderView: NSView {
        var onRecord: ((StoredHotKey) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                window?.makeFirstResponder(nil)
                return
            }

            var mods: UInt32 = 0
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.control) { mods |= UInt32(controlKey) }
            if flags.contains(.option) { mods |= UInt32(optionKey) }
            if flags.contains(.shift) { mods |= UInt32(shiftKey) }
            if flags.contains(.command) { mods |= UInt32(cmdKey) }

            guard mods != 0 else { return }

            onRecord?(StoredHotKey(keyCode: UInt32(event.keyCode), carbonModifiers: mods))
        }
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "quickask.openAtLogin") }
        set {
            UserDefaults.standard.set(newValue, forKey: "quickask.openAtLogin")
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Preference kept; registration may fail when unsigned.
            }
        }
    }
}
