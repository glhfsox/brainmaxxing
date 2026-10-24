import SwiftUI

/// The centre of the window while today's digest is being made: what the run is doing, how far along, a way to stop it.
struct RunProgressCard: View {
    let runner: RunController

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Text("Making today's digest").font(.subheadline).foregroundStyle(.secondary)
                Text(runner.statusLine)
                    .font(.title3.weight(.semibold))
                if let fraction = runner.progress?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack(spacing: 16) {
                    ForEach(runner.steps) { step in
                        Label(step.title, systemImage: icon(step.state))
                            .font(.callout.weight(step.state == .current ? .semibold : .regular))
                            .foregroundStyle(step.state == .pending ? .tertiary : step.state == .current ? .primary : .secondary)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .lineLimit(1)
                HStack {
                    if let started = runner.startedAt {
                        Text("Running for \(Text(started, style: .timer))").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(runner.isStopping ? "Stopping..." : "Stop") { runner.cancel() }
                        .disabled(runner.isStopping)
                        .help("Stop the run. What it already stored is kept.")
                }
                if let line = runner.lastLine, line != runner.statusLine {
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Text("A run takes 15 to 30 minutes. You can close the window; the run goes on in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 520)
        .padding(24)
    }

    private func icon(_ state: RunStep.State) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .current: "circle.inset.filled"
        case .pending: "circle"
        }
    }
}
