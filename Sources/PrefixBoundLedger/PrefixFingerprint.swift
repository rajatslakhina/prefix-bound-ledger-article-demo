import Foundation

/// Position of a block inside a request.
public struct BlockPosition: Hashable, Sendable, Comparable {
    public let messageIndex: Int
    public let blockIndex: Int

    public init(messageIndex: Int, blockIndex: Int) {
        self.messageIndex = messageIndex
        self.blockIndex = blockIndex
    }

    public static func < (lhs: BlockPosition, rhs: BlockPosition) -> Bool {
        (lhs.messageIndex, lhs.blockIndex) < (rhs.messageIndex, rhs.blockIndex)
    }
}

/// Builds the canonical prefix a thinking block is bound to and hashes it.
///
/// Two modelling decisions, both taken straight from the documented
/// valid/invalid table:
///
/// 1. Thinking blocks are *not* part of the hashed prefix. Their presence is
///    enforced separately by a chain link (see `sign`), which is what lets
///    "remove thinking blocks from the start of the history" stay valid while
///    "remove one from the middle" invalidates every later block.
/// 2. A tool declared with `defer_loading: true` is left out of the prefix
///    until a `tool_addition` block that names it appears *before* the block
///    being signed.
public enum PrefixFingerprint {
    public static let genesis = "genesis"

    /// Canonical text of everything before `position`.
    public static func canonicalPrefix(of request: Request, before position: BlockPosition) -> String {
        var referenced = Set<String>()
        var lines: [String] = []
        lines.append("system:\(request.system)")

        // Messages first, so we know which deferred tools were referenced.
        var messageLines: [String] = []
        for (m, message) in request.messages.enumerated() {
            guard m <= position.messageIndex else { break }
            let limit = m == position.messageIndex ? position.blockIndex : message.blocks.count
            guard limit >= 0 else { continue }
            var parts: [String] = ["role=\(message.role.rawValue)"]
            if let clear = message.clearAt { parts.append("clear_at=\(clear.rawValue)") }
            for (b, block) in message.blocks.enumerated() {
                guard b < limit else { break }
                switch block {
                case .text(let t): parts.append("text=\(t)")
                case .thinking: continue
                case let .toolUse(id, name, input): parts.append("tool_use=\(id)/\(name)/\(input)")
                case let .toolResult(id, content): parts.append("tool_result=\(id)/\(content)")
                case .toolAddition(let name):
                    referenced.insert(name)
                    parts.append("tool_addition=\(name)")
                case .toolRemoval(let name): parts.append("tool_removal=\(name)")
                case .effort(let e): parts.append("effort=\(e.rawValue)")
                }
            }
            messageLines.append("message[\(m)]:" + parts.joined(separator: "|"))
        }

        for tool in request.tools where !tool.deferLoading || referenced.contains(tool.name) {
            lines.append("tool:\(tool.name)/\(tool.description)/deferred=\(tool.deferLoading)")
        }
        lines.append(contentsOf: messageLines)
        return lines.joined(separator: "\n")
    }

    public static func prefixHash(of request: Request, before position: BlockPosition) -> String {
        SHA256.hexDigest(canonicalPrefix(of: request, before: position))
    }

    /// A signature is `prefixHash.chainHash`. The chain hash binds the block
    /// to the previous thinking block's signature (or `genesis`).
    public static func sign(prefixHash: String, previousSignature: String?) -> String {
        let chain = SHA256.hexDigest(prefixHash + "|" + (previousSignature ?? genesis))
        return prefixHash + "." + chain
    }

    public static func components(of signature: String) -> (prefix: String, chain: String)? {
        let parts = signature.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// Short display form for UI chips.
    public static func short(_ signature: String) -> String {
        String(signature.prefix(8))
    }
}
