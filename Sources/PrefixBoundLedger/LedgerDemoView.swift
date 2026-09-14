#if canImport(SwiftUI)
import SwiftUI

/// Interactive demo: a signed transcript, a policy switch, the naive edits a
/// mutable-transcript app makes, and the append-only mutation that replaces
/// each one. Every verdict on screen comes from `PrefixValidator`, not from a
/// hard-coded table.
@available(iOS 17, macOS 14, *)
public struct LedgerDemoView: View {
    @State private var ledger = Fixture.ledger()
    @State private var policy: MismatchPolicy = .error
    @State private var lastResult: ResultCard?
    @State private var selectedEdit: NaiveEdit = .rewordEarlierUserMessage

    public init() {}

    private var validator: PrefixValidator { PrefixValidator(policy: policy) }

    public var body: some View {
        NavigationStack {
            List {
                Section("Ledger — \(ledger.messages.count) entries, \(ledger.thinkingBlockCount) signed blocks") {
                    ForEach(Array(ledger.messages.enumerated()), id: \.offset) { index, message in
                        LedgerRow(index: index, message: message)
                    }
                }

                Section("prefix_mismatch_behavior") {
                    Picker("Policy", selection: $policy) {
                        ForEach(MismatchPolicy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Naive edit (what a mutable transcript does)") {
                    Picker("Edit", selection: $selectedEdit) {
                        ForEach(NaiveEdit.allCases) { Text($0.title).tag($0) }
                    }
                    Button("Send edited request") { runNaiveEdit() }
                        .buttonStyle(.borderedProminent)
                }

                Section("Sanctioned mutation (append-only)") {
                    mutationButton(.userMessage("And last month?"))
                    mutationButton(.systemMessage("From now on, answer in metric units."))
                    mutationButton(.turnScopedReminder("This turn only: under 80 words."))
                    mutationButton(.toolAddition("export_csv"))
                    mutationButton(.effort(.low))
                }

                if let card = lastResult {
                    Section("Result") { ResultCardView(card: card) }
                }

                Section("Audit: documented table vs validator") {
                    ForEach(EditAudit.run(on: ledger.request)) { row in
                        HStack {
                            Text(row.edit.title).font(.caption)
                            Spacer()
                            Text(row.observedVerdict.rawValue)
                                .font(.caption.bold())
                                .foregroundStyle(row.observedVerdict == .valid ? .green : .red)
                            Image(systemName: row.agrees ? "checkmark.seal.fill" : "xmark.seal.fill")
                                .foregroundStyle(row.agrees ? .green : .red)
                        }
                    }
                }

                Section {
                    Button("Reset ledger", role: .destructive) {
                        ledger = Fixture.ledger()
                        lastResult = nil
                    }
                }
            }
            .navigationTitle("Prefix-Bound Ledger")
        }
    }

    private func mutationButton(_ mutation: Mutation) -> some View {
        Button(mutation.label) {
            do {
                try ledger.apply(mutation)
                let outcome = validator.validate(ledger.request)
                lastResult = ResultCard(outcome: outcome, headline: "Appended: \(mutation.label)")
            } catch {
                lastResult = ResultCard(outcome: nil, headline: "Ledger refused: \(error)")
            }
        }
    }

    private func runNaiveEdit() {
        let edited = selectedEdit.apply(to: ledger.request)
        let outcome = validator.validate(edited)
        var headline = "Naive edit: \(selectedEdit.title)"
        if let replacement = selectedEdit.sanctionedReplacement, !outcome.transformations.isEmpty || !outcome.isAccepted {
            headline += "\nUse instead: \(replacement.label)"
        }
        lastResult = ResultCard(outcome: outcome, headline: headline)
    }
}

@available(iOS 17, macOS 14, *)
struct ResultCard {
    let outcome: ValidationOutcome?
    let headline: String

    var status: String {
        guard let outcome else { return "ledger error" }
        switch outcome {
        case .accepted(_, let t) where t.isEmpty: return "200 — every thinking block valid, cache prefix intact"
        case .accepted(_, let t): return "200 — \(t.count) block(s) dropped (input_transformations)"
        case let .rejected(status, _, first): return "\(status) — first invalid block at message \(first.messageIndex)"
        }
    }

    var detail: String {
        guard let outcome else { return "" }
        switch outcome {
        case .accepted(_, let t):
            return t.map { "\($0.blockID): \($0.reason.rawValue)" }.joined(separator: "\n")
        case let .rejected(_, message, _):
            return message
        }
    }

    var isGood: Bool {
        guard let outcome, case let .accepted(_, t) = outcome else { return false }
        return t.isEmpty
    }
}

@available(iOS 17, macOS 14, *)
struct ResultCardView: View {
    let card: ResultCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.headline).font(.subheadline.bold())
            Text(card.status)
                .font(.caption.monospaced())
                .foregroundStyle(card.isGood ? .green : .red)
            if !card.detail.isEmpty {
                Text(card.detail).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}

@available(iOS 17, macOS 14, *)
struct LedgerRow: View {
    let index: Int
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(index)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                Text(message.role.rawValue).font(.caption.bold())
                if message.clearAt != nil {
                    Text("clear_at").font(.caption2).padding(.horizontal, 4)
                        .background(.yellow.opacity(0.3)).clipShape(Capsule())
                }
            }
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                blockLabel(block)
            }
        }
    }

    @ViewBuilder
    private func blockLabel(_ block: Block) -> some View {
        switch block {
        case .text(let t): Text(t).font(.caption)
        case .thinking(let th):
            HStack(spacing: 4) {
                Image(systemName: "lock.fill").font(.caption2)
                Text("\(th.id) · sig \(PrefixFingerprint.short(th.signature))…")
                    .font(.caption2.monospaced())
            }.foregroundStyle(.blue)
        case let .toolUse(_, name, input): Text("tool_use \(name) \(input)").font(.caption2.monospaced())
        case let .toolResult(_, content): Text("tool_result \(content)").font(.caption2.monospaced())
        case .toolAddition(let n): Text("tool_addition \(n)").font(.caption2.monospaced()).foregroundStyle(.purple)
        case .toolRemoval(let n): Text("tool_removal \(n)").font(.caption2.monospaced()).foregroundStyle(.purple)
        case .effort(let e): Text("output_config.effort = \(e.rawValue)").font(.caption2.monospaced()).foregroundStyle(.purple)
        }
    }
}
#endif
