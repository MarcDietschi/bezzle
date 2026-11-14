// shot PID TITLE W H OUT.png : puts the titled window on the virtual display (found by its vendor number, wherever
// macOS has placed it) at W×H and captures it at 2x, without raising it. After the app's AppStore/screenshots-src/capture/shot.swift.
import AppKit
import ApplicationServices
let a = CommandLine.arguments
let pid = pid_t(a[1])!, title = a[2], w = Double(a[3])!, h = Double(a[4])!, out = a[5]
var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
CGGetActiveDisplayList(16, &ids, &n)
guard let display = ids.prefix(Int(n)).first(where: { CGDisplayVendorNumber($0) == 0xB322 }) else { print("no virtual display"); exit(1) }
let b = CGDisplayBounds(display)
let app = AXUIElementCreateApplication(pid)
var value: CFTypeRef?
AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
var target: AXUIElement?
for win in (value as? [AXUIElement]) ?? [] {
    var t: CFTypeRef?; AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &t)
    if (t as? String) == title { target = win }
}
guard let win = target else { print("no window titled \(title)"); exit(1) }
var p = CGPoint(x: b.minX + (b.width - w) / 2, y: b.minY + max(0, (b.height - h) / 2)), s = CGSize(width: w, height: h)
AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
// Never raised: screencapture -l photographs the window wherever it is, and raising would take focus.
usleep(UInt32((Double(ProcessInfo.processInfo.environment["SETTLE"] ?? "1.2") ?? 1.2) * 1_000_000))
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
guard let info = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowName as String] as? String) == title && ($0[kCGWindowLayer as String] as? Int) == 0 }) else { print("no such window listed"); exit(1) }
let wid = info[kCGWindowNumber as String] as! Int
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
task.arguments = ["-x", "-o", "-l", String(wid), out]
try! task.run(); task.waitUntilExit()
print("captured", title, wid, "display", b)
