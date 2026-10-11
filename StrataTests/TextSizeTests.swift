import Testing
import SwiftUI
import UIKit
@testable import Strata

@MainActor
struct TextSizeTests {
    private func settings(_ values: [String: Any] = [:]) -> (AppSettings, UserDefaults) {
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        for (k, v) in values { defaults.set(v, forKey: k) }
        return (AppSettings(defaults: defaults), defaults)
    }

    @Test func sevenStepsMapToXSmallThroughXXXLarge() {
        #expect(TextSizeSetting.sizes == [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge])
        #expect(TextSizeSetting.sizes.count == 7)
        #expect(TextSizeSetting.size(forStep: 0) == .xSmall)
        #expect(TextSizeSetting.size(forStep: 3) == .large)
        #expect(TextSizeSetting.size(forStep: 6) == .xxxLarge)
        #expect(TextSizeSetting.sizes[TextSizeSetting.defaultStep] == .large) // the system default size
    }

    @Test func stepsOutsideTheRangeAreClamped() {
        #expect(TextSizeSetting.size(forStep: -4) == .xSmall)
        #expect(TextSizeSetting.size(forStep: 99) == .xxxLarge)
        #expect(TextSizeSetting.clamped(7) == 6 && TextSizeSetting.clamped(-1) == 0)
    }

    @Test func theSystemSizeIsTheDefaultAndSetsNoOverride() {
        let (s, _) = settings()
        #expect(s.useSystemTextSize)
        #expect(s.textSizeStep == 3)
        #expect(s.dynamicTypeOverride == nil)
    }

    @Test func aChosenSizeBecomesTheOverrideAndTheSystemOneGivesItBack() {
        let (s, _) = settings()
        s.useSystemTextSize = false
        s.textSizeStep = 6
        #expect(s.dynamicTypeOverride == .xxxLarge)
        s.textSizeStep = 0
        #expect(s.dynamicTypeOverride == .xSmall)
        s.useSystemTextSize = true // accessibility sizes follow the system only in this mode
        #expect(s.dynamicTypeOverride == nil)
    }

    @Test func theChoiceIsPersisted() {
        let (s, defaults) = settings()
        s.useSystemTextSize = false
        s.textSizeStep = 5
        let reloaded = AppSettings(defaults: defaults)
        #expect(!reloaded.useSystemTextSize)
        #expect(reloaded.textSizeStep == 5)
        #expect(reloaded.dynamicTypeOverride == .xxLarge)
    }

    @Test func aDamagedStoredStepIsClamped() {
        let (s, _) = settings(["useSystemTextSize": false, "textSizeStep": 42])
        #expect(s.textSizeStep == 6)
    }

    @Test func launchArgumentStringsAreUnderstood() {
        // `-useSystemTextSize NO -textSizeStep 0` arrive as strings.
        let (s, _) = settings(["useSystemTextSize": "NO", "textSizeStep": "0"])
        #expect(!s.useSystemTextSize && s.textSizeStep == 0)
    }

    @Test func theTypeScaleFollowsTheSystemBodySizes() {
        #expect(DS.typeScale(.large) == 1)
        #expect(DS.typeScale(.xSmall) == 14.0 / 17)
        #expect(DS.typeScale(.xxxLarge) == 23.0 / 17)
        let sizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge, .accessibility1, .accessibility3, .accessibility5]
        let scales = sizes.map(DS.typeScale)
        #expect(scales == scales.sorted() && Set(scales).count == scales.count)
    }

    @Test func eachSizeMapsToItsUIKitCategory() {
        #expect(TextSizeOverride.contentSizeCategory(.xSmall) == .extraSmall)
        #expect(TextSizeOverride.contentSizeCategory(.large) == .large)
        #expect(TextSizeOverride.contentSizeCategory(.xxxLarge) == .extraExtraExtraLarge)
        // The scale table agrees with UIKit's own body sizes.
        for size in TextSizeSetting.sizes {
            let trait = UITraitCollection(preferredContentSizeCategory: TextSizeOverride.contentSizeCategory(size))
            let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: trait).pointSize
            #expect(abs(body / 17 - DS.typeScale(size)) < 0.001, "\(size)")
        }
    }

    @Test func theLineGapIsRecomputedFromTheScaledSize() {
        // At each text size the answer's line height is 1.65 times the size on screen, not the gap of the default size.
        for size in TextSizeSetting.sizes {
            let onScreen = 17 * DS.typeScale(size)
            let lineHeight = UIFont(name: DS.Typography.regularFontName, size: onScreen)!.lineHeight
            let gap = DS.Leading.spacing(multiple: DS.Leading.answer.multiple, size: onScreen)
            #expect(abs((lineHeight + gap) / onScreen - 1.65) < 0.001, "\(size)")
        }
        let small = DS.Leading.spacing(multiple: 1.65, size: 17 * DS.typeScale(.xSmall))
        let large = DS.Leading.spacing(multiple: 1.65, size: 17 * DS.typeScale(.xxxLarge))
        #expect(large > small * 1.5)
        #expect(small != DS.Leading.spacing(multiple: 1.65, size: 17))
    }

    @Test func theMarkdownThemeGapStaysProportionalToTheSize() {
        // MarkdownUI takes the gap in em, so it follows whatever font size the theme is scaled to.
        let em = DS.Leading.answer.em
        for scale in [DS.typeScale(.xSmall), 1, DS.typeScale(.xxxLarge)] {
            let size = 17 * scale
            let lineHeight = UIFont(name: DS.Typography.regularFontName, size: size)!.lineHeight
            #expect(abs((lineHeight + em * size) / size - 1.65) < 0.001)
        }
    }

    @Test func textSizeStepsHaveLabels() {
        #expect(Set((0..<7).map(TextSizeSetting.label(forStep:))).count == 7)
    }
}
