// desk permissions: one JSON line with the Accessibility and Screen Recording grants of this process chain
// (the terminal that runs bench.sh), which is what the benchmark's child binaries inherit. Never prompts.
// desk press <pid> <menu> <item>: AXPress on one menu bar item without activating the app (a File > New Window
// opens a window and leaves the app in the background). One JSON line {"ok": bool, "error": ...}. Built to .build/desk.
// desk quit <pid>: asks the app to quit as the Quit menu command does; a signal makes some apps (DaVinci Resolve)
// relaunch with a crash report instead.
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func titled(_ elements: [AXUIElement], _ title: String) -> AXUIElement? {
    elements.first { (attribute($0, kAXTitleAttribute) as? String) == title }
}

func emit(_ report: [String: Any]) {
    print(String(decoding: try! JSONSerialization.data(withJSONObject: report), as: UTF8.self))
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "permissions":
    emit(["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess()])
case "press" where arguments.count == 4:
    guard let pid = Int32(arguments[1]), kill(pid, 0) == 0 else {
        emit(["ok": false, "error": "no such process"])
        exit(1)
    }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 3)
    guard let bar = attribute(app, kAXMenuBarAttribute) else {
        emit(["ok": false, "error": "no menu bar"])
        exit(1)
    }
    guard let menu = titled(children(bar as! AXUIElement), arguments[2]),
          let list = children(menu).first,
          let item = titled(children(list), arguments[3]) else {
        emit(["ok": false, "error": "menu item not found"])
        exit(1)
    }
    let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
    emit(["ok": result == .success, "error": result == .success ? NSNull() : "AXPress \(result.rawValue)"])
    exit(result == .success ? 0 : 1)
case "quit" where arguments.count == 2:
    guard let pid = Int32(arguments[1]), let app = NSRunningApplication(processIdentifier: pid) else {
        emit(["ok": false, "error": "no such process"])
        exit(1)
    }
    let asked = app.terminate()
    emit(["ok": asked, "error": asked ? NSNull() : "the app refused the quit request"])
    exit(asked ? 0 : 1)
default:
    emit(["ok": false, "error": "usage: desk permissions | desk press <pid> <menu> <item> | desk quit <pid>"])
    exit(2)
}
