import Foundation

/// Mirrors `thinking.block_binding.prefix_mismatch_behavior`.
public enum MismatchPolicy: String, CaseIterable, Sendable {
    /// Reject the whole request with a 400.
    case error
    /// Drop the invalid blocks and report them in `input_transformations`.
    case dropBlock = "drop_block"
}

/// One entry of the `input_transformations` array.
public struct InputTransformation: Hashable, Sendable {
    public enum Reason: String, Sendable {
        /// Something before the block changed.
        case prefixMismatch = "prefix_mismatch"
        /// An earlier thinking block that was present at signing time is gone.
        case chainBroken = "chain_broken"
        /// The block was produced by a newer model than the one requested.
        case modelMismatch = "model_mismatch"
    }

    public let position: BlockPosition
    public let blockID: String
    public let reason: Reason
}

public enum ValidationOutcome: Sendable {
    /// The request as the API would forward it to the model.
    case accepted(Request, transformations: [InputTransformation])
    /// HTTP 400. `firstInvalid` is the block that tripped the check.
    case rejected(status: Int, message: String, firstInvalid: BlockPosition)

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    public var transformations: [InputTransformation] {
        if case let .accepted(_, t) = self { return t }
        return []
    }
}

/// Stateless re-implementation of the server-side check. It needs nothing but
/// the request bytes, which is the point: the ledger cannot lie to it.
public struct PrefixValidator: Sendable {
    public var currentModel: ModelVersion
    public var policy: MismatchPolicy

    public init(currentModel: ModelVersion = .fable51, policy: MismatchPolicy = .error) {
        self.currentModel = currentModel
        self.policy = policy
    }

    public func validate(_ request: Request) -> ValidationOutcome {
        var transformations: [InputTransformation] = []
        var invalidFrom: BlockPosition?
        var previousReadableSignature: String?
        var anyEarlierPresent = false

        for (m, b, block) in request.thinkingBlocks {
            let position = BlockPosition(messageIndex: m, blockIndex: b)

            // 1. Model check: always a silent drop, never a 400, policy ignored.
            if block.producedBy > currentModel {
                transformations.append(.init(position: position, blockID: block.id, reason: .modelMismatch))
                continue
            }

            // 2. Once a block is invalid, every later block is invalid too.
            if invalidFrom != nil {
                transformations.append(.init(position: position, blockID: block.id, reason: .prefixMismatch))
                continue
            }

            guard let parts = PrefixFingerprint.components(of: block.signature) else {
                invalidFrom = position
                transformations.append(.init(position: position, blockID: block.id, reason: .prefixMismatch))
                continue
            }

            let expectedPrefix = PrefixFingerprint.prefixHash(of: request, before: position)
            if parts.prefix != expectedPrefix {
                invalidFrom = position
                transformations.append(.init(position: position, blockID: block.id, reason: .prefixMismatch))
                continue
            }

            // 3. Chain check only when an earlier thinking block is still present.
            //    Trimming *all* earlier thinking blocks is the documented
            //    "remove from the start of the history" allowance.
            if anyEarlierPresent {
                let expectedChain = PrefixFingerprint.sign(prefixHash: expectedPrefix,
                                                           previousSignature: previousReadableSignature)
                if expectedChain != block.signature {
                    invalidFrom = position
                    transformations.append(.init(position: position, blockID: block.id, reason: .chainBroken))
                    continue
                }
            }

            anyEarlierPresent = true
            previousReadableSignature = block.signature
        }

        let hardFailure = transformations.first { $0.reason != .modelMismatch }
        if let failure = hardFailure, policy == .error {
            let message = "Invalid `signature` in `thinking` block at message \(failure.position.messageIndex): "
                + "the system prompt, tools, or an earlier message changed since this block was produced "
                + "(reason: \(failure.reason.rawValue))."
            return .rejected(status: 400, message: message, firstInvalid: failure.position)
        }

        // drop_block: strip every transformed block and forward the rest.
        let dropped = Set(transformations.map(\.position))
        var forwarded = request
        for m in forwarded.messages.indices {
            forwarded.messages[m].blocks = forwarded.messages[m].blocks.enumerated().compactMap { b, block in
                dropped.contains(BlockPosition(messageIndex: m, blockIndex: b)) ? nil : block
            }
        }
        return .accepted(forwarded, transformations: transformations)
    }
}
