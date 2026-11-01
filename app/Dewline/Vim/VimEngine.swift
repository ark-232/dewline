import Foundation

enum VimMode {
    case normal, insert, visual, visualLine
}

/// The text Vim edits and the app around it. Each `vimReplace` is one undoable edit.
@MainActor protocol VimHost: AnyObject {
    var vimText: NSString { get }
    var vimSelection: NSRange { get set }
    /// The system clipboard, the `+` register.
    var vimClipboard: String? { get set }
    func vimReplace(_ range: NSRange, with string: String)
    func vimUndo()
    func vimRedo()
    func vimSave()
    func vimClose()
}

/// Vim's keys over a host's text and selection, with no window. A key is one character or one of `<Esc>`, `<CR>`,
/// `<BS>`, `<C-r>`, `<Left>`, `<Right>`, `<Up>` and `<Down>`. In insert mode the host takes every key but `<Esc>`.
@MainActor final class VimEngine {
    private(set) var mode = VimMode.normal
    private var keys: [String] = []
    private var commandLine: String?
    private var registers: [String: Register] = [:]
    private var lastChange: Change?
    private var recording: Change?
    private var replaying = false
    private var edits = 0
    private var insertStart = 0
    private var insertLength = 0
    private var anchor = 0
    private var cursor = 0
    private var search: (pattern: String, forward: Bool)?
    private var text = VimText(string: NSString())

    private struct Register {
        var text: String
        var linewise: Bool
    }

    /// What `.` repeats: the command's keys without its counts, its count, and the text its insert typed.
    private struct Change {
        var keys: [String]
        var count: Int?
        var inserted: String?
    }

    private struct Command {
        var register: String?
        var count: Int?
        var name: String
        var motion: String?
        var argument: String?
        var keys: [String]
    }

    private enum Parse { case pending, invalid, command(Command) }
    private enum Kind { case exclusive, inclusive, linewise }

    private static let arrows = ["<Left>": "h", "<Right>": "l", "<Up>": "k", "<Down>": "j"]

    /// The mode, or the search or command line being typed, with any keys of an unfinished command.
    var status: String {
        if let commandLine { return commandLine }
        let name = switch mode {
        case .normal: "NORMAL"
        case .insert: "INSERT"
        case .visual: "VISUAL"
        case .visualLine: "VISUAL LINE"
        }
        return keys.isEmpty ? name : name + "  " + keys.joined()
    }

    func handle(_ key: String, in host: VimHost) {
        text = VimText(string: host.vimText)
        if mode == .insert {
            if key == "<Esc>" { finishInsert(host) }
            return
        }
        if commandLine != nil { return editCommandLine(key, host) }
        keys.append(Self.arrows[key] ?? key)
        switch parse() {
        case .pending:
            return
        case .invalid:
            keys = []
        case .command(let command):
            keys = []
            run(command, host)
        }
    }

    // MARK: Parsing

    private func parse() -> Parse {
        let keys = self.keys
        var i = 0
        var taken: [String] = []
        func take() -> String? {
            guard i < keys.count else { return nil }
            i += 1
            taken.append(keys[i - 1])
            return keys[i - 1]
        }
        func count() -> Int? {
            var digits = ""
            while i < keys.count, keys[i].count == 1, let digit = keys[i].first, digit.isASCII, digit.isNumber, digit != "0" || !digits.isEmpty {
                digits.append(digit)
                i += 1
            }
            return Int(digits)
        }
        enum Found { case pending, invalid, motion(String, String?) }
        func motion(_ key: String, objects: Bool) -> Found {
            switch key {
            case "h", "j", "k", "l", "w", "b", "e", "0", "^", "$", "G", "%", "n", "N":
                return .motion(key, nil)
            case "g":
                guard let next = take() else { return .pending }
                return next == "g" ? .motion("gg", nil) : .invalid
            case "f", "t":
                guard let next = take() else { return .pending }
                return next.count == 1 ? .motion(key, next) : .invalid
            case "i" where objects, "a" where objects:
                guard let next = take() else { return .pending }
                return ["w", "\"", "(", ")", "b", "p"].contains(next) ? .motion(key + next, nil) : .invalid
            default:
                return .invalid
            }
        }

        var register: String?
        if keys.first == "\"" {
            _ = take()
            guard let name = take() else { return .pending }
            register = name
        }
        let first = count()
        guard let key = take() else { return .pending }
        func command(_ name: String, _ count: Int?, motion: String? = nil, argument: String? = nil) -> Parse {
            .command(Command(register: register, count: count, name: name, motion: motion, argument: argument, keys: taken))
        }
        let visual = mode != .normal
        if ["d", "c", "y", ">", "<"].contains(key) || visual && key == "x" {
            if visual { return command(key == "x" ? "d" : key, first) }
            let second = count()
            guard let next = take() else { return .pending }
            let total = first == nil && second == nil ? nil : (first ?? 1) * (second ?? 1)
            if next == key { return command(key, total, motion: "line") }
            switch motion(next, objects: true) {
            case .pending: return .pending
            case .invalid: return .invalid
            case .motion(let name, let argument): return command(key, total, motion: name, argument: argument)
            }
        }
        if key == "r", !visual {
            guard let next = take() else { return .pending }
            return next.count == 1 ? command("r", first, argument: next) : .invalid
        }
        switch motion(key, objects: visual) {
        case .pending: return .pending
        case .motion(let name, let argument): return command("move", first, motion: name, argument: argument)
        case .invalid: break
        }
        let allowed: Set<String> = visual
            ? ["v", "V", "o", "<Esc>"]
            : ["x", "o", "O", "J", "p", "P", "u", "<C-r>", ".", "i", "a", "I", "A", "v", "V", "/", "?", ":", "<Esc>"]
        return allowed.contains(key) ? command(key, first) : .invalid
    }

    private static func isObject(_ motion: String) -> Bool {
        motion.count == 2 && (motion.hasPrefix("i") || motion.hasPrefix("a"))
    }

    // MARK: Commands

    private func run(_ command: Command, _ host: VimHost) {
        let started = mode
        let editsBefore = edits
        let count = command.count ?? 1
        let at = started == .normal ? text.normal(host.vimSelection.location) : cursor
        switch command.name {
        case "move":
            let motion = command.motion!
            if Self.isObject(motion) {
                guard let (range, linewise) = object(motion, at: at), range.length > 0 else { break }
                anchor = range.location
                cursor = text.previous(NSMaxRange(range))
                if linewise { mode = .visualLine }
            } else if let target = target(motion, command.argument, command.count, from: at, operating: false) {
                if started == .normal { place(target.position, host) } else { cursor = text.normal(target.position) }
            }
        case "d", "c", "y", ">", "<":
            let covered: (NSRange, Bool)? = started == .normal ? span(command, at: at) : (visualRange(), mode == .visualLine)
            mode = .normal
            guard let (range, linewise) = covered else { break }
            apply(command.name, range, linewise: linewise, register: command.register, at: started == .normal ? at : min(anchor, cursor), host)
        case "x":
            let end = text.lineEnd(at)
            var stop = at
            for _ in 0..<count where stop < end { stop = text.next(stop) }
            guard stop > at else { break }
            apply("d", NSRange(location: at, length: stop - at), linewise: false, register: command.register, at: at, host)
        case "r":
            let end = text.lineEnd(at)
            var stop = at
            for _ in 0..<count {
                guard stop < end else { return }
                stop = text.next(stop)
            }
            let character = command.argument!
            replace(NSRange(location: at, length: stop - at), with: String(repeating: character, count: count), host)
            place(at + (count - 1) * character.utf16.count, host)
        case "o" where started != .normal:
            swap(&anchor, &cursor)
        case "o":
            let end = text.lineEnd(at)
            replace(NSRange(location: end, length: 0), with: "\n", host)
            enterInsert(at: end + 1, host)
        case "O":
            let start = text.lineStart(at)
            replace(NSRange(location: start, length: 0), with: "\n", host)
            enterInsert(at: start, host)
        case "J":
            var line = at
            var joint: Int?
            for _ in 0..<max(count - 1, 1) {
                guard let next = text.nextLine(line) else { break }
                let end = text.lineEnd(line)
                let first = text.nonBlank(next)
                let bare = first == text.lineEnd(next) || end == text.lineStart(line) || text.isBlank(end - 1) || text.char(first) == 41
                replace(NSRange(location: end, length: first - end), with: bare ? "" : " ", host)
                joint = end
                line = end
            }
            if let joint { place(joint, host) }
        case "p", "P":
            guard let pasted = register(command.register, host), !pasted.text.isEmpty else { break }
            let body = String(repeating: pasted.text, count: count)
            if pasted.linewise {
                if command.name == "P" {
                    let start = text.lineStart(at)
                    replace(NSRange(location: start, length: 0), with: body, host)
                    place(text.nonBlank(start), host)
                } else {
                    let end = text.fullLineEnd(at)
                    if end == text.length, end == 0 || text.char(end - 1) != 10 {
                        replace(NSRange(location: end, length: 0), with: "\n" + body.dropLast(), host)
                        place(text.nonBlank(end + 1), host)
                    } else {
                        replace(NSRange(location: end, length: 0), with: body, host)
                        place(text.nonBlank(end), host)
                    }
                }
            } else {
                let position = command.name == "p" && at < text.lineEnd(at) ? text.next(at) : at
                replace(NSRange(location: position, length: 0), with: body, host)
                place(text.previous(position + body.utf16.count), host)
            }
        case "u", "<C-r>":
            for _ in 0..<count {
                if command.name == "u" { host.vimUndo() } else { host.vimRedo() }
            }
            place(host.vimSelection.location, host)
        case ".":
            repeatChange(count: command.count, host)
        case "i":
            enterInsert(at: at, host)
        case "a":
            enterInsert(at: at < text.lineEnd(at) ? text.next(at) : at, host)
        case "I":
            enterInsert(at: text.nonBlank(at), host)
        case "A":
            enterInsert(at: text.lineEnd(at), host)
        case "v", "V":
            let wanted: VimMode = command.name == "v" ? .visual : .visualLine
            if started == wanted {
                mode = .normal
                place(cursor, host)
            } else {
                if started == .normal {
                    anchor = at
                    cursor = at
                }
                mode = wanted
            }
        case "/", "?", ":":
            commandLine = command.name
        default:
            if started != .normal {
                mode = .normal
                place(cursor, host)
            }
        }
        if mode == .visual || mode == .visualLine { host.vimSelection = visualRange() }
        let repeatable = !["u", "<C-r>", "."].contains(command.name)
        if started == .normal, !replaying, repeatable, edits > editsBefore || mode == .insert {
            let change = Change(keys: command.keys, count: command.count)
            if mode == .insert { recording = change } else { lastChange = change }
        }
    }

    private func repeatChange(count: Int?, _ host: VimHost) {
        guard let change = lastChange else { return }
        var keys = change.keys
        if let count = count ?? change.count {
            keys.insert(contentsOf: String(count).map(String.init), at: keys.first == "\"" ? 2 : 0)
        }
        replaying = true
        defer { replaying = false }
        for key in keys { handle(key, in: host) }
        guard mode == .insert else { return }
        if let inserted = change.inserted {
            let at = host.vimSelection.location
            replace(NSRange(location: at, length: 0), with: inserted, host)
            host.vimSelection = NSRange(location: at + inserted.utf16.count, length: 0)
        }
        finishInsert(host)
    }

    private func enterInsert(at position: Int, _ host: VimHost) {
        mode = .insert
        host.vimSelection = NSRange(location: position, length: 0)
        insertStart = position
        insertLength = text.length
    }

    /// Back to normal mode one character left, keeping what the insert typed for `.` when it was plain typing.
    private func finishInsert(_ host: VimHost) {
        let caret = host.vimSelection.location
        if var change = recording {
            if caret >= insertStart, text.length - insertLength == caret - insertStart {
                change.inserted = text.string.substring(with: NSRange(location: insertStart, length: caret - insertStart))
            }
            lastChange = change
            recording = nil
        }
        mode = .normal
        place(caret > text.lineStart(caret) ? text.previous(caret) : caret, host)
    }

    private func editCommandLine(_ key: String, _ host: VimHost) {
        guard let line = commandLine else { return }
        switch key {
        case "<Esc>":
            commandLine = nil
        case "<BS>":
            commandLine = line.count > 1 ? String(line.dropLast()) : nil
        case "<CR>":
            commandLine = nil
            let body = String(line.dropFirst())
            if line.hasPrefix(":") {
                if ["w", "wq", "x"].contains(body) { host.vimSave() }
                if ["q", "q!", "wq", "x"].contains(body) { host.vimClose() }
            } else if let pattern = body.isEmpty ? search?.pattern : body {
                search = (pattern, line.hasPrefix("/"))
                let at = text.normal(host.vimSelection.location)
                if let target = target("n", nil, nil, from: at, operating: false) { place(target.position, host) }
            }
        default:
            if key.count == 1 { commandLine = line + key }
        }
    }

    // MARK: Motions and objects

    private func target(_ motion: String, _ argument: String?, _ count: Int?, from at: Int, operating: Bool) -> (position: Int, kind: Kind)? {
        let n = count ?? 1
        switch motion {
        case "h":
            let start = text.lineStart(at)
            var p = at
            for _ in 0..<n where p > start { p = text.previous(p) }
            return (p, .exclusive)
        case "l":
            let end = operating ? text.lineEnd(at) : text.lastCharacter(at)
            var p = at
            for _ in 0..<n where p < end { p = text.next(p) }
            return (p, .exclusive)
        case "j", "k":
            return text.vertical(at, motion == "j" ? n : -n).map { ($0, .linewise) }
        case "w":
            var p = at
            for step in 0..<n {
                let from = p
                p = text.wordForward(p)
                // An operator's last word stops at the end of its line.
                if operating, step == n - 1, p > text.lineEnd(from) { p = max(text.lineEnd(from), from) }
            }
            return (p, .exclusive)
        case "b":
            var p = at
            for _ in 0..<n { p = text.wordBackward(p) }
            return (p, .exclusive)
        case "e":
            var p = at
            for _ in 0..<n { p = text.wordEnd(p) }
            return (p, .inclusive)
        case "0":
            return (text.lineStart(at), .exclusive)
        case "^":
            return (text.nonBlank(at), .exclusive)
        case "$":
            var line = at
            for _ in 1..<max(n, 1) {
                guard let next = text.nextLine(line) else { break }
                line = next
            }
            return operating ? (text.lineEnd(line), .exclusive) : (text.lastCharacter(line), .inclusive)
        case "gg", "G":
            let line = count.map(text.line) ?? (motion == "gg" ? 0 : text.lineStart(text.normal(text.length)))
            return (text.normal(text.nonBlank(line)), .linewise)
        case "f", "t":
            guard let argument else { return nil }
            let end = text.lineEnd(at)
            var p = at
            for _ in 0..<n {
                let start = text.next(p)
                guard start < end else { return nil }
                let found = text.string.range(of: argument, options: .literal, range: NSRange(location: start, length: end - start))
                guard found.location != NSNotFound else { return nil }
                p = found.location
            }
            return (motion == "t" ? text.previous(p) : p, .inclusive)
        case "%":
            return text.match(at).map { ($0, .inclusive) }
        case "n", "N":
            guard let search else { return nil }
            var p = at
            for _ in 0..<n {
                guard let found = text.find(search.pattern, forward: search.forward == (motion == "n"), from: p) else { return nil }
                p = found
            }
            return (p, .exclusive)
        default:
            return nil
        }
    }

    private func object(_ name: String, at: Int) -> (NSRange, Bool)? {
        let around = name.hasPrefix("a")
        switch name.dropFirst() {
        case "w":
            return text.word(at, around: around).map { ($0, false) }
        case "\"":
            return text.quote(at, around: around).map { ($0, false) }
        case "p":
            return (text.paragraph(at, around: around), true)
        default:
            guard let (open, close) = text.parentheses(at) else { return nil }
            let range = around ? NSRange(location: open, length: close - open + 1) : NSRange(location: open + 1, length: close - open - 1)
            return (range, false)
        }
    }

    /// What an operator in normal mode covers, and whether it covers whole lines.
    private func span(_ command: Command, at: Int) -> (NSRange, Bool)? {
        let motion = command.motion!
        if motion == "line" {
            var last = at
            for _ in 1..<max(command.count ?? 1, 1) {
                guard let next = text.nextLine(last) else { break }
                last = next
            }
            return (text.lines(at, last), true)
        }
        if Self.isObject(motion) { return object(motion, at: at) }
        // `cw` on a word changes to its end, as `ce` would from inside it.
        if command.name == "c", motion == "w", at < text.length, text.kind(at) != 0 {
            var p = text.wordEndInside(at)
            for _ in 1..<max(command.count ?? 1, 1) { p = text.wordEnd(p) }
            return (NSRange(location: at, length: text.next(p) - at), false)
        }
        guard let target = target(motion, command.argument, command.count, from: at, operating: true) else { return nil }
        let low = min(at, target.position)
        let high = max(at, target.position)
        switch target.kind {
        case .exclusive: return (NSRange(location: low, length: high - low), false)
        case .inclusive: return (NSRange(location: low, length: text.next(high) - low), false)
        case .linewise: return (text.lines(low, high), true)
        }
    }

    private func visualRange() -> NSRange {
        let low = min(anchor, cursor)
        let high = max(anchor, cursor)
        if mode == .visualLine { return text.lines(low, high) }
        return NSRange(location: low, length: text.next(high) - low)
    }

    // MARK: Edits

    private func apply(_ op: String, _ range: NSRange, linewise: Bool, register: String?, at: Int, _ host: VimHost) {
        let content = text.string.substring(with: range)
        switch op {
        case "y":
            store(content, linewise: linewise, register, host)
            place(linewise && text.lineStart(at) == range.location ? at : range.location, host)
        case "d":
            store(content, linewise: linewise, register, host)
            var range = range
            // The last line has no newline of its own, so it takes the one before it.
            if linewise, NSMaxRange(range) == text.length, range.location > 0, !content.hasSuffix("\n") {
                range = NSRange(location: range.location - 1, length: range.length + 1)
            }
            replace(range, with: "", host)
            place(linewise ? text.nonBlank(range.location) : range.location, host)
        case "c":
            store(content, linewise: linewise, register, host)
            var range = range
            if linewise, content.hasSuffix("\n") { range.length -= 1 }
            replace(range, with: "", host)
            enterInsert(at: range.location, host)
        default:
            let lines = text.lines(range.location, max(range.location, NSMaxRange(range) - 1))
            var body = text.string.substring(with: lines)
            let newline = body.hasSuffix("\n")
            if newline { body.removeLast() }
            let shifted = body.components(separatedBy: "\n").map { line in
                if op == ">" { return line.isEmpty ? line : "    " + line }
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                return String(line.dropFirst(min(4, line.prefix { $0 == " " }.count)))
            }
            replace(NSRange(location: lines.location, length: lines.length - (newline ? 1 : 0)), with: shifted.joined(separator: "\n"), host)
            place(text.nonBlank(lines.location), host)
        }
    }

    private func replace(_ range: NSRange, with string: String, _ host: VimHost) {
        edits += 1
        host.vimReplace(range, with: string)
    }

    private func place(_ position: Int, _ host: VimHost) {
        host.vimSelection = NSRange(location: text.normal(position), length: 0)
    }

    private func store(_ content: String, linewise: Bool, _ name: String?, _ host: VimHost) {
        let register = Register(text: linewise && !content.hasSuffix("\n") ? content + "\n" : content, linewise: linewise)
        registers["\""] = register
        if name == "+" {
            host.vimClipboard = register.text
        } else if let name {
            registers[name] = register
        }
    }

    private func register(_ name: String?, _ host: VimHost) -> Register? {
        if name == "+" { return host.vimClipboard.map { Register(text: $0, linewise: $0.hasSuffix("\n")) } }
        return registers[name ?? "\""]
    }
}
