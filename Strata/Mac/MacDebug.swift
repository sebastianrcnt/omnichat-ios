#if os(macOS) && DEBUG
import AppKit

/// `-StrataKeyTest send|newline|marked`: after launch, types into the composer through the responder chain with
/// synthesized key events (no accessibility permission needed) and leaves the result on screen for a screenshot.
@MainActor
enum MacKeyTest {
    static func runIfRequested() {
        guard let mode = UserDefaults.standard.string(forKey: "StrataKeyTest") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else { return }
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(1))
            func insert(_ text: String) { (window.firstResponder as? NSTextView)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: chars,
                                                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                        NSApp.sendEvent(event)
                    }
                }
            }
            let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            FileHandle.standardError.write(Data("[key-test] mode=\(mode) first responder: \(responder)\n".utf8))
            switch mode {
            case "menus":
                func dump(_ menu: NSMenu, _ depth: Int) {
                    for item in menu.items where !item.isSeparatorItem {
                        let keys = item.keyEquivalent.isEmpty ? "" : " [\(item.keyEquivalentModifierMask.contains(.command) ? "cmd+" : "")\(item.keyEquivalent)]"
                        FileHandle.standardError.write(Data("[menus] \(String(repeating: "  ", count: depth))\(item.title)\(keys)\(item.isEnabled ? "" : " (disabled)")\n".utf8))
                        if let sub = item.submenu, depth < 1 { dump(sub, depth + 1) }
                    }
                }
                if let main = NSApp.mainMenu { dump(main, 0) }
            case "newchat", "find", "stop":
                try? await Task.sleep(for: .seconds(mode == "stop" ? 0 : 6)) // let the auto-sent chat finish
                let title = mode == "newchat" ? "New Chat" : mode == "find" ? "Find Chats" : "Stop Generating"
                for top in NSApp.mainMenu?.items ?? [] {
                    for (index, item) in (top.submenu?.items ?? []).enumerated() where item.title == title {
                        FileHandle.standardError.write(Data("[key-test] performing \(title), enabled=\(item.isEnabled)\n".utf8))
                        top.submenu?.performActionForItem(at: index)
                    }
                }
                try? await Task.sleep(for: .milliseconds(600))
                FileHandle.standardError.write(Data("[key-test] first responder now: \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")\n".utf8))
            case "letter":
                key(0, "a")
                key(11, "b")
            case "send":
                insert("hello from a synthesized Return")
                try? await Task.sleep(for: .milliseconds(300)) // let the view catch up, as a person's typing would
                key(36, "\r")
            case "newline":
                insert("first line")
                try? await Task.sleep(for: .milliseconds(300))
                key(36, "\r", .shift)
                insert("second line")
            case "marked":
                (window.firstResponder as? NSTextView)?.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                                                                        replacementRange: NSRange(location: NSNotFound, length: 0))
                key(36, "\r")
                FileHandle.standardError.write(Data("[key-test] after Return with marked text: hasMarkedText=\((window.firstResponder as? NSTextView)?.hasMarkedText() ?? false)\n".utf8))
            default: break
            }
            try? await Task.sleep(for: .seconds(1))
            if let tv = window.firstResponder as? NSTextView {
                FileHandle.standardError.write(Data("[key-test] string=\(tv.string.debugDescription) frame=\(tv.frame) scroll=\(tv.enclosingScrollView?.frame ?? .zero) color=\(String(describing: tv.textColor)) container=\(tv.textContainer?.containerSize ?? .zero)\n".utf8))
            }
        }
    }
}
#endif
