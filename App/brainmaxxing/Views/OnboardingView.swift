import DigestCore
import SwiftUI

/// First-launch setup over the main window: API key (only when none is stored yet), interest profile, categories,
/// nightly agent.
/// Edits a `SettingsModel` draft, so the key, the agent installer and the final save go through the Settings code.
struct OnboardingView: View {
    private enum Step: Int, CaseIterable {
        case apiKey, profile, categories, agent
    }

    @Environment(AppModel.self) private var model
    @State private var settings: SettingsModel?
    @State private var steps = Step.allCases
    @State private var index = 0
    @State private var saveError: String?

    var body: some View {
        Group {
            if let settings {
                content(settings)
            } else {
                ProgressView()
            }
        }
        .frame(width: 620, height: 520)
        .onAppear {
            guard settings == nil else { return }
            model.reloadConfig()
            let draft = SettingsModel(config: model.config)
            // A key already in the Keychain is used as is; the flow then starts with the profile.
            if draft.hasKey { steps = [.profile, .categories, .agent] }
            settings = draft
        }
    }

    private var step: Step { steps[index] }

    private func content(_ settings: SettingsModel) -> some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 14) {
            Text("Step \(index + 1) of \(steps.count)").font(.caption).foregroundStyle(.secondary)
            switch step {
            case .apiKey:
                Text("Anthropic API key").font(.title2.bold())
                Text("The app calls Claude with your own key. It is stored in the Keychain and never written to disk.")
                    .foregroundStyle(.secondary)
                LabeledContent("Status", value: settings.hasKey ? "Stored in Keychain" : "Not set")
                HStack {
                    SecureField("sk-ant-...", text: $settings.apiKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { settings.saveKey(model: model) }
                        .disabled(settings.keyBusy || settings.apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let message = settings.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            case .profile:
                Text("Interest profile").font(.title2.bold())
                Text("Describe what you work on and what you want to read about, in a few sentences.\nName the topics to skip too; Claude ranks every new paper against this text.")
                    .foregroundStyle(.secondary)
                TextEditor(text: $settings.draft.interestProfile)
                    .font(.body)
                    .border(.separator)
            case .categories:
                Text("arXiv categories").font(.title2.bold())
                Text("New papers are collected from these categories every night.")
                    .foregroundStyle(.secondary)
                CategoryPicker(selection: $settings.draft.categories)
            case .agent:
                Text("Nightly agent").font(.title2.bold())
                Text("A launchd agent runs the pipeline between 03:00 and 09:00 while the Mac is awake and idle, so the digest is ready in the morning. You can install it later in Settings.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Install nightly agent") { Task { await settings.installAgent(); await model.refreshStatus() } }
                        .disabled(settings.installing)
                    if settings.installing { ProgressView().controlSize(.small) }
                }
                if let out = settings.installOutput {
                    ScrollView {
                        Text(out).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }
            Spacer(minLength: 0)
            HStack {
                if let problem = problem(settings) ?? saveError {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                if index > 0 {
                    Button("Back") { move(by: -1) }
                }
                Button(step == .agent ? "Later" : "Skip") { skip(settings) }
                Button(step == .agent ? "Finish" : "Continue") { advance(settings) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem(settings) != nil)
            }
        }
        .padding(24)
    }

    /// What blocks "Continue" on the current step (and "Finish", which saves the whole draft).
    private func problem(_ settings: SettingsModel) -> String? {
        switch step {
        case .apiKey: settings.hasKey ? nil : "Save a key to continue, or skip."
        case .profile:
            settings.draft.interestProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "The interest profile is empty." : nil
        case .categories: settings.draft.categories.isEmpty ? "Pick at least one category." : nil
        case .agent: nil
        }
    }

    private func move(by delta: Int) {
        let next = index + delta
        if steps.indices.contains(next) { index = next }
    }

    /// Skipping a step leaves its setting as it was before onboarding.
    private func skip(_ settings: SettingsModel) {
        switch step {
        case .apiKey: settings.apiKey = ""
        case .profile: settings.draft.interestProfile = settings.saved.interestProfile
        case .categories: settings.draft.categories = settings.saved.categories
        case .agent: break
        }
        if step == .agent { finish(settings) } else { move(by: 1) }
    }

    private func advance(_ settings: SettingsModel) {
        if step == .agent { finish(settings) } else { move(by: 1) }
    }

    /// Writes the profile and categories into `config.json` (also when nothing changed, so the file exists) and
    /// remembers that onboarding is done. Only the two fields onboarding edits are touched; the rest of the config
    /// stays as loaded, valid or not, so a stray value elsewhere cannot trap the user in the sheet.
    private func finish(_ settings: SettingsModel) {
        var config = model.config
        config.interestProfile = settings.draft.interestProfile
        config.categories = settings.draft.categories
        do {
            try config.save(home: model.paths.home)
        } catch {
            saveError = error.localizedDescription
            return
        }
        model.reloadConfig()
        model.finishOnboarding()
    }
}
