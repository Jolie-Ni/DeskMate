import DeskMateAnalyzer
import DeskMateCore
import SwiftUI

/// First run. One field, one button.
///
/// The key is checked against the API before it is saved, so a bad paste fails
/// here rather than an hour later when Analyze finally runs and hands back a
/// 401. Being offline is not the same as being wrong: a network failure saves
/// the key anyway and says it could not check.
///
/// Skippable on purpose. Capture never touches the network and works without a
/// key, so a wall here would block the part of the app that needs nothing from
/// Anthropic at all.
struct SetupView: View {
    @Environment(\.dsTheme) private var theme

    /// Called once the screen is finished with — saved or skipped.
    let onDone: () -> Void

    @State private var key = ""
    @State private var step: Step = .editing

    private enum Step: Equatable {
        case editing
        case checking
        case failed(String)
        /// Saved, but the API could not be reached to confirm it works.
        case savedUnverified
    }

    private var isChecking: Bool { step == .checking }

    private var errorText: String? {
        if case .failed(let message) = step { return message }
        return nil
    }

    var body: some View {
        ZStack {
            DSBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: theme.space(3)) {
                    header
                    keyCard
                    privacyNote
                }
                .frame(maxWidth: 520)
                .padding(theme.space(4))
            }
            .frame(maxWidth: .infinity)
        }
        .dsTheme(.default)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.space(1)) {
            DSEyebrow(text: "Welcome", color: theme.accentDeep)
            Text("Set up DeskMate")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(theme.ink)
            Text("DeskMate watches how you actually work, then tells you which "
                 + "parts should be a machine's job. Reading your week needs a "
                 + "Claude API key. Recording it does not.")
                .font(theme.body)
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keyCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: theme.space(2)) {
                DSTextField(
                    placeholder: "sk-ant-…",
                    text: $key,
                    label: "Anthropic API key",
                    systemImage: "key.fill",
                    errorText: errorText,
                    helperText: "Stored at \(APIKeyStore.displayPath), readable only by you.",
                    isSecure: true,
                    submitLabel: .go,
                    onSubmit: submit
                )
                .disabled(isChecking)

                Link("Get a key at console.anthropic.com",
                     destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(theme.callout)
                    .foregroundStyle(theme.accentDeep)

                if step == .savedUnverified {
                    DSBanner(
                        title: "Saved, but not checked",
                        message: "Couldn't reach the Claude API to confirm the key works. "
                               + "It's saved — Analyze will tell you if it's wrong.",
                        tone: .attention)
                }

                HStack(spacing: theme.space(1.5)) {
                    Button(isChecking ? "Checking…" : "Save and continue", action: submit)
                        .buttonStyle(.ds(.primary, size: .large))
                        .disabled(isChecking || key.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button("Skip for now") { finishSkipping() }
                        .buttonStyle(.ds(.quiet, size: .large))
                        .disabled(isChecking)

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: theme.space(1)) {
            Text("What this key is for")
                .font(theme.headline)
                .foregroundStyle(theme.ink)
            Text("Only the Analyze button and the optional nightly summary use it. "
                 + "Capture never touches the network — screenshots, OCR and redaction "
                 + "all happen on this machine, and nothing is sent anywhere until you "
                 + "ask for it. You can change or remove the key later in Settings.")
                .font(theme.callout)
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func submit() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard APIKeyStore.looksLikeAnthropicKey(trimmed) else {
            step = .failed("Anthropic keys start with sk-ant-. That looks like something else.")
            return
        }

        step = .checking
        Task {
            do {
                try await AnthropicClient.verify(key: trimmed)
                try APIKeyStore.save(trimmed)
                onDone()
            } catch let error as AnthropicError {
                await MainActor.run { step = .failed(Self.describe(error)) }
            } catch let error as APIKeyStore.StoreError {
                await MainActor.run { step = .failed(error.localizedDescription) }
            } catch {
                // URLSession threw — offline, DNS, a proxy. That says nothing
                // about the key, so keep it rather than throwing away a paste.
                do {
                    try APIKeyStore.save(trimmed)
                    await MainActor.run { step = .savedUnverified }
                } catch {
                    await MainActor.run { step = .failed(error.localizedDescription) }
                }
            }
        }
    }

    private func finishSkipping() {
        SetupState.markSeen()
        onDone()
    }

    /// A 401 means the key is wrong, which is the whole point of checking. Every
    /// other status is a problem with the request or the service, and blaming
    /// the key for those would send people off to regenerate a working one.
    private static func describe(_ error: AnthropicError) -> String {
        guard case .http(let code, _) = error else { return error.localizedDescription }
        switch code {
        case 401:      return "Anthropic rejected that key. Check it was copied whole."
        case 403:      return "That key is valid but not allowed to use the Messages API."
        case 429:      return "Rate limited while checking. Wait a moment and try again."
        case 400..<500: return "Anthropic returned \(code) while checking the key."
        default:       return "Anthropic is having trouble (\(code)). Try again shortly."
        }
    }
}

/// Whether setup has been dealt with.
///
/// Two separate facts, and conflating them is a bug: a saved key means setup
/// succeeded, while the flag records that someone deliberately skipped. Without
/// the flag, skipping would show the same screen at every launch forever.
enum SetupState {
    private static let key = "setupSeen"

    static var needsSetup: Bool {
        if APIKeyStore.hasKey { return false }
        return !UserDefaults.standard.bool(forKey: key)
    }

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: key)
    }
}
