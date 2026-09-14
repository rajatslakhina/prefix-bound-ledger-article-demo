import Foundation

/// The edits a transcript-as-mutable-document integration makes without
/// thinking about it. Each one is applied *naively* to a request copy, then
/// run through `PrefixValidator`, so the verdict is derived, not asserted.
public enum NaiveEdit: String, CaseIterable, Sendable, Identifiable {
    case appendUserMessage
    case rewordEarlierUserMessage
    case deleteEarlierTurn
    case changeSystemPrompt
    case renameTool
    case addLiveTool
    case addDeferredTool
    case stripLeadingThinking
    case stripMiddleThinking
    case rewordTurnScopedReminder
    case changeTopLevelEffort

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appendUserMessage: return "Append a user message"
        case .rewordEarlierUserMessage: return "Reword an earlier user message"
        case .deleteEarlierTurn: return "Delete an earlier turn"
        case .changeSystemPrompt: return "Change the system prompt"
        case .renameTool: return "Rename a tool"
        case .addLiveTool: return "Add a live tool to `tools`"
        case .addDeferredTool: return "Add a deferred tool to `tools`"
        case .stripLeadingThinking: return "Strip thinking from the oldest turn"
        case .stripMiddleThinking: return "Strip thinking from a middle turn"
        case .rewordTurnScopedReminder: return "Reword a cleared reminder"
        case .changeTopLevelEffort: return "Change top-level effort"
        }
    }

    /// What the documented table says should happen.
    public var documentedVerdict: Verdict {
        switch self {
        case .appendUserMessage, .addDeferredTool, .stripLeadingThinking, .changeTopLevelEffort:
            return .valid
        case .rewordEarlierUserMessage, .deleteEarlierTurn, .changeSystemPrompt,
             .renameTool, .addLiveTool, .stripMiddleThinking, .rewordTurnScopedReminder:
            return .invalid
        }
    }

    /// The append-only path that achieves the same intent.
    public var sanctionedReplacement: Mutation? {
        switch self {
        case .rewordEarlierUserMessage, .deleteEarlierTurn:
            return .userMessage("Correction: ignore my earlier ask, do X instead.")
        case .changeSystemPrompt:
            return .systemMessage("From now on, answer in metric units.")
        case .renameTool, .addLiveTool:
            return .toolAddition("export_csv")
        case .rewordTurnScopedReminder:
            return .turnScopedReminder("Reminder for this turn only: keep it under 80 words.")
        case .stripMiddleThinking:
            return nil // trimming belongs to server-side compaction, not the client
        case .appendUserMessage, .addDeferredTool, .stripLeadingThinking, .changeTopLevelEffort:
            return nil
        }
    }

    public enum Verdict: String, Sendable {
        case valid, invalid
    }

    /// Applies the edit to a copy of `request`. Edits that need a target that
    /// does not exist (for example no middle thinking block) return the
    /// request unchanged, which is itself a valid "no-op".
    public func apply(to request: Request) -> Request {
        var edited = request
        let thinking = request.thinkingBlocks
        switch self {
        case .appendUserMessage:
            edited.messages.append(.user("And what about last week?"))

        case .rewordEarlierUserMessage:
            if let index = edited.messages.firstIndex(where: { $0.role == .user }) {
                edited.messages[index].blocks = [.text("(edited) " + Self.firstText(in: edited.messages[index]))]
            }

        case .deleteEarlierTurn:
            if edited.messages.count > 2 {
                edited.messages.remove(at: 1)
            }

        case .changeSystemPrompt:
            edited.system += "\nAlways answer in metric units."

        case .renameTool:
            if let index = edited.tools.firstIndex(where: { !$0.deferLoading }) {
                edited.tools[index].name += "_v2"
            }

        case .addLiveTool:
            edited.tools.append(ToolDefinition(name: "delete_history", description: "Wipe workout history"))

        case .addDeferredTool:
            edited.tools.append(ToolDefinition(name: "share_summary", description: "Share a summary", deferLoading: true))

        case .stripLeadingThinking:
            if let first = thinking.first {
                edited.messages[first.messageIndex].blocks.remove(at: first.blockIndex)
            }

        case .stripMiddleThinking:
            if thinking.count >= 3 {
                let middle = thinking[1]
                edited.messages[middle.messageIndex].blocks.remove(at: middle.blockIndex)
            }

        case .rewordTurnScopedReminder:
            if let index = edited.messages.firstIndex(where: { $0.clearAt != nil }) {
                edited.messages[index].blocks = [.text("Reminder (reworded).")]
            }

        case .changeTopLevelEffort:
            // Top-level effort lives outside system/tools/messages; nothing in
            // the signed prefix moves.
            break
        }
        return edited
    }

    private static func firstText(in message: Message) -> String {
        for block in message.blocks {
            if case .text(let t) = block { return t }
        }
        return ""
    }
}

/// One row of the audit: what the docs say, what the validator says, and the
/// append-only replacement when the naive edit is rejected.
public struct AuditRow: Identifiable, Sendable {
    public let edit: NaiveEdit
    public let documented: NaiveEdit.Verdict
    public let observed: ValidationOutcome
    public let replacement: Mutation?

    public var id: String { edit.id }

    public var observedVerdict: NaiveEdit.Verdict {
        switch observed {
        case .accepted(_, let transformations):
            return transformations.contains { $0.reason != .modelMismatch } ? .invalid : .valid
        case .rejected:
            return .invalid
        }
    }

    public var agrees: Bool { documented == observedVerdict }
}

public enum EditAudit {
    public static func run(on request: Request,
                           validator: PrefixValidator = PrefixValidator(policy: .error)) -> [AuditRow] {
        NaiveEdit.allCases.map { edit in
            AuditRow(edit: edit,
                     documented: edit.documentedVerdict,
                     observed: validator.validate(edit.apply(to: request)),
                     replacement: edit.sanctionedReplacement)
        }
    }
}
