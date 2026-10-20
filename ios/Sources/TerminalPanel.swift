import SwiftTerm
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// One shell on the desktop, rendered by SwiftTerm. Survives SwiftUI view
/// rebuilds; the view is created once and re-parented.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    /// Folder the shell starts in; nil = the desktop's home.
    let cwd: String?
    @Published var title: String
    @Published var exited = false
    /// Output arrived while another terminal was showing (the tab's dot).
    @Published var unread = false
    /// Bumped on BEL, to flash the tab.
    @Published var bells = 0
    /// ⌘F's find bar is showing (VS Code's terminal find widget).
    @Published var finding = false
    let view: TerminalView
    private var term: Term?
    private var delegate: Delegate?
    private var started = false
    private var autoStarted = false
    /// Waiting for the workbench to reconnect; suppresses repeat notices.
    private var lost = false
    private var sized = false
    /// Bumped per shell, so a late exit from a replaced shell is ignored.
    private var generation = 0
    weak var workbench: Workbench?
    /// Typed into the shell once it starts (e.g. an install command), no Enter.
    var initialInput: String?
    private var size = (cols: 80, rows: 24)

    /// Desktop-side session this terminal attaches to: it survives
    /// disconnects and app restarts (macOS/Linux desktops).
    let persistentID: String
    /// Output bytes received from the session, so a reattach replays only what was missed.
    let received = ByteCounter()

    init(title: String, cwd: String?, persistentID: String? = nil) {
        self.title = title
        self.cwd = cwd
        self.persistentID = persistentID ?? String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)).lowercased()
        view = PadTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 300))
        delegate = Delegate(owner: self)
        view.terminalDelegate = delegate
        view.optionAsMetaKey = true
        view.linkHighlightMode = .hoverWithModifier // ⌘-hover underlines, ⌘-click opens (VS Code)
        (view as? PadTerminalView)?.onFind = { [weak self] in self?.finding = true }
        keyBar = view.inputAccessoryView
        pointer = PointerSelection(view) { [weak self] in self?.size ?? (80, 24) }
    }

    private(set) var pointer: PointerSelection?

    /// SwiftTerm's key bar (esc, ctrl, tab, arrows…), kept to put back later.
    private var keyBar: UIView?

    /// Shows the key bar only with the on-screen keyboard; with a hardware
    /// keyboard it would just sit over the bottom of the window.
    func setKeyBar(visible: Bool) {
        let want = visible ? keyBar : nil
        guard view.inputAccessoryView !== want else { return }
        view.inputAccessoryView = want
        if view.isFirstResponder { view.reloadInputViews() }
    }

    func apply(theme: VSTheme, fontSize: CGFloat) {
        view.font = UIFont(name: "Menlo-Regular", size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.nativeBackgroundColor = theme.terminalBg
        view.nativeForegroundColor = theme.terminalFg
        view.caretColor = theme.terminalCursor
        view.selectedTextBackgroundColor = theme.terminalSelection
        view.keyboardAppearance = theme.isDark ? .dark : .light
        view.installColors(theme.ansi.map { c in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return SwiftTerm.Color(red: UInt16(r * 65535), green: UInt16(g * 65535), blue: UInt16(b * 65535))
        })
    }

    /// Starts the remote shell once the view has a real size.
    /// First start, when the view appears. Later starts are explicit (Enter
    /// after exit, or reattach after a reconnect), so a dead connection can't
    /// cause a retry on every view update.
    func autoStart(_ wb: Workbench) {
        guard !autoStarted, wb.desktop != nil else { return }
        autoStarted = true
        start(wb)
    }

    func start(_ wb: Workbench) {
        guard !started, let d = wb.desktop else { return }
        started = true
        exited = false
        if !sized { size = estimatedSize() }
        generation += 1
        let gen = generation
        Task {
            do {
                let sink = Sink(owner: self, generation: gen)
                term = try await d.openTerminal(cols: UInt16(size.cols), rows: UInt16(size.rows), cwd: cwd,
                                                session: persistentID, offset: received.value, sink: sink)
                if let input = initialInput {
                    initialInput = nil
                    try? term?.write(data: Data(input.utf8))
                }
                lost = false
            } catch PadError.Closed {
                started = false
                connectionLost(wb)
            } catch {
                view.feed(text: "\r\n\u{1b}[31m[could not start terminal: \(error.localizedDescription)]\u{1b}[0m\r\n")
                exited = true
                started = false
            }
        }
    }

    func restart(_ wb: Workbench) {
        started = false
        received.value = 0 // the old session ended; a new one starts from scratch
        view.feed(text: "\r\n")
        start(wb)
    }

    /// After a reconnect: the old shell died with the old tunnel; start a new one.
    func reattach(_ wb: Workbench) {
        try? term?.close() // detach; the shell keeps running on the desktop
        term = nil
        started = false
        exited = false
        guard autoStarted else { return } // never shown yet: autoStart handles it
        start(wb) // replays whatever the shell printed meanwhile
    }

    /// Types into the shell (used by tests and Run).
    func send(_ text: String) {
        try? term?.write(data: Data(text.utf8))
    }

    /// One dim notice, then let the workbench replace the connection.
    private func connectionLost(_ wb: Workbench?) {
        guard !lost else { return }
        lost = true
        view.feed(text: "\r\n\u{1b}[2m[connection lost — reconnecting…]\u{1b}[0m\r\n")
        if let wb { Task { await wb.reconnect() } }
    }

    fileprivate func lostShell(generation gen: Int) {
        guard gen == generation else { return }
        started = false
        term = nil
        connectionLost(workbench)
    }

    func kill() {
        try? term?.kill()
    }

    /// ⌘-click in the terminal, as in VS Code: `src/main.rs:12:5` opens in the
    /// editor (relative to the folder the shell started in), web links in Safari.
    /// ponytail: SwiftTerm only detects paths with a `/` (not a bare `point.c:6`),
    /// and doesn't know the shell's current folder after `cd`.
    func openLink(_ link: String) {
        guard let (path, line, column) = Self.fileLink(link), let wb = workbench, let d = wb.desktop else {
            if let url = URL(string: link), url.scheme != nil { UIApplication.shared.open(url) }
            return
        }
        let full = path.hasPrefix("/") ? path
            : path.hasPrefix("~/") ? d.join(base: wb.env?.home ?? "", name: String(path.dropFirst(2)))
            : d.join(base: cwd ?? wb.root, name: path)
        // A terminal window has no editor: the file opens in this desktop's editor window.
        guard let target = wb.terminalsOnly == nil ? wb : wb.editorWindow else {
            return wb.openInNewWindow(wb.root.isEmpty ? nil : wb.root) // ponytail: click again once it's open
        }
        let clean = full.contains("\\") ? full : (full as NSString).standardizingPath // not Windows paths
        Task { await target.open(clean, line: line, column: column.map { max($0 - 1, 0) }) }
    }

    /// `src/main.rs:12:5` → ("src/main.rs", 12, 5); `file:///a/b.c` → ("/a/b.c", nil, nil);
    /// a web link → nil.
    nonisolated static func fileLink(_ link: String) -> (path: String, line: Int?, column: Int?)? {
        var s = link.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("file://") {
            s = URL(string: s)?.path ?? String(s.dropFirst(7))
        } else if s.range(of: #"^[A-Za-z][\w+.-]+:(?!\d)"#, options: .regularExpression) != nil {
            return nil // https:, mailto:, ssh: …
        }
        guard let m = s.firstMatch(of: #/^(.+?)(?::(\d+))?(?::(\d+))?:?$/#) else { return nil }
        return (String(m.1), m.2.flatMap { Int($0) }, m.3.flatMap { Int($0) })
    }

    /// Lets go of the desktop shell without ending it (it moves to another window).
    func detach() {
        generation += 1 // a late exit/lost from this stream is ignored
        try? term?.close()
        term = nil
        started = false
    }

    fileprivate func send(_ data: ArraySlice<UInt8>) {
        // Synchronous enqueue (microseconds) keeps keystrokes in order with
        // no task hop between the key press and the network write.
        try? term?.write(data: Data(data))
    }

    /// Grid size from the view's bounds, until SwiftTerm reports the real one.
    private func estimatedSize() -> (cols: Int, rows: Int) {
        let cell = ("W" as NSString).size(withAttributes: [.font: view.font])
        guard cell.width > 0, cell.height > 0, view.bounds.width > 0 else { return size }
        return (max(Int(view.bounds.width / cell.width), 20), max(Int(view.bounds.height / cell.height), 5))
    }

    /// Resizes sent to the desktop (tests).
    private(set) var resizeCount = 0

    fileprivate func resized(cols: Int, rows: Int) {
        sized = true
        guard cols != size.cols || rows != size.rows else { return }
        size = (cols, rows)
        resizeCount += 1
        try? term?.resize(cols: UInt16(cols), rows: UInt16(rows))
    }

    fileprivate func ended(code: Int32, generation gen: Int) {
        guard gen == generation else { return }
        exited = true
        started = false
        term = nil
        view.feed(text: "\r\n\u{1b}[2m[process exited with code \(code) — press Enter to restart]\u{1b}[0m\r\n")
    }

    /// Bytes from the desktop arrive on a Rust thread; SwiftTerm's feed is
    /// thread-safe (`nonisolated`), so no hop to the main actor is needed.
    private final class Sink: TermSink, @unchecked Sendable {
        weak var owner: TerminalSession?
        let view: TerminalView
        let generation: Int
        let received: ByteCounter
        /// When this attach began: the replay of earlier output that follows isn't news.
        private let attached = CACurrentMediaTime()
        init(owner: TerminalSession, generation: Int) {
            self.owner = owner
            self.generation = generation
            view = owner.view
            received = owner.received
        }
        func onData(data: Data) {
            var bytes = [UInt8](data)
            // ESC ] 7778 ; N BEL: absolute offset of what follows (sent on attach).
            if let (n, end) = Self.marker(bytes, code: "7778") {
                received.value = n
                bytes.removeSubrange(0..<end)
            }
            // ESC ] 7779 ; code BEL: shell exit notice from the session daemon.
            if let r = Self.find(bytes, Array("\u{1b}]7779;".utf8)), let bel = bytes[r...].firstIndex(of: 7) {
                bytes.removeSubrange(r...bel)
            }
            received.add(UInt64(bytes.count))
            bytes.withUnsafeBufferPointer { view.feed(byteArray: ArraySlice($0)) }
            if !bytes.isEmpty, CACurrentMediaTime() - attached > 1.5, !flagged.swap(true) {
                DispatchQueue.main.async { [weak owner, flagged] in
                    MainActor.assumeIsolated {
                        // Checked again after a beat, so a stream of output costs a few hops a second.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { flagged.swap(false) }
                        guard let owner, let wb = owner.workbench else { return }
                        if wb.activeTerminal != owner.id || wb.panelTab != .terminal || !wb.panelOpen { owner.unread = true }
                    }
                }
            }
        }
        /// One main-thread hop per burst of output, not per chunk.
        private let flagged = Flag()

        static func marker(_ b: [UInt8], code: String) -> (UInt64, Int)? {
            let head = Array("\u{1b}]\(code);".utf8)
            guard b.starts(with: head), let bel = b[head.count...].firstIndex(of: 7),
                  let n = UInt64(String(decoding: b[head.count..<bel], as: UTF8.self)) else { return nil }
            return (n, bel + 1)
        }

        static func find(_ b: [UInt8], _ needle: [UInt8]) -> Int? {
            guard b.count >= needle.count else { return nil }
            return (0...(b.count - needle.count)).first { b[$0..<($0 + needle.count)].elementsEqual(needle) }
        }
        func onExit(code: Int32) {
            Task { @MainActor [weak owner, generation] in owner?.ended(code: code, generation: generation) }
        }
        func onLost() {
            Task { @MainActor [weak owner, generation] in owner?.lostShell(generation: generation) }
        }
    }

    private final class Delegate: NSObject, TerminalViewDelegate {
        weak var owner: TerminalSession?
        var onRestart: (() -> Void)?
        init(owner: TerminalSession) { self.owner = owner }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated {
                guard let owner else { return }
                if owner.exited, data.contains(13) { onRestart?() } else { owner.send(data) }
            }
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { owner?.resized(cols: newCols, rows: newRows) }
        }
        func setTerminalTitle(source: TerminalView, title: String) {
            MainActor.assumeIsolated { if !title.isEmpty { owner?.title = title } }
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            MainActor.assumeIsolated { owner?.openLink(link) }
        }
        func bell(source: TerminalView) { MainActor.assumeIsolated { owner?.bells += 1 } }
        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s }
        }
        func clipboardRead(source: TerminalView) -> Data? { UIPasteboard.general.string.map { Data($0.utf8) } }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    func setRestartHandler(_ f: @escaping () -> Void) { delegate?.onRestart = f }
}

/// Trackpad and mouse in the terminal, as on the desktop: click-drag selects
/// (two-finger scrolling still scrolls), right-click opens Copy / Paste.
/// Touch keeps SwiftTerm's own gestures: drag scrolls, long-press selects.
@MainActor
final class PointerSelection: NSObject, UIGestureRecognizerDelegate {
    private weak var view: TerminalView?
    private let grid: () -> (cols: Int, rows: Int)
    private var anchor: Position?

    init(_ view: TerminalView, grid: @escaping () -> (cols: Int, rows: Int)) {
        self.view = view
        self.grid = grid
        super.init()
        (view as? PadTerminalView)?.pointer = self
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pan.allowedScrollTypesMask = []
        pan.delegate = self
        view.addGestureRecognizer(pan)
        let menu = UITapGestureRecognizer(target: self, action: #selector(secondaryClick))
        menu.buttonMaskRequired = .secondary
        view.addGestureRecognizer(menu)
    }

    // ponytail: an app tracking the mouse (vim mouse=a, htop) doesn't get
    // trackpad drags; SwiftTerm doesn't expose the mouse mode to check.

    /// Buffer position of the cell boundary nearest `p` (view coordinates, so
    /// scrollback is included); a selection's end is exclusive.
    func position(_ p: CGPoint) -> Position? {
        guard let cell else { return nil }
        return Position(col: min(max(Int((p.x / cell.width).rounded()), 0), grid().cols), row: max(Int(p.y / cell.height), 0))
    }

    var cell: CGSize? {
        guard let view else { return nil }
        let (cols, rows) = grid()
        let frame = view.getOptimalFrameSize()
        guard cols > 0, rows > 0, frame.width > 0, frame.height > 0 else { return nil }
        return CGSize(width: frame.width / CGFloat(cols), height: frame.height / CGFloat(rows))
    }

    @objc private func drag(_ g: UIPanGestureRecognizer) {
        guard let view else { return }
        let p = g.location(in: view)
        switch g.state {
        case .began:
            // Start where the button went down, not where the drag was recognized.
            let t = g.translation(in: view)
            begin(at: CGPoint(x: p.x - t.x, y: p.y - t.y))
            extend(to: p)
        case .changed:
            extend(to: p)
        default:
            anchor = nil
        }
    }

    /// Also driven by the test scenario.
    func begin(at p: CGPoint) {
        _ = view?.becomeFirstResponder()
        anchor = position(p)
    }

    func extend(to p: CGPoint) {
        guard let view, let anchor, let end = position(p) else { return }
        view.setSelectionRange(start: anchor, end: end)
        // Dragging past the top or bottom edge scrolls, a row per event.
        let h = cell?.height ?? 0
        let top = view.contentOffset.y, maxY = max(0, view.contentSize.height - view.bounds.height)
        if p.y < top { view.contentOffset.y = max(0, top - h) }
        else if p.y > top + view.bounds.height { view.contentOffset.y = min(maxY, top + h) }
    }

    @objc private func secondaryClick(_ g: UITapGestureRecognizer) {
        view?.showStandardContextMenu(at: g.location(in: view))
    }

    /// SwiftTerm's own pans (selection handles, mouse reports) wait for this
    /// one, which only ever takes trackpad and mouse drags. Not the scroll
    /// view's pan: two-finger scrolling never reaches this one, so it would wait forever.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other is UIPanGestureRecognizer && other.view === view && other !== view?.panGestureRecognizer
    }

    /// A trackpad button is down: a drag now selects instead of scrolling.
    var pressed: Bool { press.map { $0.phase != .ended && $0.phase != .cancelled } ?? false }
    private weak var press: UITouch?
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        press = touch // only trackpad/mouse touches reach this recognizer
        return true
    }
}

/// Two-finger scrolling arrives as scroll events, with no touch; a click-drag
/// arrives as a touch. The scroll view's pan takes both, so it's refused while
/// a button is down.
///
/// Full-screen programs that track the mouse (Claude Code, vim with mouse=a,
/// htop, less with --mouse) scroll themselves on wheel events; their screen
/// has no scrollback. While one runs, trackpad scrolling becomes wheel reports
/// (sent through SwiftTerm's own wheel handler, which knows the encoding),
/// paced like a native scroll: one report per few rows of travel, then momentum.
final class PadTerminalView: TerminalView {
    weak var pointer: PointerSelection?
    /// SwiftTerm's one-finger wheel pan; it exists only while a program tracks the mouse.
    private(set) weak var wheel: UIPanGestureRecognizer?
    /// Two-finger trackpad scrolling, for such a program.
    private(set) lazy var scrollPan: UIPanGestureRecognizer = {
        let g = UIPanGestureRecognizer(target: self, action: #selector(scrolled))
        g.allowedScrollTypesMask = .all
        g.allowedTouchTypes = [] // scroll events only
        return g
    }()
    private let feed = FeedPan()
    private let press = PressRecognizer()
    /// This press is the one that gave the terminal the keyboard.
    private var focusingPress = false
    private var momentum: CADisplayLink?
    private var velocity: CGFloat = 0
    private var lastTick: CFTimeInterval = 0

    /// Claude Code and vim scroll 3 rows per wheel report: one report per 3 rows
    /// of finger travel keeps the text under the fingers.
    static let rowsPerReport: CGFloat = 3

    /// Take the keyboard as soon as this view is in a window (the panel just opened).
    var focusOnAttach = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Right as the panel's first frame is built, so UIKit's keyboard rebuild
        // (~45 ms) delays the slide's start instead of stalling it halfway.
        if window != nil, focusOnAttach {
            focusOnAttach = false
            _ = becomeFirstResponder()
        }
        if scrollPan.view == nil { super.addGestureRecognizer(scrollPan) }
        if press.view == nil {
            // The keyboard comes here the moment a finger or button goes down,
            // as on the desktop. SwiftTerm's tap only fires once double- and
            // triple-click detection gives up, and with a program that tracks the
            // mouse (Claude Code) it passed the click on without taking focus.
            press.onPress = { [weak self] in
                guard let self else { return }
                focusingPress = !isFirstResponder
                if focusingPress { _ = becomeFirstResponder() }
            }
            super.addGestureRecognizer(press)
        }
        if feed.view == nil { super.addGestureRecognizer(feed) } // SwiftTerm's handler wants an attached recognizer
    }

    override func addGestureRecognizer(_ g: UIGestureRecognizer) {
        // The only single-touch pan SwiftTerm adds (enableMousePanGesture).
        if let pan = g as? UIPanGestureRecognizer, pan.maximumNumberOfTouches == 1, pan !== panGestureRecognizer { wheel = pan }
        super.addGestureRecognizer(g)
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        let tracking = wheel?.view === self
        if g === scrollPan { return tracking }
        // The focusing click only focuses (no Copy/Paste menu by the cursor),
        // unless a program wants the click.
        if focusingPress, !tracking, let tap = g as? UITapGestureRecognizer, tap.numberOfTapsRequired == 1,
           tap.buttonMaskRequired == .primary { return false }
        if g === panGestureRecognizer, g.numberOfTouches > 0, pointer?.pressed == true { return false }
        if g === panGestureRecognizer, g.numberOfTouches == 0, tracking { return false }
        return super.gestureRecognizerShouldBegin(g)
    }

    /// A finger or button going down, as the test scenario drives it.
    func simulatePress() { press.onPress() }

    var onFind: () -> Void = {}
    override var keyCommands: [UIKeyCommand]? {
        let find = UIKeyCommand(input: "f", modifierFlags: .command, action: #selector(findKey))
        let clear = UIKeyCommand(input: "k", modifierFlags: .command, action: #selector(clearTerminal))
        find.wantsPriorityOverSystemBehavior = true
        clear.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [find, clear]
    }
    @objc private func findKey() { onFind() }

    /// ⌘K, as in VS Code: the scrollback goes and the shell redraws its prompt at the top.
    /// ponytail: Ctrl-L goes to whatever's running; a busy program gets it instead of the shell.
    @objc func clearTerminal() {
        clearScrollback()
        send(txt: "\u{0C}")
    }

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        wheelScroll(g.state, travel: t.y, velocity: g.velocity(in: self).y, at: g.location(in: self))
    }

    /// Also driven by the test scenario.
    func wheelScroll(_ state: UIGestureRecognizer.State, travel: CGFloat, velocity v: CGFloat = 0, at p: CGPoint) {
        feed.point = p
        switch state {
        case .began:
            stopMomentum()
            deliver(.began, 0)
            deliver(.changed, travel)
        case .changed:
            deliver(.changed, travel)
        case .ended where abs(v) > 50:
            velocity = v
            lastTick = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(coast))
            link.add(to: .main, forMode: .common)
            momentum = link
        default:
            deliver(.ended, 0)
        }
    }

    /// UIScrollView's normal deceleration (0.998 per ms), until it's barely moving.
    @objc private func coast(_ link: CADisplayLink) {
        let dt = min(link.timestamp - lastTick, 0.05)
        lastTick = link.timestamp
        velocity *= pow(0.998, dt * 1000)
        guard abs(velocity) > 30 else { return stopMomentum() }
        deliver(.changed, velocity * dt)
    }

    private func stopMomentum() {
        guard let momentum else { return }
        momentum.invalidate()
        self.momentum = nil
        deliver(.ended, 0)
    }

    private func deliver(_ state: UIGestureRecognizer.State, _ travel: CGFloat) {
        let handler = NSSelectorFromString("panMouseHandler:") // SwiftTerm 1.99 (pinned)
        guard responds(to: handler) else { return }
        feed.state = state
        feed.dy = travel / Self.rowsPerReport
        perform(handler, with: feed)
    }
}

/// Reports a press as it starts, then steps aside for the other recognizers.
private final class PressRecognizer: UIGestureRecognizer {
    var onPress: () -> Void = {}
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onPress()
        state = .failed
    }
}

/// A pan whose translation, location and state we set, read by SwiftTerm's
/// wheel handler. Disabled, so it never sees real touches.
private final class FeedPan: UIPanGestureRecognizer {
    var dy: CGFloat = 0
    var point = CGPoint.zero
    // Its own state: UIKit ignores state changes on a disabled recognizer on newer iPadOS.
    private var fed = UIGestureRecognizer.State.possible
    override var state: UIGestureRecognizer.State { get { fed } set { fed = newValue } }
    init() { super.init(target: nil, action: nil); isEnabled = false }
    override func translation(in view: UIView?) -> CGPoint { CGPoint(x: 0, y: dy) }
    override func setTranslation(_ translation: CGPoint, in view: UIView?) { dy = translation.y }
    override func location(in view: UIView?) -> CGPoint { point }
}

/// A window with only terminals in it (Terminal: Move Terminal into New Window).
/// One row on top, like Terminal.app: the tabs, then New / Split… / Kill.
struct TerminalWindowView: View {
    @StateObject var wb: Workbench
    var target: Binding<TerminalWindowTarget?>
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var phase
    @State private var window: UIWindow?

    var body: some View {
        let t = wb.theme
        VStack(spacing: 0) {
            TerminalPanel().frame(maxHeight: .infinity, alignment: .top)
        }
        .avoidKeyboard()
        .background(Color(t.terminalBg))
        .background(WindowProbe { window = $0 })
        .overlay { if wb.desktop == nil { ConnectingOverlay() } }
        .environmentObject(wb)
        .environmentObject(wb.languages)
        .environmentObject(wb.editorStatus)
        .focusedSceneObject(wb)
        .preferredColorScheme(t.isDark ? .dark : .light)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { if wb.desktop == nil { await wb.connect() } }
        .onAppear {
            wb.openWindowAction = openWindow
            wb.dismissWindow = { dismissWindow() }
        }
        .onChange(of: phase) { _, p in
            if p == .active { Task { await wb.reconnectIfNeeded() } }
        }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await wb.reconnectIfNeeded()
            }
        }
        // The window remembers its shells, so a relaunch reattaches them;
        // closing the last one closes the window (even one in the background).
        .onChange(of: wb.terminals.map(\.persistentID)) { _, ids in target.wrappedValue?.terminals = ids }
        // The name iPadOS shows for this window (App Exposé, the window menu).
        .onChange(of: windowTitle, initial: true) { _, title in window?.windowScene?.title = title }
        .onChange(of: window) { _, w in
            wb.scene = w?.windowScene
            w?.windowScene?.title = windowTitle
        }
    }

    private var windowTitle: String {
        let active = wb.terminals.first { $0.id == wb.activeTerminal }?.title ?? "Terminal"
        return "\(active) — \(wb.machine.name)"
    }
}

/// Hosts a session's existing TerminalView inside SwiftUI.
struct TerminalHost: UIViewRepresentable {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var wb: Workbench
    @ObservedObject private var keyboard = KeyboardState.shared

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if session.view.superview !== container { attach(to: container) }
        session.apply(theme: wb.theme, fontSize: AppSettings.shared.terminalFontSize.map { CGFloat($0) } ?? wb.fontSize)
        session.setKeyBar(visible: !keyboard.hardware)
        container.backgroundColor = wb.theme.terminalBg
        DispatchQueue.main.async { [session, wb] in
            session.setRestartHandler { [weak session, weak wb] in
                guard let session, let wb else { return }
                session.restart(wb)
            }
            session.workbench = wb
            session.autoStart(wb)
        }
    }

    private func attach(to container: UIView) {
        let v = session.view
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// VS Code's bottom panel: PROBLEMS and TERMINAL tabs; terminal tabs on the right.
struct TerminalPanel: View {
    @EnvironmentObject var wb: Workbench
    @EnvironmentObject var languages: Languages
    /// The active tab's highlight and underline slide between tabs.
    @Namespace private var tabs

    var body: some View {
        let t = wb.theme
        let problems = languages.counts.errors + languages.counts.warnings
        let window = wb.terminalsOnly != nil
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if !window {
                    // A segmented pill; the selection slides between segments.
                    HStack(spacing: 2) {
                        panelTab("Problems", .problems, badge: problems)
                        panelTab("Terminal", .terminal, badge: 0)
                        panelTab("Ports", .ports, badge: wb.forwards.count)
                    }
                    .padding(2)
                    .background(t.hoverFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(t.cardBorder))
                    .animation(Motion.pop, value: wb.panelTab)
                    Spacer(minLength: 8)
                }
                if wb.panelTab == .terminal {
                    // Tabs while they fit, else VS Code's "2: zsh ⌄" dropdown; the icons never shrink.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 2) {
                            ForEach(wb.terminals) {
                                TerminalTab(session: $0, highlight: tabs).transition(.scale(scale: 0.85, anchor: .leading).combined(with: .opacity))
                            }
                        }
                        .animation(.snappy(duration: 0.22), value: wb.terminals.map(\.id))
                        .animation(.snappy(duration: 0.2), value: wb.activeTerminal)
                        TerminalPicker(titled: true)
                        TerminalPicker(titled: false)
                    }
                    .layoutPriority(1)
                }
                // A terminal window's tabs start at the left, like Terminal.app's.
                if window { Spacer(minLength: 8) }
                HStack(spacing: 2) {
                    if wb.panelTab == .terminal {
                        Button { wb.newTerminal() } label: { CodiconView(icon: .add) }.fixedSize()
                            .tip(wb.terminalsOnly != nil ? "New Terminal Tab (⌘T)" : "New Terminal")
                        if wb.terminalsOnly != nil {
                            if let editor = wb.editorWindow, let id = wb.activeTerminal {
                                Button { wb.moveTerminalToEditorWindow(id) } label: { CodiconView(icon: .layoutPanel) }.fixedSize()
                                    .tip("Move Terminal into Editor Window (\(editor.root.isEmpty ? editor.machine.name : editor.baseName(editor.root)))")
                            }
                        } else if let id = wb.activeTerminal {
                            Button { wb.moveTerminalToNewWindow(id) } label: { CodiconView(icon: .multipleWindows) }.fixedSize()
                                .tip("Move Terminal into New Window")
                        }
                        Button {
                            if let id = wb.activeTerminal { wb.killTerminal(id) }
                        } label: { CodiconView(icon: .trash) }.fixedSize().tip("Kill Terminal")
                    }
                    if wb.terminalsOnly == nil {
                        // Snaps rather than animates: a terminal resized every frame reflows every frame.
                        Button { wb.panelMaximized.toggle() } label: {
                            Image(systemName: wb.panelMaximized ? "chevron.down" : "chevron.up").font(.system(size: 12, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 16, height: 16)
                        }
                        .fixedSize().tip(wb.panelMaximized ? "Restore Panel Size" : "Maximize Panel Size")
                        Button { wb.hidePanel() } label: { CodiconView(icon: .close) }.fixedSize().tip("Hide Panel")
                    }
                }
                .fixedSize()
            }
            .buttonStyle(ToolbarButtonStyle())
            .foregroundStyle(t.panelTitleInactiveFg)
            .padding(.horizontal, 10)
            .background(window ? t.canvasBg : .clear)
            .frame(height: 38)

            ZStack {
                // Terminals stay alive (and keep their views) while Problems shows.
                ForEach(wb.terminals) { s in
                    let shown = wb.panelTab == .terminal && s.id == wb.activeTerminal
                    // Hidden ones keep their size: resizing reflows a terminal's
                    // whole buffer, which made every pane drag pay for each one.
                    let b = s.view.bounds.size
                    let frozen = !shown && b.width > 100 && b.height > 40
                    TerminalHost(session: s)
                        .frame(width: frozen ? b.width + 8 : nil, height: frozen ? b.height + 4 : nil)
                        // …but a kept size must never size the panel: one left wider (the
                        // side bar since opened) widened the panel and pushed the window sideways.
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                }
                if wb.panelTab == .terminal, let s = wb.terminals.first(where: { $0.id == wb.activeTerminal }) {
                    TerminalFind(session: s)
                }
                if wb.panelTab == .problems {
                    ProblemsView().background(t.panelBg)
                }
                if wb.panelTab == .ports {
                    PortsView().background(t.panelBg)
                }
            }
        }
        .background(t.panelBg)
    }

    private func panelTab(_ title: String, _ tab: PanelTab, badge: Int) -> some View {
        let t = wb.theme
        let active = wb.panelTab == tab
        return Button { wb.panelTab = tab } label: {
            Hovering { on in
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 12, weight: active ? .semibold : .medium))
                    if badge > 0 {
                        Text("\(badge)").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).frame(minWidth: 16, minHeight: 15)
                            .background(t.activityBadgeBg).foregroundStyle(.white).clipShape(Capsule())
                            .contentTransition(.numericText())
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .foregroundStyle(active || on ? t.panelTitleActiveFg : t.panelTitleInactiveFg)
                .padding(.horizontal, 11).frame(height: 24)
                .background {
                    if active {
                        Capsule().fill(t.raised)
                            .matchedGeometryEffect(id: "panel-segment", in: tabs)
                    }
                }
                .fixedSize()
                .contentShape(Capsule())
                .animation(Motion.pop, value: badge)
            }
        }
        .buttonStyle(PressDown())
        .hoverEffectDisabled()
    }
}

/// VS Code's terminal find widget: ↩ / ⇧↩ step through matches in the scrollback.
private struct TerminalFind: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var wb: Workbench
    @State private var query = ""
    @State private var count = (index: 0, total: 0)
    @FocusState private var focused: Bool

    var body: some View {
        // The panel watches the workbench, not each shell: this view shows itself.
        ZStack {
            if session.finding {
                bar.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.18), value: session.finding)
    }

    private var bar: some View {
        let t = wb.theme
        return HStack(spacing: 2) {
            TextField("Find", text: $query)
                .textFieldStyle(.plain).font(.system(size: 13))
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused($focused)
                .onSubmit { step(forward: true); focused = true }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    step(forward: false)
                    return .handled
                }
                .onKeyPress(.escape) { close(); return .handled }
                .padding(.horizontal, 6).frame(width: 180, height: 24)
                .background(t.inputBg).overlay(RoundedRectangle(cornerRadius: 2).stroke(focused ? t.focusBorder : t.inputBorder))
            Text(query.isEmpty ? "" : count.total == 0 ? "No results" : "\(count.index) of \(count.total)")
                .font(.system(size: 12)).foregroundStyle(count.total == 0 && !query.isEmpty ? t.errorFg : t.descriptionFg)
                .frame(minWidth: 70)
            Button { step(forward: false) } label: { CodiconView(icon: .arrowUp) }.tip("Previous Match (⇧↩)")
            Button { step(forward: true) } label: { CodiconView(icon: .arrowDown) }.tip("Next Match (↩)")
            Button { close() } label: { CodiconView(icon: .close) }.tip("Close (Escape)")
        }
        .buttonStyle(ToolbarButtonStyle())
        .padding(4)
        .glass(t.ui("editorWidget.background", default: "#252526"), radius: 12)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(t.widgetBorder))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        .onAppear { focused = true }
        .onChange(of: query) { _, q in
            // Searching from the bottom as you type, like VS Code.
            session.view.clearSearch()
            if !q.isEmpty { step(forward: false) } else { count = (0, 0) }
        }
    }

    private func step(forward: Bool) {
        guard !query.isEmpty else { return }
        if forward { session.view.findNext(query) } else { session.view.findPrevious(query) }
        count = session.view.searchMatchSummary(query)
    }

    private func close() {
        session.view.clearSearch()
        session.finding = false
        _ = session.view.becomeFirstResponder()
    }
}

private struct TerminalTab: View {
    @ObservedObject var session: TerminalSession
    let highlight: Namespace.ID
    @EnvironmentObject var wb: Workbench
    @State private var flash = false
    var body: some View {
        let active = session.id == wb.activeTerminal
        Hovering { on in
            HStack(spacing: 4) {
                CodiconView(icon: session.exited ? .debugDisconnect : wb.env?.os == .windows ? .terminalPowershell : .terminal, size: 14)
                    .foregroundStyle(session.exited ? wb.theme.descriptionFg : .primary)
                    .overlay(alignment: .topTrailing) {
                        if session.unread && !active {
                            Circle().fill(wb.theme.ui("activityBarBadge.background", default: "#007acc")).frame(width: 6, height: 6)
                                .offset(x: 2, y: -1).transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.snappy(duration: 0.2), value: session.unread && !active)
                // Long titles (e.g. a running command) are cut, so a tab never grows past ~24 characters.
                Text(session.title.count > 24 ? session.title.prefix(23) + "…" : session.title).font(.system(size: 12)).lineLimit(1)
                // VS Code's trash-can "Kill Terminal", on the active or hovered tab.
                Button { wb.killTerminal(session.id) } label: { CodiconView(icon: .close, size: 12) }
                    .buttonStyle(ToolbarButtonStyle(padding: 1))
                    .opacity(active || on ? 1 : 0)
                    .tip("Kill Terminal")
            }
            .padding(.leading, 6).padding(.trailing, 2).padding(.vertical, 2)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(wb.theme.raised)
                        .matchedGeometryEffect(id: "terminal-tab", in: highlight)
                } else if on {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(wb.theme.hoverFill)
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(wb.theme.accent.opacity(flash ? 0.35 : 0)) }
            .foregroundStyle(active || on ? wb.theme.panelTitleActiveFg : wb.theme.panelTitleInactiveFg)
            .contentShape(Rectangle())
            .onTapGesture { wb.focusTerminal(session.id) }
        }
        .fixedSize()
        .onChange(of: session.bells) {
            withAnimation(.easeOut(duration: 0.08)) { flash = true }
            withAnimation(.easeIn(duration: 0.4).delay(0.12)) { flash = false }
        }
        .onChange(of: active) { _, a in if a { session.unread = false } }
        .contextMenu {
            Button { wb.moveTerminalToNewWindow(session.id) } label: { Label("Move Terminal into New Window", systemImage: "macwindow.badge.plus") }
            if wb.terminalsOnly != nil, wb.editorWindow != nil {
                Button { wb.moveTerminalToEditorWindow(session.id) } label: { Label("Move Terminal into Editor Window", systemImage: "rectangle.bottomhalf.inset.filled") }
            }
            Button("Kill Terminal", role: .destructive) { wb.killTerminal(session.id) }
            Button("Kill All Terminals", role: .destructive) { for t in wb.terminals { wb.killTerminal(t.id) } }
        }
    }
}

/// The terminal tabs folded into one menu, for a narrow panel.
private struct TerminalPicker: View {
    let titled: Bool
    @EnvironmentObject var wb: Workbench
    var body: some View {
        let index = wb.terminals.firstIndex { $0.id == wb.activeTerminal }
        Menu {
            ForEach(Array(wb.terminals.enumerated()), id: \.element.id) { i, s in
                Button { wb.focusTerminal(s.id) } label: {
                    if s.id == wb.activeTerminal { Label("\(i + 1): \(s.title)", systemImage: "checkmark") } else { Text("\(i + 1): \(s.title)") }
                }
            }
            if let id = wb.activeTerminal {
                Divider()
                Button("Move Terminal into New Window") { wb.moveTerminalToNewWindow(id) }
                Button("Kill Terminal", role: .destructive) { wb.killTerminal(id) }
            }
        } label: {
            HStack(spacing: 3) {
                CodiconView(icon: wb.env?.os == .windows ? .terminalPowershell : .terminal, size: 14)
                if let index { Text(titled ? "\(index + 1): \(wb.terminals[index].title)" : "\(index + 1)").font(.system(size: 12)).lineLimit(1) }
                CodiconView(icon: .chevronDown, size: 12)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .hoverBackground(wb.theme.listHoverBg, cornerRadius: 5)
            .foregroundStyle(wb.theme.panelTitleActiveFg)
        }
        .hoverEffectDisabled()
        .fixedSize()
    }
}

/// Thread-safe byte count (written on the core's thread, read on the main actor).
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    /// Sets the flag, returning what it was.
    @discardableResult func swap(_ v: Bool) -> Bool { lock.lock(); defer { lock.unlock() }; let old = on; on = v; return old }
}

final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n: UInt64 = 0
    var value: UInt64 {
        get { lock.lock(); defer { lock.unlock() }; return n }
        set { lock.lock(); n = newValue; lock.unlock() }
    }
    func add(_ k: UInt64) { lock.lock(); n += k; lock.unlock() }
}
