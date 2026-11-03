import SwiftUI

/// The tools a reply used, shown above its text. Each step expands to the exact arguments the
/// model sent and the result it got back.
struct ToolStepsView: View {
    let steps: [ToolStep]
    var running: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(steps) { step in
                ToolStepRow(step: step)
            }
            if let running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("\(running)…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct ToolStepRow: View {
    let step: ToolStep
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preface = step.preface, !preface.isEmpty {
                Text(preface)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button {
                withAnimation(.smooth(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: step.symbol)
                        .foregroundStyle(step.failed ? Theme.caution : Color.accentColor)
                        .frame(width: 18)
                    Text(step.title)
                        .font(.footnote.weight(.semibold))
                    if let subject = step.subject {
                        Text(subject)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(step.subject.map { "\(step.title): \($0)" } ?? step.title)
            .accessibilityHint(expanded ? "Hides the details." : "Shows the arguments and the result.")

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    detail("Arguments", step.argumentsJSON)
                    detail(step.failed ? "Error" : "Result", step.result)
                    Text("Took \(ByteFormat.seconds(step.duration))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.faint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
