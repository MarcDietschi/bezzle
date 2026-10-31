// press PID WINDOW LABEL [list] : AXPresses the first element in the titled window whose label starts with LABEL ("list" prints labels).
import AppKit
import ApplicationServices
let a = CommandLine.arguments
let pid = pid_t(a[1])!, title = a[2], label = a[3], list = a.count > 4
let app = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, n as CFString, &v); return v }
var wins = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
guard let win = wins.first(where: { (attr($0, kAXTitleAttribute) as? String) == title }) else { print("no window"); exit(1) }
var found = false
var nth = label.hasPrefix("#") ? Int(label.dropFirst())! : 0
func walk(_ e: AXUIElement, _ depth: Int) {
    if found || depth > 40 { return }
    let role = attr(e, kAXRoleAttribute) as? String ?? ""
    let desc = [attr(e, kAXDescriptionAttribute), attr(e, kAXTitleAttribute), attr(e, kAXValueAttribute)].compactMap { $0 as? String }.joined(separator: " | ")
    var names: CFArray?; AXUIElementCopyActionNames(e, &names)
    let acts = (names as? [String]) ?? []
    if list, !desc.isEmpty, acts.contains(kAXPressAction) { print(role, "«\(desc)»", acts) }
    if !list, nth > 0, acts.contains(kAXIncrementAction) { nth -= 1; if nth == 0 { print("press", role, "«\(desc)»", AXUIElementPerformAction(e, kAXPressAction as CFString).rawValue); found = true; return } }
    if !list, !label.hasPrefix("#"), acts.contains(kAXPressAction), desc.hasPrefix(label) {
        print("press", role, "«\(desc)»", AXUIElementPerformAction(e, kAXPressAction as CFString).rawValue); found = true; return
    }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, depth + 1) }
}
walk(win, 0)
if !list && !found { print("not found"); exit(1) }
