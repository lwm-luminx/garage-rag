import SwiftUI

// The building blocks of the menu bar popover, in the shape of a Control Center module: a rounded
// card holding a few rows, each a symbol in a tinted circle, a title, a detail line and, when there
// is something to do about it, one small action on the right.

/// The rounded card a section of the popover sits in.
///
/// The card is its own accessibility container: an identifier given to a module then names the
/// card, and its rows keep theirs. Without it, an identifier on the plain stack is applied to every
/// row inside and replaces their own ("menubar.services" would hide "menubar.allSystemsGo").
struct MenuBarModule<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// The tinted circle a module row starts with, as Control Center draws its toggles.
struct MenuBarSymbolCircle: View {
    let symbol: String
    let tint: Color
    var isActive: Bool = true

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? AnyShapeStyle(tint) : AnyShapeStyle(HierarchicalShapeStyle.quaternary))
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}

/// One row of a module: a service, a page, a result. The whole row is a button that opens what the
/// row is about; `trailing` is an optional control that acts on it instead (Start, Apply, Stop).
struct MenuBarRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    var isActive: Bool = true
    let title: String
    var detail: String? = nil
    var detailTint: Color? = nil
    var showsChevron = true
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 10) {
                    MenuBarSymbolCircle(symbol: symbol, tint: tint, isActive: isActive)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if let detail {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(detailTint ?? .secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MenuBarRowButtonStyle())
            .accessibilityElement(children: .combine)

            trailing()
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
    }
}

extension MenuBarRow where Trailing == EmptyView {
    init(
        symbol: String,
        tint: Color,
        isActive: Bool = true,
        title: String,
        detail: String? = nil,
        detailTint: Color? = nil,
        showsChevron: Bool = true,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.tint = tint
        self.isActive = isActive
        self.title = title
        self.detail = detail
        self.detailTint = detailTint
        self.showsChevron = showsChevron
        self.action = action
        self.trailing = { EmptyView() }
    }
}

/// The small capsule action at the right of a row: "Start", "Apply", "Stop".
struct MenuBarActionButton: View {
    let title: String
    var isDestructive = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(isDestructive ? .red : nil)
            .disabled(isDisabled)
            .fixedSize()
    }
}

/// A row that highlights under the pointer without a border or background of its own, so the
/// module's card stays the visible container.
struct MenuBarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.5)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isEnabled && isHovering ? AnyShapeStyle(HierarchicalShapeStyle.quaternary) : AnyShapeStyle(Color.clear))
                )
                .padding(.horizontal, -6)
                .padding(.vertical, -4)
                .onHover { isHovering = $0 }
        }
    }
}

/// A round icon button in the popover's header ("Open Garage", "Quit Garage"), in the style of the
/// buttons at the top of Control Center's modules: no border until the pointer is over it.
struct MenuBarHeaderButton: View {
    let symbol: String
    let help: String
    /// The ⌘ shortcut that fires the button while the popover is open.
    let key: KeyEquivalent
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(isHovering ? AnyShapeStyle(HierarchicalShapeStyle.quaternary) : AnyShapeStyle(Color.clear))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// "Scan › Ingest › Embed" under a progress bar, the current stage in the tint color.
struct MenuBarStageTrail: View {
    let stages: [MenuBarStatus.Stage]
    let current: MenuBarStatus.Stage?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(stages.enumerated()), id: \.element) { index, stage in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.quaternary)
                        .accessibilityHidden(true)
                }
                Text(stage.title)
                    .font(.system(size: 10, weight: stage == current ? .semibold : .regular))
                    .foregroundStyle(stage == current ? AnyShapeStyle(TintShapeStyle.tint) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(current.map { "Stage: \($0.title)" } ?? "")
    }
}
