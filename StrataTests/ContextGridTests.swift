import Testing
import Foundation
@testable import Strata

struct ContextGridZoomTests {
    @Test func underAQuarterOfTheWindowTheGridZoomsToAboutTwiceWhatIsUsed() {
        #expect(ContextGrid.range(used: 30_000, window: 1_048_576) == 65_536)
        #expect(ContextGrid.range(used: 200_000, window: 2_097_152) == 524_288)
        #expect(ContextGrid.range(used: 16_384, window: 262_144) == 32_768) // exactly twice fits
        #expect(ContextGrid.range(used: 16_385, window: 262_144) == 65_536)
        #expect(ContextGrid.range(used: 0, window: 262_144) == 32_768)
    }

    @Test func fromAQuarterOnTheGridShowsTheWholeWindow() {
        #expect(ContextGrid.range(used: 92_000, window: 262_144) == 262_144)
        #expect(ContextGrid.range(used: 65_536, window: 262_144) == 262_144)
        #expect(ContextGrid.range(used: 300_000, window: 262_144) == 262_144)
    }

    @Test func theZoomNeverExceedsTheWindow() {
        #expect(ContextGrid.range(used: 1000, window: 20_000) == 20_000) // 32k would be larger than the window
        #expect(ContextGrid.range(used: 40_000, window: 200_000) == 131_072)
        #expect(ContextGrid.range(used: 49_000, window: 200_000) == 131_072)
        #expect(ContextGrid.range(used: 50_000, window: 200_000) == 200_000) // a quarter: the whole window
        #expect(ContextGrid.range(used: 10, window: 0) == 0)
    }

    @Test func sizesReadAsPowersOfTwoWhenTheyAreOne() {
        #expect(ContextGrid.sizeLabel(262_144) == "256k")
        #expect(ContextGrid.sizeLabel(1_048_576) == "1M")
        #expect(ContextGrid.sizeLabel(32_768) == "32k")
        #expect(ContextGrid.sizeLabel(200_000) == "200k")
        #expect(ContextGrid.tokensPerCell(range: 262_144) == 1311)
    }
}

struct ContextGridAllocationTests {
    private func counts(_ owners: [Int], _ n: Int = 6) -> [Int] {
        (0..<n).map { c in owners.filter { $0 == c }.count }
    }

    @Test func cellsAreGroupedInCategoryOrder() {
        let owners = ContextGrid.allocate([2_000, 0, 5_000, 3_000, 0, 0], range: 200_000) // 1000 per cell
        #expect(owners == [0, 0] + Array(repeating: 2, count: 5) + [3, 3, 3])
    }

    @Test func everyPresentCategoryGetsAtLeastOneCell() {
        let owners = ContextGrid.allocate([10, 0, 1_000, 0, 0, 3], range: 200_000)
        #expect(counts(owners) == [1, 0, 1, 0, 0, 1])
    }

    @Test func leftoverCellsGoByLargestRemainder() {
        // Exact cells 1.2, 2.7, 1.1: floors make 4 of 5, and the one left goes to the largest remainder (0.7).
        #expect(counts(ContextGrid.allocate([1_200, 2_700, 1_100], range: 200_000), 3) == [1, 3, 1])
        // Ties go to the earlier category.
        #expect(counts(ContextGrid.allocate([1_500, 2_500, 1_000], range: 200_000), 3) == [2, 2, 1])
    }

    @Test func theTotalIsExactlyTheUsedCells() {
        let cases: [([Int], Int)] = [
            ([2_400, 1_900, 18_600, 61_200, 4_300, 3_100], 262_144),
            ([2_400, 1_900, 18_600, 61_200, 4_300, 3_100], 131_072),
            ([333, 333, 333, 333, 333, 333], 32_768),
            ([7_777, 0, 12_345, 99_999, 1, 0], 1_048_576),
        ]
        for (tokens, range) in cases {
            let per = Double(range) / 200
            let used = tokens.reduce(0, +)
            let present = tokens.filter { $0 > 0 }.count
            let want = min(200, max(present, Int((Double(used) / per).rounded())))
            let owners = ContextGrid.allocate(tokens, range: range)
            #expect(owners.count == want)
            #expect(owners == owners.sorted()) // grouped
            for (i, t) in tokens.enumerated() { #expect((counts(owners)[i] > 0) == (t > 0)) }
        }
    }

    @Test func theMinimumCellsCanPushPastTheRoundedTotalOnlyWhenTheyMust() {
        // Five tiny categories and one of 10 cells: the minimum would make 15, so the big one gives back 5.
        let owners = ContextGrid.allocate([1, 1, 1, 1, 1, 100_000], range: 2_000_000)
        #expect(counts(owners) == [1, 1, 1, 1, 1, 5])
        // More present categories than the rounded total: one cell each, no fewer.
        #expect(ContextGrid.allocate([1, 1, 1, 0, 0, 0], range: 2_000_000) == [0, 1, 2])
    }

    @Test func aFullWindowFillsTheGridAndNoMore() {
        #expect(ContextGrid.allocate([50_000, 300_000], range: 262_144).count == 200)
        #expect(ContextGrid.allocate([], range: 262_144).isEmpty)
        #expect(ContextGrid.allocate([0, 0, 0], range: 262_144).isEmpty)
    }
}

struct ContextGridSummarizeTests {
    @Test func theSummarizeCellIsWhereTheLimitFalls() {
        let limit = Compaction.limit(window: 262_144, maxOutput: nil) // 235_929
        #expect(ContextGrid.summarizeCell(limit: limit, range: 262_144) == 179)
        #expect(ContextGrid.summarizeCell(limit: 90_000, range: 100_000) == 180)
    }

    @Test func noSummarizeCellWhenTheLimitIsOutsideTheShownRange() {
        #expect(ContextGrid.summarizeCell(limit: 235_929, range: 65_536) == nil)
        #expect(ContextGrid.summarizeCell(limit: 65_536, range: 65_536) == nil)
        #expect(ContextGrid.summarizeCell(limit: 0, range: 65_536) == nil)
        #expect(ContextGrid.summarizeCell(limit: 65_535, range: 65_536) == 199)
    }
}

struct ContextEstimatorTests {
    private let prose = { (n: Int) in String(repeating: "ab ", count: n / 3) } // n characters of prose

    @Test func charactersAreSortedIntoCategories() {
        let image = ContentPart.imageURL("data:image/jpeg;base64,AAAA")
        let messages: [APIMessage] = [
            .system(prose(300)),
            .user(prose(600)),
            .assistant(prose(90), toolCalls: [ToolCall(id: "c1", name: "web_search", arguments: #"{"query":"x"}"#)]),
            .tool(callID: "c1", content: prose(1_200)),
            .user(parts: [image, image, .text(prose(30))]),
            .assistant(prose(150)),
        ]
        let c = ContextEstimator.chars(messages: messages, toolsJSON: nil)
        #expect(c[ContextCategory.system.rawValue] == 300)
        #expect(c[ContextCategory.tools.rawValue] == 0)
        #expect(c[ContextCategory.messages.rawValue] == 600 + 90 + 30 + 150)
        #expect(c[ContextCategory.web.rawValue] == 1_200 + "web_search".count + #"{"query":"x"}"#.count)
        #expect(c[ContextCategory.reasoning.rawValue] == 0) // reasoning is never sent back
        #expect(c[ContextCategory.images.rawValue] == 2 * Compaction.imageChars)
        // The categories add up to compaction's own estimate of the same messages.
        #expect(c.reduce(0, +) == Compaction.chars(messages))
    }

    @Test func toolDefinitionsCountOnlyWhenSent() {
        #expect(ContextEstimator.toolsJSON(nil) == nil)
        #expect(ContextEstimator.toolsJSON([]) == nil)
        let json = try! #require(ContextEstimator.toolsJSON(ToolDefinition.standard))
        #expect(json.contains("web_search") && json.contains("web_fetch"))
        let c = ContextEstimator.chars(messages: [.user("hi")], toolsJSON: json)
        #expect(c[ContextCategory.tools.rawValue] == Compaction.estimateChars(json))
    }

    @Test func theSplitIsScaledToTheRealTotalExactly() {
        let split = ContextEstimator.scale([1_000, 0, 3_000, 6_000, 0, 0], to: 25_000)
        #expect(split == [2_500, 0, 7_500, 15_000, 0, 0])
        for total in [1, 7, 999, 92_123] {
            let s = ContextEstimator.scale([333, 17, 4_001, 9_999, 0, 765 * 4], to: total)
            #expect(s.reduce(0, +) == total)
            #expect(s[4] == 0) // an absent category stays absent
        }
    }

    @Test func withNoEstimateEverythingCountsAsMessages() {
        #expect(ContextEstimator.scale([0, 0, 0, 0, 0, 0], to: 500) == [0, 0, 500, 0, 0, 0])
        #expect(ContextEstimator.scale([10, 0, 0, 0, 0, 0], to: 0) == [0, 0, 0, 0, 0, 0])
    }

    @Test func splitCombinesTheEstimateAndTheScaling() {
        let s = ContextEstimator.split(messages: [.system(prose(300)), .user(prose(300))], tools: nil, total: 1_000)
        #expect(s == [500, 0, 500, 0, 0, 0])
    }
}
