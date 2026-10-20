import SwiftUI

/// The title bar, on the canvas: the command center in the middle, layout
/// actions on the right. It also keeps iPadOS's window controls off the
/// content in windowed mode.
struct TitleBar<Leading: View, Trailing: View>: View {
    let theme: VSTheme
    let title: String
    var onCommandCenter: (() -> Void)?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let t = theme
        ZStack {
            HStack(spacing: 12) {
                leading
                Spacer()
                trailing
            }
            .padding(.horizontal, 12)
            commandCenter(t)
        }
        .buttonStyle(.plain)
        .foregroundStyle(t.titleBarFg)
        .frame(height: 38)
        .background(t.canvasBg)
    }

    private func commandCenter(_ t: VSTheme) -> some View {
        Button { onCommandCenter?() } label: {
            Hovering { on in
                let hover = on && onCommandCenter != nil
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                        .symbolEffect(.bounce, value: hover)
                    Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(t.titleBarFg.opacity(hover ? 1 : 0.78))
                .frame(maxWidth: 480)
                .frame(height: 28)
                .padding(.horizontal, 12)
                .background(hover ? t.raised : t.hoverFill, in: Capsule())
                .overlay(Capsule().strokeBorder(t.cardBorder))
                .scaleEffect(hover ? 1.015 : 1)
                .animation(Motion.pop, value: hover)
            }
        }
        .buttonStyle(PressDown())
        .hoverEffectDisabled()
        .disabled(onCommandCenter == nil)
        .padding(.horizontal, 160) // keep clear of the side actions
    }
}

/// A title-bar icon that opens a menu.
struct TitleBarMenu<Items: View>: View {
    let icon: Codicon
    let label: String
    @ViewBuilder var items: Items

    var body: some View {
        Menu { items } label: {
            CodiconView(icon: icon, size: 16)
                .opacity(0.75)
                .frame(width: 28, height: 28)
                .hoverBackground(Color(white: 0.5, opacity: 0.3), cornerRadius: 5)
                .contentShape(Rectangle())
        }
        .hoverEffectDisabled()
        .tip(label)
    }
}

/// A title-bar icon button. With an SF Symbol, swapping the symbol (a panel
/// shown or hidden) morphs one into the other.
struct TitleBarButton: View {
    var icon: Codicon? = nil
    var symbol: String? = nil
    let label: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 15, weight: .regular))
                        .contentTransition(.symbolEffect(.replace.downUp))
                } else if let icon {
                    CodiconView(icon: icon, size: 16)
                }
            }
            .opacity(active ? 1 : 0.72)
            .frame(width: 30, height: 30)
            .animation(Motion.pop, value: symbol)
        }
        .buttonStyle(ToolbarButtonStyle(padding: 0))
        .tip(label)
    }
}

/// Pressing dips the label; it springs back on release.
struct PressDown: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.pop, value: configuration.isPressed)
    }
}
