import ActivityKit
import SwiftUI
import WidgetKit

/// Puts the reply views (`ReplyActivityViews.swift`, shared with the app's gallery) in the Live Activity's slots.
struct ReplyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ReplyActivityAttributes.self) { context in
            let accent = ReplyActivityStyle.accent(context.attributes.accentHex)
            ReplyActivityLockScreen(state: context.state, accent: accent, isStale: context.isStale)
                .activitySystemActionForegroundColor(accent)
                .widgetURL(context.state.lead.map { ReplyActivityLink.url(for: $0.id) })
        } dynamicIsland: { context in
            let accent = ReplyActivityStyle.accent(context.attributes.accentHex)
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ReplyActivityIsland.ExpandedLeading(state: state, accent: accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ReplyActivityIsland.ExpandedTrailing(state: state, accent: accent)
                }
                DynamicIslandExpandedRegion(.center) {
                    ReplyActivityIsland.ExpandedCenter(state: state, accent: accent, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ReplyActivityIsland.ExpandedBottom(state: state, accent: accent)
                }
            } compactLeading: {
                ReplyActivityIsland.CompactLeading(state: state, accent: accent)
            } compactTrailing: {
                ReplyActivityIsland.CompactTrailing(state: state, accent: accent)
            } minimal: {
                ReplyActivityIsland.Minimal(state: state, accent: accent)
            }
            .widgetURL(state.lead.map { ReplyActivityLink.url(for: $0.id) })
            .keylineTint(accent)
        }
    }
}
