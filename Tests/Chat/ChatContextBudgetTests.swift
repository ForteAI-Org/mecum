import ChatCore
import Testing

struct ChatContextBudgetTests {
    @Test func latencyBudgetPrecedesLargeContextCapacity() {
        #expect(!ChatContextBudget.shouldCompact(usedTokens: 63_999, windowTokens: 258_400))
        #expect(ChatContextBudget.shouldCompact(usedTokens: 64_000, windowTokens: 258_400))
    }
    @Test func smallModelsKeepTheirEarlierCapacityLimit() {
        #expect(!ChatContextBudget.shouldCompact(usedTokens: 8_999, windowTokens: 10_000))
        #expect(ChatContextBudget.shouldCompact(usedTokens: 9_000, windowTokens: 10_000))
    }
    @Test func missingUsageDoesNotInventACompaction() {
        #expect(!ChatContextBudget.shouldCompact(usedTokens: nil, windowTokens: 10_000))
        #expect(!ChatContextBudget.shouldCompact(usedTokens: 0, windowTokens: nil))
        #expect(ChatContextBudget.shouldCompact(usedTokens: 64_000, windowTokens: nil))
    }
}
