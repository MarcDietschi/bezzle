import SwiftUI
import AppKit

/// Bringing a web page in as a design: the address, the widths to read it at, whether cookie
/// banners go, and the import running. Kept apart from the sheet so a menu, a dropped link or
/// the home screen can open it.
@MainActor @Observable
final class WebImporting {
    static let shared = WebImporting()

    var showing = false
    var address = ""
    var desktop = true
    var tablet = false
    var mobile = false
    var custom = false
    var customWidth: Double = 1280
    var hideBanners = true
    private(set) var stage: String?
    private(set) var progress: Double?
    private(set) var failure: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancelled = false

    var running: Bool { progress != nil }

    /// The sizes chosen, the widest first.
    var sizes: [WebCapture.Size] {
        var out: [WebCapture.Size] = []
        if desktop { out.append(.desktop) }
        if custom, customWidth >= 240 { out.append(.custom(CGFloat(customWidth))) }
        if tablet { out.append(.tablet) }
        if mobile { out.append(.mobile) }
        return out.sorted { $0.width > $1.width }.reduce(into: []) { list, s in if !list.contains(where: { $0.width == s.width }) { list.append(s) } }
    }

    var canStart: Bool { !running && WebCapture.address(address) != nil && !sizes.isEmpty }

    /// Opens the sheet, with an address to bring in or the one on the clipboard.
    func present(_ address: String? = nil) {
        if let address {
            self.address = address
        } else if !running, let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  copied.lowercased().hasPrefix("http"), WebCapture.address(copied) != nil {
            self.address = copied
        }
        if !running { failure = nil }
        showing = true
    }

    func close() {
        cancel()
        showing = false
    }

    func start() {
        guard !running else { return }
        guard let url = WebCapture.address(address) else {
            failure = String(localized: "That is not a web address Bezzle can open.")
            return
        }
        failure = nil
        cancelled = false
        stage = String(localized: "Loading the page…")
        progress = 0.01
        let sizes = sizes, hide = hideBanners
        task = Task { [weak self] in
            do {
                let (design, report) = try await WebImport.run(url, sizes: sizes, hideBanners: hide, into: Library.shared.folder) { what, done in
                    guard let self, !self.cancelled else { return }
                    self.stage = what
                    self.progress = max(self.progress ?? 0, done)
                }
                guard let self, !self.cancelled else { return }
                self.done(nil)
                self.showing = false
                Library.shared.refresh()
                WindowRouter.shared.open(design, report: report)
            } catch {
                guard let self, !self.cancelled else { return }
                self.done(error is CancellationError ? nil : error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard running else { return }
        cancelled = true
        task?.cancel()
        done(nil)
    }

    private func done(_ failure: String?) {
        task = nil
        stage = nil
        progress = nil
        self.failure = failure
    }
}

/// The sheet over the window where a web page is brought in.
struct WebImportSheet: View {
    @Bindable var model: WebImporting
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if !model.running { model.close() } }
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Import from a Website")
                        .font(Theme.serif(22, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    IconButton(symbol: "xmark", help: "Close") { model.close() }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Address").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                    HStack(spacing: 7) {
                        Image(systemName: "globe")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(focused ? Theme.ink2 : Theme.ink3)
                        TextField(text: $model.address, prompt: Text(verbatim: "example.com")) { Text("Address") }
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($focused)
                            .onSubmit { if model.canStart { model.start() } }
                            .disabled(model.running)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .well(radius: Theme.controlRadius)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sizes").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                    HStack(spacing: 8) {
                        SizeChoice(title: "Desktop", width: Int(WebCapture.Size.desktop.width), isOn: $model.desktop)
                        SizeChoice(title: "Tablet", width: Int(WebCapture.Size.tablet.width), isOn: $model.tablet)
                        SizeChoice(title: "Mobile", width: Int(WebCapture.Size.mobile.width), isOn: $model.mobile)
                    }
                    HStack(spacing: 8) {
                        CheckBox(isOn: $model.custom)
                        Text("Another width")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.ink)
                            .onTapGesture { withAnimation(Theme.quick) { model.custom.toggle() } }
                        TextField(value: $model.customWidth, format: .number.grouping(.never)) { Text("Width") }
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5).monospacedDigit())
                            .multilineTextAlignment(.trailing)
                            .frame(width: 52)
                            .padding(.horizontal, 7)
                            .frame(height: 24)
                            .well(radius: 6)
                            .opacity(model.custom ? 1 : 0.45)
                            .disabled(!model.custom)
                        Text(verbatim: "px").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                    }
                    .disabled(model.running)
                }
                .disabled(model.running)
                HStack(spacing: 8) {
                    CheckBox(isOn: $model.hideBanners)
                    Text("Hide cookie banners")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink)
                        .onTapGesture { withAnimation(Theme.quick) { model.hideBanners.toggle() } }
                }
                .disabled(model.running)
                if let failure = model.failure {
                    Text(failure)
                        .prose(12)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                VStack(spacing: 8) {
                    PrimaryButton(title: model.running ? "Importing…" : "Import", progress: model.progress, enabled: model.canStart) { model.start() }
                    if model.running {
                        HStack {
                            Text(verbatim: model.stage ?? "")
                                .prose(12)
                                .foregroundStyle(Theme.ink3)
                                .lineLimit(1)
                                .contentTransition(.opacity)
                            Spacer(minLength: 8)
                            TextButton(title: "Cancel") { model.cancel() }
                        }
                        .transition(.opacity)
                    }
                }
            }
            .padding(24)
            .frame(width: 440)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5) }
            .shadow(color: Theme.shadow.opacity(0.22), radius: 30, y: 14)
            .transition(.scale(scale: 0.97).combined(with: .opacity))
            .animation(Theme.spring, value: model.running)
            .animation(Theme.spring, value: model.failure)
        }
        .onExitCommand { model.close() }
        .onAppear { focused = true }
    }
}

/// One of the sizes a page is read at, chosen or not.
private struct SizeChoice: View {
    let title: LocalizedStringResource
    let width: Int
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text(verbatim: "\(width) px")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(isOn ? Theme.pencilWash : Theme.ink.opacity(hovering ? 0.07 : 0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(isOn ? Theme.pencil.opacity(0.8) : Theme.hairline, lineWidth: isOn ? 1.2 : 0.5)
        }
        .overlay(alignment: .topTrailing) {
            CheckMark(size: 9, color: Theme.pencil, weight: 1.5)
                .padding(8)
                .opacity(isOn ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Theme.quick) { isOn.toggle() } }
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
