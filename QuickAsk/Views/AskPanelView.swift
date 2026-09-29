import SwiftUI

struct AskPanelView: View {
    @EnvironmentObject private var state: AppState
    @FocusState private var questionFocused: Bool
    @FocusState private var followUpFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !state.hasConversation {
                composer(text: $state.question, focused: $questionFocused, placeholder: "Ask anything…")
                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let status = state.statusText, state.isLoading {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .id("status")
                        }

                        if let error = state.errorText {
                            Text(error)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }

                        ForEach(state.turns) { turn in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(turn.question)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                if !turn.answer.isEmpty {
                                    Text(turn.answer)
                                        .font(.body)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else if state.isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                            .id(turn.id)
                        }

                        if !state.hasConversation && !state.isLoading && state.errorText == nil {
                            Text(hintText)
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }

                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.answer) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: state.turns.count) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }

            if state.hasConversation {
                Divider()
                composer(text: $state.followUp, focused: $followUpFocused, placeholder: "Ask a follow-up…")
            }

            Divider()

            HStack {
                if let profile = state.activeProfile {
                    Menu {
                        ForEach(state.profiles) { p in
                            Button {
                                state.setActiveProfile(p.id)
                            } label: {
                                HStack {
                                    Text(p.name)
                                    if p.id == profile.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("\(profile.name) · \(profile.model)", systemImage: "cpu")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                }

                Spacer()

                Button("Clear") {
                    state.clearConversation()
                    questionFocused = true
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Text("Esc · \(state.hotKey.displayString)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 640, height: 480)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
        .onAppear { focusInput() }
        .onChange(of: state.isPanelVisible) { _, visible in
            if visible { focusInput() }
        }
        .onChange(of: state.hasConversation) { _, has in
            if has {
                DispatchQueue.main.async { followUpFocused = true }
            } else {
                DispatchQueue.main.async { questionFocused = true }
            }
        }
    }

    private func composer(text: Binding<String>, focused: FocusState<Bool>.Binding, placeholder: String) -> some View {
        HStack(spacing: 10) {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)

            TextField(placeholder, text: text, axis: .vertical)
                .font(.title3)
                .textFieldStyle(.plain)
                .focused(focused)
                .lineLimit(1...4)
                .disabled(state.isLoading)
                .onSubmit {
                    Task { await state.submit() }
                }

            if state.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    Task { await state.submit() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func focusInput() {
        DispatchQueue.main.async {
            if state.hasConversation {
                followUpFocused = true
            } else {
                questionFocused = true
            }
        }
    }

    private var hintText: String {
        "Type a question and press Return.\nShortcut: \(state.hotKey.displayString)"
    }
}
