import SwiftUI

/// The title bar, on the canvas: the command center in the middle, layout
/// actions on the right. It also keeps iPadOS's window controls off the
/// content in windowed mode.
struct TitleBar<Leading: View, Trailing: View>: View {
    let theme: VSTheme
    let title: String
    var onCommandCenter: (() -> Void)?
    /// When set, the command center is a search field (the home page's machine filter), `title` its prompt.
    var filter: Binding<String>? = nil
    @Environment(\.home) private var h
    @FocusState private var searching: Bool
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let t = theme
        ZStack {
            HStack(spacing: 4) {
                leading
                Spacer()
                trailing
            }
            .padding(.horizontal, 12)
            commandCenter(t)
        }
        .buttonStyle(.plain)
        .foregroundStyle(h.ink)
        .frame(height: 44)
        // Straight on the canvas, no bar: the command center is the one object, the actions are quiet icons.
        .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 4)
    }

    @ViewBuilder
    private func commandCenter(_ t: VSTheme) -> some View {
        if let filter { searchField(filter) } else { commandButton(t) }
    }

    private func searchField(_ text: Binding<String>) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
            TextField("", text: text, prompt: Text(title).foregroundStyle(h.muted))
                .textFieldStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(h.ink)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($searching)
                .onKeyPress(.escape) { text.wrappedValue = ""; searching = false; return .handled }
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 13)) }
                    .buttonStyle(PressDown()).tip("Clear")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .foregroundStyle(searching ? h.ink : h.muted)
        .frame(maxWidth: 480)
        .frame(height: 32)
        .padding(.horizontal, 14)
        .background(h.card, in: Capsule())
        .overlay(Capsule().strokeBorder(searching ? h.green : h.border, lineWidth: searching ? 1.5 : 1))
        .shadow(color: .black.opacity((searching ? 0.08 : 0.05) * h.shadow), radius: searching ? 10 : 6, y: 3)
        .contentShape(Capsule())
        .onTapGesture { searching = true }
        .animation(Motion.pop, value: searching)
        .animation(Motion.quick, value: text.wrappedValue.isEmpty)
        .padding(.horizontal, 160) // keep clear of the side actions
    }

    private func commandButton(_ t: VSTheme) -> some View {
        Button { onCommandCenter?() } label: {
            Hovering { on in
                let hover = on && onCommandCenter != nil
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                        .symbolEffect(.bounce, value: hover)
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(hover ? h.ink : h.muted)
                .frame(maxWidth: 480)
                .frame(height: 32)
                .padding(.horizontal, 14)
                .background(h.card, in: Capsule())
                .overlay(Capsule().strokeBorder(hover ? h.green : h.border))
                .shadow(color: .black.opacity((hover ? 0.08 : 0.05) * h.shadow), radius: hover ? 10 : 6, y: 3)
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
    let symbol: String
    let label: String
    @ViewBuilder var items: Items

    var body: some View {
        Menu { items } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .regular))
                .opacity(0.72)
                .frame(width: 36, height: 36)
                .hoverBackground(Color(white: 0.5, opacity: 0.2), cornerRadius: 6)
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
            .frame(width: 36, height: 36)
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
