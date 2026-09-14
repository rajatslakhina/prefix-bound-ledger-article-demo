import XCTest
@testable import PrefixBoundLedger

final class PrefixBoundLedgerTests: XCTestCase {

    // MARK: SHA-256 sanity

    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256.hexDigest(""),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hexDigest("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Two-block message (56 bytes forces padding into a second chunk).
        XCTAssertEqual(SHA256.hexDigest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    // MARK: Ledger invariants

    func testFixtureHasFourSignedBlocksThatAllValidate() {
        let ledger = Fixture.ledger()
        XCTAssertEqual(ledger.thinkingBlockCount, 4)
        let outcome = PrefixValidator(policy: .error).validate(ledger.request)
        XCTAssertTrue(outcome.isAccepted)
        XCTAssertTrue(outcome.transformations.isEmpty)
    }

    func testEverySanctionedMutationKeepsAllBlocksValid() throws {
        let mutations: [Mutation] = [
            .userMessage("One more thing."),
            .systemMessage("From now on use metric."),
            .turnScopedReminder("Short answer this turn."),
            .toolAddition("export_csv"),
            .toolRemoval("get_history"),
            .effort(.low),
        ]
        for mutation in mutations {
            var ledger = Fixture.ledger()
            try ledger.apply(mutation)
            let outcome = PrefixValidator(policy: .error).validate(ledger.request)
            XCTAssertTrue(outcome.isAccepted, "\(mutation.label) should not invalidate any block")
            XCTAssertTrue(outcome.transformations.isEmpty, "\(mutation.label) dropped blocks")
        }
    }

    func testDeclaringDeferredToolIsSafeUntilOffered() throws {
        var ledger = Fixture.ledger()
        ledger.declareDeferredTool(ToolDefinition(name: "share", description: "Share"))
        XCTAssertTrue(PrefixValidator().validate(ledger.request).isAccepted)

        // Offering it appends a tool_addition block; earlier blocks stay valid
        // because the tool only enters the prefix *after* that block.
        try ledger.apply(.toolAddition("share"))
        let outcome = PrefixValidator().validate(ledger.request)
        XCTAssertTrue(outcome.isAccepted)
        XCTAssertTrue(outcome.transformations.isEmpty)

        // A block signed after the addition binds to the now-visible tool.
        ledger.recordAssistantTurn(thinking: "Offer share.", blocks: [.text("You can share now.")])
        var tampered = ledger.request
        if let index = tampered.tools.firstIndex(where: { $0.name == "share" }) {
            tampered.tools[index].description = "Share (edited)"
        }
        let tamperedOutcome = PrefixValidator(policy: .dropBlock).validate(tampered)
        XCTAssertEqual(tamperedOutcome.transformations.count, 1)
        XCTAssertEqual(tamperedOutcome.transformations.first?.blockID, "think_5")
    }

    func testLedgerRejectsMisusedToolMutations() {
        var ledger = Fixture.ledger()
        XCTAssertThrowsError(try ledger.apply(.toolAddition("nope"))) { error in
            XCTAssertEqual(error as? LedgerError, .unknownTool("nope"))
        }
        XCTAssertThrowsError(try ledger.apply(.toolAddition("log_workout"))) { error in
            XCTAssertEqual(error as? LedgerError, .toolNotDeferred("log_workout"))
        }
        XCTAssertNoThrow(try ledger.apply(.toolAddition("export_csv")))
        XCTAssertThrowsError(try ledger.apply(.toolAddition("export_csv"))) { error in
            XCTAssertEqual(error as? LedgerError, .toolAlreadyOffered("export_csv"))
        }
    }

    // MARK: Validator vs the documented table

    func testAuditAgreesWithDocumentedTableOnEveryRow() {
        let rows = EditAudit.run(on: Fixture.ledger().request)
        XCTAssertEqual(rows.count, NaiveEdit.allCases.count)
        for row in rows {
            XCTAssertTrue(row.agrees,
                          "\(row.edit.title): documented \(row.documented) but observed \(row.observedVerdict)")
        }
        XCTAssertEqual(rows.filter { $0.documented == .invalid }.count, 7)
        XCTAssertEqual(rows.filter { $0.documented == .valid }.count, 4)
    }

    func testChangingSystemPromptInvalidatesEveryBlockAndReturns400() {
        let edited = NaiveEdit.changeSystemPrompt.apply(to: Fixture.ledger().request)
        let outcome = PrefixValidator(policy: .error).validate(edited)
        guard case let .rejected(status, message, first) = outcome else {
            return XCTFail("expected a 400")
        }
        XCTAssertEqual(status, 400)
        XCTAssertEqual(first, BlockPosition(messageIndex: 1, blockIndex: 0))
        XCTAssertTrue(message.contains("prefix_mismatch"))

        let dropped = PrefixValidator(policy: .dropBlock).validate(edited)
        XCTAssertEqual(dropped.transformations.count, 4)
        XCTAssertTrue(dropped.transformations.allSatisfy { $0.reason == .prefixMismatch })
    }

    func testRewordingLaterMessageOnlyInvalidatesLaterBlocks() {
        var edited = Fixture.ledger().request
        // Message 5 is the second user question; blocks 1 and 2 precede it.
        edited.messages[5].blocks = [.text("(edited) compare please")]
        let outcome = PrefixValidator(policy: .dropBlock).validate(edited)
        XCTAssertEqual(outcome.transformations.map(\.blockID), ["think_3", "think_4"])
        if case let .accepted(forwarded, _) = outcome {
            XCTAssertEqual(forwarded.thinkingBlocks.count, 2)
        } else {
            XCTFail("drop_block must accept")
        }
    }

    func testStrippingLeadingThinkingIsAllowedButMiddleIsNot() {
        let leading = NaiveEdit.stripLeadingThinking.apply(to: Fixture.ledger().request)
        XCTAssertTrue(PrefixValidator().validate(leading).transformations.isEmpty)

        let middle = NaiveEdit.stripMiddleThinking.apply(to: Fixture.ledger().request)
        let outcome = PrefixValidator(policy: .dropBlock).validate(middle)
        XCTAssertEqual(outcome.transformations.map(\.reason), [.chainBroken, .prefixMismatch])
        XCTAssertEqual(outcome.transformations.map(\.blockID), ["think_3", "think_4"])
    }

    func testOlderModelDropsNewerBlocksSilentlyEvenUnderErrorPolicy() {
        let request = Fixture.ledger(model: .fable51).request
        let outcome = PrefixValidator(currentModel: .opus5, policy: .error).validate(request)
        XCTAssertTrue(outcome.isAccepted, "model mismatch is a drop, never a 400")
        XCTAssertEqual(outcome.transformations.count, 4)
        XCTAssertTrue(outcome.transformations.allSatisfy { $0.reason == .modelMismatch })
    }

    func testNewerModelReadsOlderBlocks() {
        let request = Fixture.ledger(model: .opus5).request
        let outcome = PrefixValidator(currentModel: .fable51).validate(request)
        XCTAssertTrue(outcome.transformations.isEmpty)
    }

    // MARK: Edge cases

    func testEmptyLedgerValidates() {
        let ledger = ConversationLedger(system: "s", tools: [])
        XCTAssertTrue(PrefixValidator().validate(ledger.request).isAccepted)
        XCTAssertTrue(EditAudit.run(on: ledger.request).allSatisfy { $0.observedVerdict == .valid })
    }

    func testMalformedSignatureIsRejected() {
        var request = Fixture.ledger().request
        request.messages[1].blocks[0] = .thinking(
            ThinkingBlock(id: "bad", summary: "", signature: "not-a-signature", producedBy: .fable51))
        guard case .rejected = PrefixValidator(policy: .error).validate(request) else {
            return XCTFail("malformed signature must be rejected")
        }
    }
}
