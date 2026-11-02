// Probe for the floating-layout spike. All coordinates are CG global (top-left origin, points).
//   probe click X Y          synthesize a left click, print the frontmost app afterwards, restore the cursor
//   probe key KEYCODE [cmd]  synthesize a key press (to the frontmost app, i.e. our own spike)
//   probe front              print the frontmost app
//   probe activate PID       activate an app by pid (used to hand focus back)
//   probe order PID[,PID]    on-screen windows of those pids, front to back, with layer and bounds
//   probe cmd NAME           post the "meum.spike.cmd" distributed notification
//   probe sample PID MS      sample that pid's window bounds as fast as possible for MS ms (JSON lines)
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
let a = CommandLine.arguments
func front() -> String {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    let f = NSWorkspace.shared.frontmostApplication
    return "\(f?.localizedName ?? "-") pid=\(f?.processIdentifier ?? -1)"
}
func windows(_ pids: Set<Int32>?) -> [[String: Any]] {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var out: [[String: Any]] = []
    for (i, w) in info.enumerated() {
        let pid = (w[kCGWindowOwnerPID as String] as? Int32) ?? -1
        if let pids, !pids.contains(pid) { continue }
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        out.append(["z": i, "pid": pid, "owner": w[kCGWindowOwnerName as String] ?? "", "num": w[kCGWindowNumber as String] ?? 0,
                    "layer": w[kCGWindowLayer as String] ?? 0, "alpha": w[kCGWindowAlpha as String] ?? 1,
                    "b": [b["X"] ?? 0, b["Y"] ?? 0, b["Width"] ?? 0, b["Height"] ?? 0]])
    }
    return out
}
func json(_ o: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)! }

switch a.count > 1 ? a[1] : "" {
case "click":
    let p = CGPoint(x: Double(a[2])!, y: Double(a[3])!)
    let saved = CGEvent(source: nil)!.location
    print("before:", front())
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(40_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    print("after:", front())
    CGWarpMouseCursorPosition(saved)
case "key":
    let code = CGKeyCode(Int(a[2])!)
    let src = CGEventSource(stateID: .hidSystemState)
    let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)!
    let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)!
    if a.count > 3 && a[3] == "cmd" { d.flags = .maskCommand; u.flags = .maskCommand }
    d.post(tap: .cghidEventTap); usleep(30_000); u.post(tap: .cghidEventTap); usleep(250_000)
    print("after key:", front())
case "front":
    print(front())
case "activate":
    let ok = NSRunningApplication(processIdentifier: Int32(a[2])!)?.activate(options: []) ?? false
    usleep(300_000)
    print("activate \(ok):", front())
case "order":
    let pids = Set(a[2].split(separator: ",").compactMap { Int32($0) })
    for w in windows(pids) { print(json(w)) }
case "cmd":
    DistributedNotificationCenter.default().postNotificationName(.init("meum.spike.cmd"), object: a[2], userInfo: nil, deliverImmediately: true)
    usleep(100_000)
case "sample":
    let pid = Int32(a[2])!
    let end = Date().addingTimeInterval(Double(a[3])! / 1000)
    let t0 = CACurrentMediaTime()
    while Date() < end {
        let ws = windows([pid]).map { $0["b"]! }
        print(json(["t": (CACurrentMediaTime() - t0) * 1000, "w": ws]))
        usleep(1000)
    }
default:
    print("usage: see header")
}
