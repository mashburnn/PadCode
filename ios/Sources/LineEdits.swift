import Foundation

/// VS Code's line commands as plain text transforms on UTF-16 offsets (NSRange),
/// so they can be applied to the editor as one undoable replace.
enum LineEdit {
    case toggleComment
    case deleteLines
    case copyLines(down: Bool)
    case insertLine(below: Bool)

    struct Result: Equatable {
        var range: NSRange
        var text: String
        var selection: NSRange
    }

    /// Comment syntax by file name: a line token, or a block pair for languages
    /// without one (VS Code's ⌘/ wraps those lines in a block comment).
    static func comment(for name: String) -> (line: String?, block: (String, String)?) {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if ["makefile", "dockerfile", "gemfile", "rakefile", ".gitignore", ".env", ".zshrc", ".bashrc"].contains(lower) { return ("#", nil) }
        switch ext {
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm", "rs", "js", "jsx", "mjs", "cjs", "ts", "tsx", "go", "java",
             "kt", "kts", "swift", "cs", "scala", "dart", "php", "jsonc", "json5", "zig", "groovy", "gradle", "proto", "scss", "less", "glsl", "metal":
            return ("//", nil)
        case "py", "sh", "bash", "zsh", "fish", "rb", "pl", "r", "yaml", "yml", "toml", "conf", "cmake", "ps1", "psm1", "nim",
             "tf", "jl", "ex", "exs", "cr", "nix", "mk", "dockerfile", "properties", "gitignore", "env":
            return ("#", nil)
        case "lua", "sql", "hs", "elm", "ada": return ("--", nil)
        case "tex", "sty", "erl", "hrl": return ("%", nil)
        case "lisp", "clj", "cljs", "el", "scm", "ini", "asm", "s": return (";", nil)
        case "vb", "bas": return ("'", nil)
        case "css": return (nil, ("/*", "*/"))
        case "html", "htm", "xml", "svg", "md", "markdown", "vue", "plist": return (nil, ("<!--", "-->"))
        default: return (nil, nil)
        }
    }

    /// The whole lines a selection touches, without the last line's line break.
    /// A selection that ends at the start of a line doesn't include that line.
    private static func lines(_ s: NSString, _ sel: NSRange) -> NSRange {
        var end = NSMaxRange(sel)
        if sel.length > 0, end > sel.location, s.character(at: end - 1) == 10 { end -= 1 }
        let full = s.lineRange(for: NSRange(location: sel.location, length: end - sel.location))
        var len = full.length
        if len > 0, s.character(at: NSMaxRange(full) - 1) == 10 { len -= 1 }
        if len > 0, s.character(at: full.location + len - 1) == 13 { len -= 1 }
        return NSRange(location: full.location, length: len)
    }

    private static func indent(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    func apply(to s: NSString, selection sel: NSRange, fileName: String = "") -> Result? {
        let block = Self.lines(s, sel)
        let body = s.substring(with: block)
        switch self {
        case .toggleComment:
            let syntax = Self.comment(for: fileName)
            if let token = syntax.line { return Self.toggleLine(token, s, sel, block, body) }
            if let pair = syntax.block { return Self.toggleBlock(pair, sel, block, body) }
            return nil

        case .deleteLines:
            // Take the line break after the lines, or before them on the last line.
            var r = NSRange(location: block.location, length: NSMaxRange(s.lineRange(for: block)) - block.location)
            if NSMaxRange(block) == s.length, block.location > 0 {
                r = NSRange(location: block.location - 1, length: block.length + 1)
            }
            return Result(range: r, text: "", selection: NSRange(location: r.location, length: 0))

        case .copyLines(let down):
            // Insert a copy above; "down" keeps the selection on the lower one.
            let copy = body + "\n"
            let shift = down ? (copy as NSString).length : 0
            return Result(range: NSRange(location: block.location, length: 0), text: copy,
                          selection: NSRange(location: sel.location + shift, length: sel.length))

        case .insertLine(let below):
            let line = s.substring(with: Self.lines(s, NSRange(location: below ? NSMaxRange(sel) : sel.location, length: 0)))
            let lead = Self.indent(of: line)
            if below {
                let at = NSMaxRange(Self.lines(s, NSRange(location: NSMaxRange(sel), length: 0)))
                let text = "\n" + lead
                return Result(range: NSRange(location: at, length: 0), text: text,
                              selection: NSRange(location: at + (text as NSString).length, length: 0))
            }
            let at = Self.lines(s, NSRange(location: sel.location, length: 0)).location
            let text = lead + "\n"
            return Result(range: NSRange(location: at, length: 0), text: text,
                          selection: NSRange(location: at + (lead as NSString).length, length: 0))
        }
    }

    private static func toggleLine(_ token: String, _ s: NSString, _ sel: NSRange, _ block: NSRange, _ body: String) -> Result {
        var rows = body.components(separatedBy: "\n")
        let filled = rows.indices.filter { !rows[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        let commented = !filled.isEmpty && filled.allSatisfy {
            rows[$0].drop { $0 == " " || $0 == "\t" }.hasPrefix(token)
        }
        // Comment at the smallest indentation, like VS Code.
        let column = filled.map { indent(of: rows[$0]).utf16.count }.min() ?? 0
        var firstDelta = 0, firstColumn = 0
        for i in (filled.isEmpty ? Array(rows.indices) : filled) {
            let row = rows[i] as NSString
            if commented {
                let at = indent(of: rows[i]).utf16.count
                var cut = (token as NSString).length
                if at + cut < row.length, row.character(at: at + cut) == 32 { cut += 1 }
                rows[i] = row.replacingCharacters(in: NSRange(location: at, length: cut), with: "")
                if i == 0 { firstDelta = -cut; firstColumn = at }
            } else {
                let at = min(column, row.length)
                rows[i] = row.replacingCharacters(in: NSRange(location: at, length: 0), with: token + " ")
                if i == 0 { firstDelta = (token as NSString).length + 1; firstColumn = at }
            }
        }
        let text = rows.joined(separator: "\n")
        let newLength = (text as NSString).length
        let selection: NSRange
        if sel.length == 0 {
            // Keep the caret on the same character.
            let col = sel.location - block.location
            let moved = col >= firstColumn ? max(col + firstDelta, firstColumn) : col
            selection = NSRange(location: block.location + moved, length: 0)
        } else {
            selection = NSRange(location: block.location, length: newLength)
        }
        return Result(range: block, text: text, selection: selection)
    }

    private static func toggleBlock(_ pair: (String, String), _ sel: NSRange, _ block: NSRange, _ body: String) -> Result {
        let (open, close) = pair
        let lead = indent(of: body)
        let inner = body.dropFirst(lead.count)
        let text: String
        if inner.hasPrefix(open), body.trimmingCharacters(in: .whitespaces).hasSuffix(close) {
            var t = String(inner.dropFirst(open.count))
            if t.hasPrefix(" ") { t.removeFirst() }
            while t.last == " " || t.last == "\t" { t.removeLast() }
            t = String(t.dropLast(close.count))
            if t.hasSuffix(" ") { t.removeLast() }
            text = lead + t
        } else {
            text = lead + open + " " + inner + " " + close
        }
        let length = (text as NSString).length
        let selection = sel.length == 0
            ? NSRange(location: min(sel.location, block.location + length), length: 0)
            : NSRange(location: block.location, length: length)
        return Result(range: block, text: text, selection: selection)
    }
}

/// VS Code's matching-bracket highlight: the bracket touching the caret
/// (before it first) and its partner, by depth counting.
enum Brackets {
    private static let pairs: [unichar: (unichar, Int)] = [40: (41, 1), 91: (93, 1), 123: (125, 1), 41: (40, -1), 93: (91, -1), 125: (123, -1)]

    // ponytail: counts brackets inside strings/comments too; use tree-sitter nodes if that misleads.
    static func match(_ s: NSString, caret: Int, limit: Int = 20_000) -> (Int, Int)? {
        for at in [caret - 1, caret] where at >= 0 && at < s.length {
            guard let (partner, dir) = pairs[s.character(at: at)] else { continue }
            let me = s.character(at: at)
            var depth = 0, i = at + dir
            let stop = dir > 0 ? min(s.length, at + limit) : max(-1, at - limit)
            while i != stop {
                let c = s.character(at: i)
                if c == me { depth += 1 } else if c == partner {
                    if depth == 0 { return (min(at, i), max(at, i)) }
                    depth -= 1
                }
                i += dir
            }
        }
        return nil
    }
}
