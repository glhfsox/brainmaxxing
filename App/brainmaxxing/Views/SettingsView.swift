import DigestCore
import Observation
import SwiftUI

/// Draft of `config.json` plus the API key and agent installer actions. Nothing is written until "Save".
@Observable @MainActor
final class SettingsModel {
    static let modelChoices = ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]
    static let languages = [("ru", "Russian (English terms)"), ("en", "English")]
    static let levels = [("engineer", "ML engineer"), ("two_layer", "Two layers"), ("intro", "Introductory")]

    var draft: Config
    private(set) var saved: Config
    var apiKey = ""
    private(set) var hasKey = KeychainStore.hasAnthropicKey()
    private(set) var message: String?
    private(set) var installOutput: String?
    private(set) var installing = false

    init(config: Config) {
        draft = config
        saved = config
    }

    var isDirty: Bool { draft != saved }

    /// Problems that make the draft unsavable; empty when valid.
    var problems: [String] {
        var p: [String] = []
        if draft.categories.isEmpty { p.append("Pick at least one category.") }
        if draft.interestProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { p.append("The interest profile is empty.") }
        if !(draft.dailyBudgetUsd > 0) { p.append("The daily budget must be above $0.") }
        let s = draft.schedule
        if !(0...23).contains(s.windowStart) || !(1...24).contains(s.windowEnd) || s.windowStart >= s.windowEnd {
            p.append("The run window must start before it ends, within one day.")
        }
        if !(0...23).contains(s.showAt) { p.append("Show time must be an hour 0-23.") }
        if !(1...240).contains(s.idleMinutes) { p.append("Idle minutes must be 1-240.") }
        return p
    }

    func save(home: URL, model: AppModel) {
        guard problems.isEmpty else { return }
        let scheduleChanged = draft.schedule != saved.schedule
        do {
            try draft.save(home: home)
            saved = draft
            model.reloadConfig()
            Task { await model.refreshStatus() }
            message = scheduleChanged ? "Saved. Click \"Install nightly agent\" for the new schedule to take effect." : "Saved."
        } catch {
            message = error.localizedDescription
        }
    }

    func revert() { draft = saved }

    func saveKey(model: AppModel) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try KeychainStore.saveAnthropicKey(key)
            model.chat.apiKeyMayHaveChanged()
            apiKey = ""
            message = "API key saved to the Keychain."
        } catch {
            message = error.localizedDescription
        }
        hasKey = KeychainStore.hasAnthropicKey()
    }

    func deleteKey(model: AppModel) {
        do {
            try KeychainStore.deleteAnthropicKey()
            model.chat.apiKeyMayHaveChanged()
            message = "API key removed."
        } catch {
            message = error.localizedDescription
        }
        hasKey = KeychainStore.hasAnthropicKey()
    }

    /// Runs the bundled `digest-cli install-agent` and shows its output.
    func installAgent() async {
        guard let cli = RunController.cliURL, FileManager.default.isExecutableFile(atPath: cli.path) else {
            installOutput = RunControllerError.cliMissing(RunController.cliURL?.path ?? "digest-cli").localizedDescription
            return
        }
        installing = true
        defer { installing = false }
        let result = await CLIProcess.run(cli, arguments: ["install-agent"])
        installOutput = (result.status == 0 ? "" : "Failed (exit \(result.status)).\n") + result.output
    }
}

/// One-shot child process with combined output, off the main actor.
enum CLIProcess {
    static func run(_ url: URL, arguments: [String]) async -> (status: Int32, output: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = url
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return (Int32(-1), error.localizedDescription)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var settings: SettingsModel?

    var body: some View {
        Group {
            if let settings {
                SettingsForm(settings: settings)
            } else {
                ProgressView()
            }
        }
        .frame(width: 640, height: 620)
        .onAppear {
            model.reloadConfig()
            settings = SettingsModel(config: model.config)
        }
    }
}

private struct SettingsForm: View {
    @Environment(AppModel.self) private var model
    @Bindable var settings: SettingsModel

    var body: some View {
        TabView {
            Tab("Topics", systemImage: "list.bullet") {
                Form {
                    Section("Categories") {
                        CategoryPicker(selection: $settings.draft.categories).frame(minHeight: 260)
                    }
                    Section("Interest profile") {
                        TextEditor(text: $settings.draft.interestProfile)
                            .font(.body)
                            .frame(minHeight: 120)
                    }
                    Section {
                        Toggle("OpenAlex (journal papers)", isOn: $settings.draft.sources.openalex)
                        Toggle("HuggingFace Daily Papers", isOn: $settings.draft.sources.hfPapers)
                    } header: {
                        Text("Sources")
                    } footer: {
                        Text("arXiv is always on. Changes apply from the next run.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
            Tab("Digest", systemImage: "doc.richtext") {
                Form {
                    Section("Models") {
                        modelPicker("Triage", selection: $settings.draft.models.triage)
                        modelPicker("Digest", selection: $settings.draft.models.digest)
                        modelPicker("Chat", selection: $settings.draft.models.chat)
                    }
                    Section("Output") {
                        Picker("Language", selection: $settings.draft.language) {
                            ForEach(SettingsModel.languages, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        Picker("Explanation level", selection: $settings.draft.explanationLevel) {
                            ForEach(SettingsModel.levels, id: \.0) { Text($0.1).tag($0.0) }
                        }
                    }
                    Section("Budget") {
                        TextField("Daily budget (USD)", value: $settings.draft.dailyBudgetUsd, format: .number.precision(.fractionLength(2)))
                    }
                }
                .formStyle(.grouped)
            }
            Tab("Schedule", systemImage: "clock") {
                Form {
                    Section("Nightly run") {
                        Stepper("Window starts at \(settings.draft.schedule.windowStart):00", value: $settings.draft.schedule.windowStart, in: 0...23)
                        Stepper("Window ends at \(settings.draft.schedule.windowEnd):00", value: $settings.draft.schedule.windowEnd, in: 1...24)
                        Stepper("Run only after \(settings.draft.schedule.idleMinutes) idle minutes", value: $settings.draft.schedule.idleMinutes, in: 1...240)
                        Stepper("Show digest at \(settings.draft.schedule.showAt):00", value: $settings.draft.schedule.showAt, in: 0...23)
                    }
                    Section("Nightly agent") {
                        HStack {
                            Button("Install nightly agent") { Task { await settings.installAgent(); await model.refreshStatus() } }
                                .disabled(settings.installing || settings.isDirty)
                            if settings.installing { ProgressView().controlSize(.small) }
                            if settings.isDirty { Text("Save first").font(.caption).foregroundStyle(.secondary) }
                        }
                        if let out = settings.installOutput {
                            ScrollView {
                                Text(out).font(.caption.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 140)
                        }
                    }
                }
                .formStyle(.grouped)
            }
            Tab("API Key", systemImage: "key") {
                Form {
                    Section("Anthropic API key") {
                        LabeledContent("Status", value: settings.hasKey ? "Stored in Keychain" : "Not set")
                        SecureField("sk-ant-...", text: $settings.apiKey)
                        HStack {
                            Button("Save key") { settings.saveKey(model: model) }
                                .disabled(settings.apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button("Remove key", role: .destructive) { settings.deleteKey(model: model) }
                                .disabled(!settings.hasKey)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if let problem = settings.problems.first {
                    Text(problem).font(.caption).foregroundStyle(.red)
                } else if let message = settings.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { settings.revert() }.disabled(!settings.isDirty)
                Button("Save") { settings.save(home: model.paths.home, model: model) }
                    .keyboardShortcut("s")
                    .disabled(!settings.isDirty || !settings.problems.isEmpty)
            }
            .padding()
            .background(.bar)
        }
    }

    private func modelPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            // Keep a hand-edited model id selectable instead of silently replacing it.
            ForEach(Array(Set(SettingsModel.modelChoices + [selection.wrappedValue])).sorted(), id: \.self) { Text($0).tag($0) }
        }
    }
}
