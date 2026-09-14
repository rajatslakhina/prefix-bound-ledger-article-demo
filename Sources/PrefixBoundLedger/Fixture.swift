import Foundation

/// A small in-app assistant transcript for a running app: three tools (one
/// deferred), one turn-scoped reminder, four signed thinking blocks.
public enum Fixture {
    public static let tools: [ToolDefinition] = [
        ToolDefinition(name: "log_workout", description: "Record a workout"),
        ToolDefinition(name: "get_history", description: "Fetch recent workouts"),
        ToolDefinition(name: "export_csv", description: "Export history as CSV", deferLoading: true),
    ]

    public static let system = "You are the in-app coach for RunLog. Be brief and specific."

    public static func ledger(model: ModelVersion = .fable51) -> ConversationLedger {
        var ledger = ConversationLedger(system: system, tools: tools, model: model)
        // Fixture data is static, so these appends cannot throw; a failure
        // here would be a programming error worth surfacing loudly.
        do {
            try ledger.apply(.userMessage("Log a 5k run, 27 minutes."))
            ledger.recordAssistantTurn(
                thinking: "Distance and time are both given; call log_workout directly.",
                blocks: [.toolUse(id: "toolu_1", name: "log_workout", input: "{distance_km:5,minutes:27}")]
            )
            ledger.recordToolResult(toolUseID: "toolu_1", content: "ok, pace 5:24/km")
            ledger.recordAssistantTurn(
                thinking: "Logged. Report pace, no lecture.",
                blocks: [.text("Logged: 5 km in 27:00, 5:24/km.")]
            )
            try ledger.apply(.turnScopedReminder("This turn only: keep the answer under 80 words."))
            try ledger.apply(.userMessage("How does that compare to my last three runs?"))
            ledger.recordAssistantTurn(
                thinking: "Need history before comparing; fetch three most recent.",
                blocks: [.toolUse(id: "toolu_2", name: "get_history", input: "{limit:3}")]
            )
            ledger.recordToolResult(toolUseID: "toolu_2", content: "5:41, 5:37, 5:30 /km")
            ledger.recordAssistantTurn(
                thinking: "Steady improvement, 12s faster than the average of the last three.",
                blocks: [.text("Faster than all three: 5:24 vs 5:41, 5:37, 5:30. That's 6 s/km better than your best of them.")]
            )
        } catch {
            preconditionFailure("Fixture is static and must apply cleanly: \(error)")
        }
        return ledger
    }
}
