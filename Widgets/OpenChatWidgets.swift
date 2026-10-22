import SwiftUI
import WidgetKit

/// The widget extension: the Live Activity of running replies and the New Chat control. Home Screen widgets join
/// this bundle when there are some.
@main
struct OpenChatWidgets: WidgetBundle {
    var body: some Widget {
        ReplyLiveActivity()
        NewChatControl()
    }
}
