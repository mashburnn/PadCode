import Combine
import GameController
import SwiftUI
import UIKit

/// Whether a hardware keyboard is attached. The terminal's key bar (esc, ctrl,
/// arrows…) only makes sense with the on-screen keyboard.
@MainActor
final class KeyboardState: ObservableObject {
    static let shared = KeyboardState()
    @Published private(set) var hardware = GCKeyboard.coalesced != nil
    private var bag: [AnyCancellable] = []

    private init() {
        let nc = NotificationCenter.default
        nc.publisher(for: .GCKeyboardDidConnect).sink { [weak self] _ in self?.hardware = true }.store(in: &bag)
        nc.publisher(for: .GCKeyboardDidDisconnect).sink { [weak self] _ in self?.hardware = false }.store(in: &bag)
        // GCKeyboard can be nil until the first key press, so also judge by the
        // keyboard's height: a full on-screen keyboard is far taller than a bar.
        nc.publisher(for: UIResponder.keyboardWillChangeFrameNotification).sink { [weak self] n in
            guard let end = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, end.height > 0 else { return }
            if end.height > 200 { self?.hardware = false } else if end.height < 120 { self?.hardware = true }
        }.store(in: &bag)
    }
}

/// Keeps the whole layout above the keyboard (or its accessory bar), so the
/// status bar and terminal prompt are never covered. iPadOS already shrinks the
/// window for the full on-screen keyboard but not for an accessory bar alone, so
/// this measures the space it was actually given and pads only what the
/// keyboard still overlaps; it never counts the keyboard twice.
struct AvoidKeyboard: ViewModifier {
    /// Keyboard top edge in window coordinates; nil when it's hidden.
    @State private var keyboardTop: CGFloat?
    @State private var window: UIWindow?

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let overlap = keyboardTop.map { max(0, frame.maxY - $0) } ?? 0
            content
                .frame(width: frame.width, height: max(frame.height - overlap, 0))
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(WindowProbe { window = $0 })
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification), perform: update)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { n in
            animate(n) { keyboardTop = nil }
        }
    }

    private func update(_ n: Notification) {
        guard let window, let end = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let kb = window.convert(end, from: window.screen.coordinateSpace)
        let top: CGFloat? = kb.intersects(window.bounds) && kb.height > 0 ? kb.minY : nil
        animate(n) { keyboardTop = top }
    }

    private func animate(_ n: Notification, _ change: () -> Void) {
        let d = n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        withAnimation(.easeOut(duration: d), change)
    }
}

extension View {
    func avoidKeyboard() -> some View { modifier(AvoidKeyboard()) }
}

/// Reports the UIWindow a SwiftUI view lives in.
private struct WindowProbe: UIViewRepresentable {
    let found: (UIWindow?) -> Void

    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.found = found
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: Probe, context: Context) { v.found = found }

    final class Probe: UIView {
        var found: (UIWindow?) -> Void = { _ in }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            let w = window
            DispatchQueue.main.async { [found] in found(w) }
        }
    }
}
