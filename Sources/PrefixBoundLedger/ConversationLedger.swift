import Foundation

/// The only ways a committed conversation may change. Every case is an
/// *append*; none of them touch `system`, `tools`, or an earlier message.
public enum Mutation: Hashable, Sendable {
    case userMessage(String)
    /// New standing instructions, delivered as a mid-conversation system
    /// message instead of an edit to the top-level `system` prompt.
    case systemMessage(String)
    /// A per-turn reminder with `clear_at: "next_user_message"`.
    case turnScopedReminder(String)
    /// Offer a tool that was declared with `defer_loading: true`.
    case toolAddition(String)
    case toolRemoval(String)
    /// Per-message effort via `output_config` on a system message.
    case effort(Effort)

    public var label: String {
        switch self {
        case .userMessage: return "Append user message"
        case .systemMessage: return "Append system message"
        case .turnScopedReminder: return "Turn-scoped reminder"
        case .toolAddition(let n): return "tool_addition(\(n))"
        case .toolRemoval(let n): return "tool_removal(\(n))"
        case .effort(let e): return "effort → \(e.rawValue)"
        }
    }
}

public enum LedgerError: Error, Equatable {
    case unknownTool(String)
    case toolNotDeferred(String)
    case toolAlreadyOffered(String)
}

/// An append-only conversation store that signs thinking blocks against the
/// prefix they were produced under. There is deliberately no API for editing
/// `system`, `tools`, or a committed message.
public struct ConversationLedger: Sendable {
    public private(set) var request: Request
    public let model: ModelVersion
    private var offeredDeferredTools: Set<String> = []
    private var nextThinkingID = 1

    public init(system: String, tools: [ToolDefinition], model: ModelVersion = .fable51) {
        self.request = Request(system: system, tools: tools, messages: [])
        self.model = model
    }

    public var messages: [Message] { request.messages }

    // MARK: Appends

    public mutating func apply(_ mutation: Mutation) throws {
        switch mutation {
        case .userMessage(let text):
            request.messages.append(.user(text))
        case .systemMessage(let text):
            request.messages.append(Message(role: .system, blocks: [.text(text)]))
        case .turnScopedReminder(let text):
            request.messages.append(Message(role: .system, blocks: [.text(text)], clearAt: .nextUserMessage))
        case .toolAddition(let name):
            guard let tool = request.tools.first(where: { $0.name == name }) else {
                throw LedgerError.unknownTool(name)
            }
            guard tool.deferLoading else { throw LedgerError.toolNotDeferred(name) }
            guard !offeredDeferredTools.contains(name) else { throw LedgerError.toolAlreadyOffered(name) }
            offeredDeferredTools.insert(name)
            request.messages.append(Message(role: .system, blocks: [.toolAddition(name: name)]))
        case .toolRemoval(let name):
            guard request.tools.contains(where: { $0.name == name }) else {
                throw LedgerError.unknownTool(name)
            }
            request.messages.append(Message(role: .system, blocks: [.toolRemoval(name: name)]))
        case .effort(let level):
            request.messages.append(Message(role: .system, blocks: [.effort(level)]))
        }
    }

    /// Declaring a *deferred* tool is the one change to `tools` that leaves
    /// every existing signature valid, because the prefix check ignores it
    /// until a `tool_addition` block references it.
    public mutating func declareDeferredTool(_ tool: ToolDefinition) {
        var deferred = tool
        deferred.deferLoading = true
        request.tools.append(deferred)
    }

    /// Records an assistant turn. `thinking` becomes a signed block placed
    /// first, followed by `blocks` exactly as the model produced them.
    @discardableResult
    public mutating func recordAssistantTurn(thinking: String, blocks: [Block]) -> ThinkingBlock {
        let messageIndex = request.messages.count
        let position = BlockPosition(messageIndex: messageIndex, blockIndex: 0)
        // Append a placeholder so the prefix is computed with this message present.
        request.messages.append(Message(role: .assistant, blocks: []))
        let prefixHash = PrefixFingerprint.prefixHash(of: request, before: position)
        let previous = request.thinkingBlocks.last?.block.signature
        let signature = PrefixFingerprint.sign(prefixHash: prefixHash, previousSignature: previous)
        let block = ThinkingBlock(id: "think_\(nextThinkingID)", summary: thinking,
                                  signature: signature, producedBy: model)
        nextThinkingID += 1
        request.messages[messageIndex].blocks = [.thinking(block)] + blocks
        return block
    }

    /// Appends a tool result for the most recent `tool_use`.
    public mutating func recordToolResult(toolUseID: String, content: String) {
        request.messages.append(Message(role: .user, blocks: [.toolResult(toolUseID: toolUseID, content: content)]))
    }

    public var thinkingBlockCount: Int { request.thinkingBlocks.count }
}
