import SwiftUI

/// A control that opens one of Bezzle's own menus: its value, and a chevron.
struct MenuButton: View {
    @Environment(MenuHost.self) private var host
    let id: String
    let title: String
    var width: CGFloat = 240
    var prominent = false
    let entries: () -> [MenuEntry]
    @State private var hovering = false

    var body: some View {
        let isOpen = host.open?.id == id
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12.5, weight: prominent ? .medium : .regular))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Chevron(color: Theme.ink3)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Theme.ink.opacity(isOpen ? 0.09 : hovering ? 0.065 : 0.04))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { host.toggle(id, width: width, entries: entries()) }
        .menuAnchor(id)
        .animation(Theme.quick, value: hovering)
        .animation(Theme.quick, value: isOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugOpenMenu)) { note in
            if note.object as? String == id { host.toggle(id, width: width, entries: entries()) }
        }
        #endif
    }
}

/// A choice of a few options: a card that slides along a well.
struct SegmentedWell<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                let selected = value == selection
                Text(title)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Theme.card)
                                .shadow(color: Theme.shadow.opacity(0.12), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "thumb", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(Theme.spring) { selection = value } }
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .well(radius: 9)
    }
}

/// An on/off switch: a knob that slides in a well, which fills with ink when on.
struct Switch: View {
    @Binding var isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.well.shadow(.inner(color: Theme.shadow.opacity(0.25), radius: 1.5, y: 1))))
            Circle()
                .fill(isOn ? Theme.onInk : Theme.card)
                .shadow(color: Theme.shadow.opacity(0.2), radius: 1.5, y: 1)
                .padding(2)
        }
        .frame(width: 32, height: 18)
        .contentShape(Capsule())
        .onTapGesture { withAnimation(Theme.spring) { isOn.toggle() } }
        .accessibilityRepresentation { Toggle("", isOn: $isOn) }
    }
}

/// The one ink button on screen. Its loading state lives inside it: while work runs, the button
/// fills with pencil blue from the left as the run progresses.
struct PrimaryButton: View {
    let title: String
    var progress: Double?
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.ink.opacity(enabled ? (hovering ? 0.88 : 1) : 0.22))
                if let progress {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Theme.pencil)
                            .frame(width: max(14, geo.size.width * progress))
                            .animation(.easeOut(duration: 0.35), value: progress)
                    }
                    .transition(.opacity)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.onInk.opacity(enabled ? 1 : 0.8))
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: Theme.shadow.opacity(enabled ? 0.18 : 0), radius: 6, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .disabled(!enabled)
        .onHover { hovering = $0 && enabled }
        .animation(Theme.quick, value: hovering)
        .animation(Theme.spring, value: progress == nil)
    }
}

/// Sinks a little while pressed.
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

/// A button raised off the paper like a small card, for secondary actions.
struct CardButton: View {
    let title: String
    var symbol: String?
    var height: CGFloat = 32
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: height * 0.36, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                }
                Text(title)
                    .font(.system(size: height >= 32 ? 13 : 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, height / 2)
            .frame(height: height)
            .card(radius: height * 0.28, lifted: hovering)
            .offset(y: hovering ? -1 : 0)
        }
        .buttonStyle(Pressable())
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
    }
}

/// A soft chip of ink on the paper: a secondary action that still reads as a button on its own,
/// such as "Open…" beside the presets.
struct ChipButton: View {
    let title: String
    var height: CGFloat = 28
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, height * 0.4)
                .frame(height: height)
                .background {
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .fill(Theme.ink.opacity(hovering ? 0.085 : 0.05))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
    }
}

/// A quiet round button for small actions on a card.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(hovering ? Theme.ink : Theme.ink2)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.ink.opacity(hovering ? 0.08 : 0)))
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help(help)
            .animation(Theme.quick, value: hovering)
            .accessibilityLabel(help)
            .accessibilityAddTraits(.isButton)
    }
}

/// A plain text button, for small actions inside another control, such as "Set".
struct TextButton: View {
    let title: String
    var color: Color = Theme.ink2
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(hovering ? Theme.ink : color)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .animation(Theme.quick, value: hovering)
            .accessibilityAddTraits(.isButton)
    }
}
