import Foundation

// MARK: - Request shape
//
// A deliberately small mirror of the Messages API request: a top-level system
// prompt, a tool list, and an ordered message array. Everything a thinking
// block is bound to lives in these three fields.

public enum Role: String, Codable, Hashable, Sendable {
    case user, assistant, system
}

/// A model generation, ordered. Newer models read older models' thinking; the
/// reverse is dropped by the API without an error.
public struct ModelVersion: Codable, Hashable, Sendable, Comparable {
    public let name: String
    public let rank: Int

    public init(name: String, rank: Int) {
        self.name = name
        self.rank = rank
    }

    public static func < (lhs: ModelVersion, rhs: ModelVersion) -> Bool { lhs.rank < rhs.rank }

    public static let opus5 = ModelVersion(name: "claude-opus-5", rank: 50)
    public static let fable51 = ModelVersion(name: "claude-fable-5-1", rank: 51)
}

public enum Effort: String, Codable, Hashable, Sendable, CaseIterable {
    case low, medium, high, xhigh, max
}

public struct ToolDefinition: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    /// A tool declared with `defer_loading: true` is invisible to the prefix
    /// check until a `tool_addition` block references it.
    public var deferLoading: Bool

    public init(name: String, description: String, deferLoading: Bool = false) {
        self.name = name
        self.description = description
        self.deferLoading = deferLoading
    }
}

/// A thinking block as the API returns it: opaque reasoning plus a signature.
/// Here the signature *is* the SHA-256 of the prefix the block was produced
/// against, which is exactly the property the real API checks.
public struct ThinkingBlock: Codable, Hashable, Sendable {
    public let id: String
    public let summary: String
    public let signature: String
    public let producedBy: ModelVersion

    public init(id: String, summary: String, signature: String, producedBy: ModelVersion) {
        self.id = id
        self.summary = summary
        self.signature = signature
        self.producedBy = producedBy
    }
}

public enum Block: Codable, Hashable, Sendable {
    case text(String)
    case thinking(ThinkingBlock)
    case toolUse(id: String, name: String, input: String)
    case toolResult(toolUseID: String, content: String)
    /// Mid-conversation tool changes: append, never edit `tools`.
    case toolAddition(name: String)
    case toolRemoval(name: String)
    /// Per-message effort: an `output_config` on a system message.
    case effort(Effort)

    public var isThinking: Bool {
        if case .thinking = self { return true }
        return false
    }
}

public enum ClearAt: String, Codable, Hashable, Sendable {
    case nextUserMessage = "next_user_message"
}

public struct Message: Codable, Hashable, Sendable {
    public var role: Role
    public var blocks: [Block]
    /// Only meaningful on `system` messages. A turn-scoped reminder renders
    /// once, then stays in history at no token cost. It is still part of the
    /// prefix: leave it in place and it's valid; delete or reword it and every
    /// later thinking block is invalid.
    public var clearAt: ClearAt?

    public init(role: Role, blocks: [Block], clearAt: ClearAt? = nil) {
        self.role = role
        self.blocks = blocks
        self.clearAt = clearAt
    }

    public static func user(_ text: String) -> Message {
        Message(role: .user, blocks: [.text(text)])
    }
}

public struct Request: Codable, Hashable, Sendable {
    public var system: String
    public var tools: [ToolDefinition]
    public var messages: [Message]

    public init(system: String, tools: [ToolDefinition], messages: [Message]) {
        self.system = system
        self.tools = tools
        self.messages = messages
    }

    /// Every thinking block with its coordinates, in order.
    public var thinkingBlocks: [(messageIndex: Int, blockIndex: Int, block: ThinkingBlock)] {
        var out: [(Int, Int, ThinkingBlock)] = []
        for (m, message) in messages.enumerated() {
            for (b, block) in message.blocks.enumerated() {
                if case let .thinking(t) = block { out.append((m, b, t)) }
            }
        }
        return out
    }
}
