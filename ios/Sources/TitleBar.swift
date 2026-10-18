import SwiftUI

/// VS Code's title bar: the command center in the middle, layout actions on
/// the right. It also keeps iPadOS's window controls off the content in
/// windowed mode, the way the desktop title bar makes room for the traffic lights.
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
        .frame(height: 34)
        .background(t.titleBarBg)
        .overlay(alignment: .bottom) { Rectangle().fill(t.titleBarBorder).frame(height: 1) }
    }

    private func commandCenter(_ t: VSTheme) -> some View {
        Button { onCommandCenter?() } label: {
            Hovering { on in
                let hover = on && onCommandCenter != nil
                HStack(spacing: 6) {
                    CodiconView(icon: .search, size: 13)
                    Text(title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(hover ? t.ui("commandCenter.activeForeground", "commandCenter.foreground", "titleBar.activeForeground", default: "#cccccc")
                                 : t.ui("commandCenter.foreground", "titleBar.activeForeground", default: "#cccccc"))
                .frame(maxWidth: 480)
                .frame(height: 24)
                .padding(.horizontal, 10)
                .background(hover ? t.ui("commandCenter.activeBackground", default: "#ffffff14") : t.ui("commandCenter.background", default: "#ffffff0d"))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(hover ? t.ui("commandCenter.activeBorder", "commandCenter.border", default: "#ffffff4d")
                                                                   : t.ui("commandCenter.border", default: "#ffffff26")))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
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

/// A title-bar icon button.
struct TitleBarButton: View {
    let icon: Codicon
    let label: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CodiconView(icon: icon, size: 16)
                .opacity(active ? 1 : 0.75)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(ToolbarButtonStyle(padding: 0))
        .tip(label)
    }
}
