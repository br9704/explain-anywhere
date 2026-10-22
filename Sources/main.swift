// Explain Anywhere: a floating panel that explains selected text with Claude.
// Launched by the "Explain with Claude" Quick Action (Control+Shift+I, or right-click > Services).
// Uses your Claude Code CLI login (claude -p), never an API key.
// Model text is only ever inserted with textContent, never as HTML.
//
// Args:
//   --file <path>     read the selection from this file (the file is deleted after reading)
//   --text <string>   the selection itself
//   --keep            start pinned (does not close on a click outside)
//   --followup <s>    after the first answer, send this follow-up automatically (testing)
//   --offscreen <dir> render headless and write PNG frames to <dir>, then quit (screenshots)
//   --frames <fps>    with --offscreen, also write numbered frames of the open and answer motion (demo GIF)
//   --info <path>     write window number and frame here once shown (testing)
//   --at <x,top>      place the panel's top-left here, in screen points (testing)
//
// Settings: ~/.config/explain-anywhere/config.json (see README).

import Cocoa
import WebKit

let HOME = NSHomeDirectory()
let BUNDLE_ID = Bundle.main.bundleIdentifier ?? "io.github.explain-anywhere"

func expand(_ p: String?) -> String? {
    guard let p = p?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
    return (p as NSString).expandingTildeInPath
}

struct Config {
    var model = "claude-haiku-5-5"
    var timeout: Double = 30
    var claudePath: String
    var audience = "someone learning software and AI engineering"
    var logFile: String? = "\(HOME)/Library/Logs/explain-anywhere.md"
    var logKeepDays = 14
    var notesDir = "\(HOME)/Documents/Explain Anywhere"
    var webhookURL: URL?
    var webhookTokenFile: String?

    static func load() -> Config {
        let candidates = ["\(HOME)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        var c = Config(claudePath: candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0])
        let path = "\(HOME)/.config/explain-anywhere/config.json"
        guard let d = FileManager.default.contents(atPath: path),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return c }
        if let v = j["model"] as? String, !v.isEmpty { c.model = v }
        if let v = j["timeoutSeconds"] as? Double, v >= 5 { c.timeout = v }
        if let v = expand(j["claudePath"] as? String) { c.claudePath = v }
        if let v = j["audience"] as? String, !v.isEmpty { c.audience = v }
        if j.keys.contains("logFile") { c.logFile = expand(j["logFile"] as? String) }   // null turns the log off
        if let v = j["logKeepDays"] as? Int { c.logKeepDays = v }
        if let v = expand(j["notesDir"] as? String) { c.notesDir = v }
        if let v = j["webhookURL"] as? String, let u = URL(string: v), u.scheme == "https" { c.webhookURL = u }
        c.webhookTokenFile = expand(j["webhookTokenFile"] as? String)
        return c
    }
}

let CFG = Config.load()
let WORKDIR = "\(HOME)/Library/Caches/explain-anywhere"
let FALLBACK_LOG = "\(HOME)/Library/Logs/explain-anywhere.md"
let PANEL_W: CGFloat = 460
let PANEL_MIN_H: CGFloat = 150
let PANEL_MAX_H: CGFloat = 640

let SCHEMA = """
{"type":"object","properties":{"title":{"type":"string"},"plain":{"type":"string"},"example":{"type":"string"},"code":{"type":"string"},"flow":{"type":"array","items":{"type":"string"}},"related":{"type":"array","items":{"type":"string"}}},"required":["title","plain","example"]}
"""

let SYSTEM_PROMPT = """
You explain things to AUDIENCE. Answer only through the structured output.
Fields:
- title: the term itself, or a 2 to 6 word name for what was selected.
- plain: 2 to 4 short plain sentences, under 70 words in total. Say what it is or does and why it is used. No jargon without a quick gloss.
- example: one concrete example in 1 or 2 sentences, under 45 words. Prefer a real situation (a payment, a chatbot, a search box).
- code: only when the selection is code, or a programming idea that is much clearer with code. At most 8 short lines, no comments longer than a few words. Otherwise leave it out.
- flow: only when the idea is a process or pipeline. 3 to 5 steps in order, each 1 to 4 words, like ["User question", "Search documents", "Model writes answer"]. Otherwise leave it out.
- related: 2 to 4 related terms worth learning next, each 1 to 3 words.
Plain text in every field: no markdown, no bullet points, no emoji, no em dashes.
"""

// MARK: - Answer model

struct Answer {
    var title: String
    var plain: String
    var example: String
    var code: String?
    var flow: [String]?
    var related: [String]?

    func toDict() -> [String: Any] {
        var d: [String: Any] = ["title": title, "plain": plain, "example": example]
        if let c = code { d["code"] = c }
        if let f = flow { d["flow"] = f }
        if let r = related { d["related"] = r }
        return d
    }

    var copyText: String {
        var s = "\(title)\n\n\(plain)\n\nExample: \(example)"
        if let c = code { s += "\n\n\(c)" }
        if let f = flow { s += "\n\n" + f.joined(separator: " > ") }
        return s
    }

    var logText: String {
        var s = "\(plain)\n\nExample: \(example)"
        if let c = code { s += "\n\n```\n\(c)\n```" }
        if let f = flow { s += "\n\nFlow: " + f.joined(separator: " > ") }
        if let r = related, !r.isEmpty { s += "\n\nRelated: " + r.joined(separator: ", ") }
        return s
    }
}

func clean(_ s: String, max: Int) -> String {
    var t = s.replacingOccurrences(of: "\u{2014}", with: ", ")
        .replacingOccurrences(of: "\u{2013}", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if t.count > max { t = String(t.prefix(max)) + "..." }
    return t
}

func validate(_ any: Any?) -> Answer? {
    guard let d = any as? [String: Any],
          let title = d["title"] as? String, !title.trimmingCharacters(in: .whitespaces).isEmpty,
          let plain = d["plain"] as? String, !plain.trimmingCharacters(in: .whitespaces).isEmpty
    else { return nil }
    let example = (d["example"] as? String) ?? ""
    var a = Answer(title: clean(title, max: 80), plain: clean(plain, max: 700), example: clean(example, max: 500))
    if let c = d["code"] as? String {
        let lines = c.replacingOccurrences(of: "\u{2014}", with: "-").split(separator: "\n", omittingEmptySubsequences: false).prefix(16)
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        if !joined.trimmingCharacters(in: .whitespaces).isEmpty { a.code = String(joined.prefix(1200)) }
    }
    if let f = d["flow"] as? [Any] {
        let items = f.compactMap { $0 as? String }.map { clean($0, max: 40) }.filter { !$0.isEmpty }
        if items.count >= 2 { a.flow = Array(items.prefix(6)) }
    }
    if let r = d["related"] as? [Any] {
        let items = r.compactMap { $0 as? String }.map { clean($0, max: 40) }.filter { !$0.isEmpty }
        if !items.isEmpty { a.related = Array(items.prefix(5)) }
    }
    return a
}

func stripFences(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("```") {
        if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
        if t.hasSuffix("```") { t = String(t.dropLast(3)) }
    }
    return t
}

enum Outcome {
    case ok(Answer)
    case fail(String)
}

// MARK: - Claude runner

func askClaude(prompt: String, done: @escaping (Outcome) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        try? FileManager.default.createDirectory(atPath: WORKDIR, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CFG.claudePath)
        p.arguments = ["-p", "--model", CFG.model, "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                       "--no-session-persistence", "--output-format", "json", "--json-schema", SCHEMA,
                       "--system-prompt", SYSTEM_PROMPT.replacingOccurrences(of: "AUDIENCE", with: CFG.audience)]
        p.currentDirectoryURL = URL(fileURLWithPath: WORKDIR)
        p.environment = ["HOME": HOME, "USER": NSUserName(), "LOGNAME": NSUserName(), "SHELL": "/bin/zsh",
                         "PATH": "\(HOME)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                         "LANG": "en_AU.UTF-8", "LC_ALL": "en_AU.UTF-8"]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        var timedOut = false
        do { try p.run() } catch {
            DispatchQueue.main.async { done(.fail("Could not start Claude Code. Install it and run claude once, or set claudePath in the config.")) }
            return
        }
        let killer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + CFG.timeout, execute: killer)
        inPipe.fileHandleForWriting.write(prompt.data(using: .utf8)!)
        try? inPipe.fileHandleForWriting.close()
        // Drain stderr in the background so a chatty process cannot block.
        DispatchQueue.global().async { _ = errPipe.fileHandleForReading.readDataToEndOfFile() }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        var outcome: Outcome
        if timedOut {
            outcome = .fail("Claude took longer than \(Int(CFG.timeout)) seconds, so it was stopped. Try again, or select less text.")
        } else if let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if (top["is_error"] as? Bool) == true {
                let msg = (top["result"] as? String) ?? "unknown error"
                outcome = .fail(msg.lowercased().contains("login") ? "Claude Code is not logged in. Run claude in Terminal once." : "Claude returned an error: \(clean(msg, max: 200))")
            } else if let a = validate(top["structured_output"]) {
                outcome = .ok(a)
            } else if let r = top["result"] as? String, !r.isEmpty {
                if let d = try? JSONSerialization.jsonObject(with: Data(stripFences(r).utf8)), let a = validate(d) {
                    outcome = .ok(a)
                } else {
                    // Fallback: plain text answer.
                    outcome = .ok(Answer(title: "Explanation", plain: clean(r, max: 1200), example: ""))
                }
            } else {
                outcome = .fail("Claude sent back an empty answer. Try again.")
            }
        } else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            if p.terminationStatus != 0 || raw.isEmpty {
                outcome = .fail("Claude Code did not answer (exit \(p.terminationStatus)). Run claude in Terminal once to check the login.")
            } else {
                outcome = .ok(Answer(title: "Explanation", plain: clean(raw, max: 1200), example: ""))
            }
        }
        DispatchQueue.main.async { done(outcome) }
    }
}

// MARK: - Log

// The auto log keeps logKeepDays days (0 keeps everything): older "## yyyy-MM-dd HH:mm" sections are trimmed on each write.
let logQueue = DispatchQueue(label: "explain.log")

func trimmed(_ text: String) -> String {
    let parts = text.components(separatedBy: "\n## ")
    guard parts.count > 1 else { return text }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.locale = Locale(identifier: "en_AU_POSIX")
    guard CFG.logKeepDays > 0 else { return text }
    let cutoff = Date().addingTimeInterval(-Double(CFG.logKeepDays) * 86400)
    var keep = [parts[0]]
    for sec in parts.dropFirst() {
        let head = String(sec.prefix(16))
        if let d = f.date(from: head), d < cutoff { continue }
        keep.append(sec)
    }
    return keep.joined(separator: "\n## ")
}

func appendLog(_ entry: String) {
    guard let LOGFILE = CFG.logFile else { return }
    logQueue.async {
        if !FileManager.default.fileExists(atPath: LOGFILE) {
            try? FileManager.default.createDirectory(atPath: (LOGFILE as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: LOGFILE, contents: "# Explained terms\n".data(using: .utf8))
        }
        if let old = try? String(contentsOfFile: LOGFILE, encoding: .utf8) {
            let new = trimmed(old) + entry
            if (try? new.write(toFile: LOGFILE, atomically: true, encoding: .utf8)) != nil { return }
        }
        let data = entry.data(using: .utf8)!
        for path in [LOGFILE, FALLBACK_LOG] {
            if path == FALLBACK_LOG {
                try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            }
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
                return
            }
        }
    }
}

// MARK: - Optional save webhook
// When webhookURL is set, each lookup is POSTed once, when the panel closes (or when a
// related chip starts a new lookup):
//   {"text": "...", "answer": {title, plain, example, code?, flow?, related?},
//    "followups": [{"q": "...", "a": "..."}], "source_app": "Safari"}
// Bearer token: EXPLAIN_WEBHOOK_TOKEN env var, or the file named by webhookTokenFile.
// Any failure (no token, 4xx, 5xx, offline) is ignored. The token is never logged.

func webhookToken() -> String? {
    if let e = ProcessInfo.processInfo.environment["EXPLAIN_WEBHOOK_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty { return e }
    guard let f = CFG.webhookTokenFile,
          let t = try? String(contentsOfFile: f, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
    return t
}

func sendToWebhook(_ payload: [String: Any], done: @escaping () -> Void = {}) {
    DispatchQueue.global(qos: .utility).async {
        guard let url = CFG.webhookURL, let body = try? JSONSerialization.data(withJSONObject: payload), body.count < 60_000 else {
            DispatchQueue.main.async(execute: done); return
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        req.httpMethod = "POST"
        if let token = webhookToken() { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { _, _, _ in DispatchQueue.main.async(execute: done) }.resume()
    }
}

func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: Date())
}

func quote(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
}

// MARK: - Panel

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class DragView: NSView {
    override func mouseDown(with e: NSEvent) { window?.performDrag(with: e) }
    override var mouseDownCanMoveWindow: Bool { true }
    // Drag works on the first click even when another app is in front.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}



final class App: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    var resizing = false
    var atPoint: NSPoint?
    var fx: NSVisualEffectView!
    var closing = false
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var sourceApp = ""
    var panel: KeyPanel!
    var web: WKWebView!
    var selection = ""
    var keep = false
    var autoFollowup: String?
    var infoPath: String?
    var pageReady = false
    var pending: [String] = []
    var last: Answer?
    var busy = false
    var topY: CGFloat = 0

    func applicationWillFinishLaunching(_ n: Notification) {
        sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    }

    var firstAnswer: Answer?
    var pairs: [[String: String]] = []
    var offscreenDir: String?
    var frameFPS: Double = 0
    var shotN = 0

    /// Numbered frames for the demo animation, e.g. a-open-000.png ... (only with --offscreen --frames).
    func burst(_ tag: String, seconds: Double) {
        guard frameFPS > 0 else { return }
        for k in 0..<Int(seconds * frameFPS) {
            shoot(String(format: "%@-%03d", tag, k), after: Double(k) / frameFPS)
        }
    }

    /// Send the current lookup to the save webhook (text, first answer, follow-ups) and reset.
    func flushWebhook(done: @escaping () -> Void = {}) {
        guard offscreenDir == nil, let a = firstAnswer else { done(); return }
        var payload: [String: Any] = ["text": String(selection.prefix(2000)), "answer": a.toDict(),
                                      "followups": Array(pairs.prefix(20))]
        if !sourceApp.isEmpty { payload["source_app"] = sourceApp }
        firstAnswer = nil; pairs = []
        sendToWebhook(payload, done: done)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        parseArgs()
        buildMenu()
        buildPanel()
        if offscreenDir == nil {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self else { return e }
            if e.keyCode == 53 { self.closePanel(); return nil }  // Esc
            if e.modifierFlags.contains(.command), let k = e.charactersIgnoringModifiers {
                // The panel never activates the app, so the menu bar cannot route these.
                switch k {
                case "c": self.copyAnswer(); return nil
                case "v": NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self); return nil
                case "x": NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self); return nil
                case "a": NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self); return nil
                case "z": NSApp.sendAction(Selector(("undo:")), to: nil, from: self); return nil
                case "w": self.closePanel(); return nil
                default: break
                }
            }
            return e
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.keep == false { self?.closePanel() }
        }
        }
        let sel = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if sel.isEmpty {
            js("showError(\(jsonString(["msg": "Nothing was selected. Select some text, then press Control+Shift+I.", "retry": false])))")
            return
        }
        selection = String(sel.prefix(6000))
        explain(prompt: firstPrompt(selection), loadingTitle: shortTitle(selection), logHead: selection, followup: nil)
    }


    func parseArgs() {
        let a = CommandLine.arguments
        var i = 1
        while i < a.count {
            switch a[i] {
            case "--file":
                if i + 1 < a.count {
                    let path = a[i + 1]
                    selection = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(atPath: path)
                    i += 1
                }
            case "--text": if i + 1 < a.count { selection = a[i + 1]; i += 1 }
            case "--keep": keep = true
            case "--at":
                if i + 1 < a.count {
                    let parts = a[i + 1].split(separator: ",").compactMap { Double($0) }
                    if parts.count == 2 { atPoint = NSPoint(x: parts[0], y: parts[1]) }
                    i += 1
                }
            case "--followup": if i + 1 < a.count { autoFollowup = a[i + 1]; i += 1 }
            case "--info": if i + 1 < a.count { infoPath = a[i + 1]; i += 1 }
            case "--offscreen": if i + 1 < a.count { offscreenDir = a[i + 1]; i += 1 }
            case "--frames": if i + 1 < a.count { frameFPS = min(60, max(0, Double(a[i + 1]) ?? 0)); i += 1 }
            default: break
            }
            i += 1
        }
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "Quit Explain", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func buildPanel() {
        let mouse = NSEvent.mouseLocation
        let h = PANEL_MIN_H + 90
        var x = mouse.x + 14
        var top = mouse.y - 14
        // Last position the panel was dragged to wins, if it is still on a screen.
        let ud = UserDefaults.standard
        if let sx = ud.object(forKey: "panelX") as? Double, let st = ud.object(forKey: "panelTop") as? Double,
           NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -4, dy: -4).contains(NSPoint(x: sx + 40, y: st - 20)) }) {
            x = CGFloat(sx); top = CGFloat(st)
        }
        if let at = atPoint { x = at.x; top = at.y }
        // Stack below any other open panels.
        let others = max(0, NSRunningApplication.runningApplications(withBundleIdentifier: BUNDLE_ID).count - 1)
        x += CGFloat(others) * 28
        top -= CGFloat(others) * 28
        let anchor = NSPoint(x: x + 40, y: top - 20)
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) }
            ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        if x + PANEL_W > vf.maxX - 12 { x = vf.maxX - PANEL_W - 12 }
        if x < vf.minX + 12 { x = vf.minX + 12 }
        // Keep room for the panel to grow downwards.
        if top - PANEL_MAX_H < vf.minY + 12 { top = min(vf.maxY - 12, vf.minY + 12 + PANEL_MAX_H) }
        if top > vf.maxY - 12 { top = vf.maxY - 12 }
        if offscreenDir != nil { x = -8000; top = 2000 }
        topY = top

        // Non-activating: the panel takes clicks and typing on the first try without
        // pulling the app forward, so the app you were in stays frontmost.
        panel = KeyPanel(contentRect: NSRect(x: x, y: top - h, width: PANEL_W, height: h),
                         styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)

        fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: PANEL_W, height: h))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 18
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 1
        fx.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        fx.autoresizingMask = [.width, .height]
        panel.contentView = fx

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "explain")
        web = WKWebView(frame: fx.bounds, configuration: cfg)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.navigationDelegate = self
        fx.addSubview(web)
        // Native drag strip over the header (leaves the buttons on the right clickable).
        let drag = DragView(frame: NSRect(x: 0, y: h - 48, width: PANEL_W - 120, height: 48))
        drag.autoresizingMask = [.minYMargin]
        fx.addSubview(drag)
        web.loadHTMLString(PAGE, baseURL: nil)

        if offscreenDir != nil {
            // Headless render for screenshots: never on screen, never key, never animated natively.
            let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            if web.responds(to: sel) {
                typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(web.method(for: sel), to: F.self)(web, sel, false)
            }
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
            return
        }
        // Open: fade in, scale 0.96 to 1 from the top-left, 240ms on a sheet curve.
        // The page adds a 12px to 0 blur on the content. Reduce Motion: a plain fade.
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        animatePanel(opening: true)
        writeInfo()
        panel.makeFirstResponder(web)
    }

    // Prevent any navigation away from the page we built.
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(a.navigationType == .other ? .allow : .cancel)
    }

    func shoot(_ name: String, after: Double, final: Bool = false) {
        guard let dir = offscreenDir else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            self.web.takeSnapshot(with: nil) { img, _ in
                guard let img = img else { return }
                let size = img.size
                let out = NSImage(size: size)
                out.lockFocus()
                // Stand-in for the native glass, rounded like the panel.
                NSColor(srgbRed: 0x1A/255, green: 0x1A/255, blue: 0x1C/255, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 18, yRadius: 18).fill()
                img.draw(in: NSRect(origin: .zero, size: size))
                out.unlockFocus()
                if let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                }
                if name == "error" || final { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) } }
            }
        }
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        pageReady = true
        if offscreenDir != nil {
            shoot("open-1", after: 0.0); shoot("open-2", after: 0.12); shoot("open-3", after: 0.24)
            shoot("loading-1", after: 0.6); shoot("loading-2", after: 2.1)
            burst("a-open", seconds: 1.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { NSApp.terminate(nil) }
        }
        if keep { web.evaluateJavaScript("setPinned(true)") }
        for s in pending { web.evaluateJavaScript(s) }
        pending.removeAll()
    }

    func js(_ s: String) {
        if pageReady { web.evaluateJavaScript(s) } else { pending.append(s) }
    }

    func jsonString(_ o: Any) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    func shortTitle(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > 60 ? String(one.prefix(60)) + "..." : one
    }

    func firstPrompt(_ text: String) -> String {
        "Explain this selection:\n\n\(text)"
    }

    func explain(prompt: String, loadingTitle: String, logHead: String, followup: String?) {
        guard !busy else { return }
        busy = true
        js("showLoading(\(jsonString(["title": loadingTitle, "keep": last != nil])))")
        askClaude(prompt: prompt) { [weak self] out in
            guard let self = self else { return }
            self.busy = false
            switch out {
            case .ok(let a):
                self.last = a
                self.js("render(\(self.jsonString(a.toDict())))")
                var entry = "\n## \(stamp())\n\n\(quote(logHead))\n\n"
                if let f = followup { entry += "Follow-up: \(f)\n\n" }
                entry += "**\(a.title)**\n\n\(a.logText)\n"
                if self.offscreenDir == nil { appendLog(entry) }
                if let f = followup { self.pairs.append(["q": f, "a": a.plain]) } else { self.firstAnswer = a }
                if followup == nil { self.burst("b-answer", seconds: 1.6) }
                self.shoot(followup == nil ? "answer" : "followup", after: self.frameFPS > 0 ? 2.0 : 1.0,
                           final: followup != nil || self.autoFollowup == nil)
                if let f = self.autoFollowup {
                    self.autoFollowup = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.followUp(f) }
                }
            case .fail(let msg):
                self.js("showError(\(self.jsonString(["msg": msg, "retry": true])))")
                self.shoot("error", after: 0.6)
            }
        }
    }

    func followUp(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let prev = last.map { jsonString($0.toDict()) } ?? "none"
        let prompt = """
        The student selected this text:

        \(selection)

        Your previous explanation (JSON):
        \(prev)

        The student now adds this context or follow-up question:
        \(t)

        Give a new explanation in the same format that uses the added context or answers the follow-up. Keep the title about the original selection unless the follow-up asks about something else.
        """
        explain(prompt: prompt, loadingTitle: last?.title ?? shortTitle(selection), logHead: selection, followup: t)
        shoot("followup-loading", after: 0.5)
    }

    func explainTerm(_ term: String) {
        let ctx = last?.title ?? shortTitle(selection)
        flushWebhook()
        selection = term
        last = nil
        explain(prompt: "Explain this term. It came up while learning about \(ctx):\n\n\(term)",
                loadingTitle: term, logHead: term, followup: nil)
    }

    func copyAnswer() {
        web.evaluateJavaScript("currentSelection()") { [weak self] r, _ in
            guard let self = self else { return }
            var text = (r as? String) ?? ""
            if text.isEmpty { text = self.last?.copyText ?? "" }
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.js("flashCopied()")
        }
    }

    func scaleTransform(_ s: CGFloat) -> CATransform3D {
        let h = fx.layer?.bounds.height ?? panel.frame.height
        return CATransform3DConcat(CATransform3DMakeScale(s, s, 1), CATransform3DMakeTranslation(0, h * (1 - s), 0))
    }

    func animatePanel(opening: Bool, done: (() -> Void)? = nil) {
        let dur = reduceMotion ? 0.15 : (opening ? 0.24 : 0.16)
        let curve = opening ? CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)   // sheet curve
                            : CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)       // ease-in for the exit
        if !reduceMotion, let layer = fx.layer {
            let a = CABasicAnimation(keyPath: "transform")
            a.fromValue = NSValue(caTransform3D: opening ? scaleTransform(0.96) : CATransform3DIdentity)
            a.toValue = NSValue(caTransform3D: opening ? CATransform3DIdentity : scaleTransform(0.96))
            a.duration = dur; a.timingFunction = curve
            a.fillMode = .forwards; a.isRemovedOnCompletion = opening
            layer.add(a, forKey: "pop")
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = dur; ctx.timingFunction = curve
            panel.animator().alphaValue = opening ? 1 : 0
        }, completionHandler: { done?() })
    }

    func closePanel() {
        if closing { return }
        closing = true
        web.evaluateJavaScript("leave()")
        // Hide first, then send the lookup to the webhook in the background and quit (at most 4 s).
        animatePanel(opening: false) { [weak self] in
            self?.panel.orderOut(nil)
            self?.flushWebhook { NSApp.terminate(nil) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { NSApp.terminate(nil) }  // safety net
    }

    func windowDidMove(_ n: Notification) {
        if resizing { return }
        topY = panel.frame.maxY
        UserDefaults.standard.set(Double(panel.frame.minX), forKey: "panelX")
        UserDefaults.standard.set(Double(panel.frame.maxY), forKey: "panelTop")
        writeInfo()
    }

    func saveNote() {
        guard let a = last else { js("flash('Nothing to save yet')"); return }
        let src = selection
        DispatchQueue.global(qos: .utility).async {
            let bad = CharacterSet(charactersIn: "/\\:*?\"<>|[]#^")
            var name = a.title.components(separatedBy: bad).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "Term" }
            try? FileManager.default.createDirectory(atPath: CFG.notesDir, withIntermediateDirectories: true)
            var path = "\(CFG.notesDir)/(Term) \(name).md"
            var n = 2
            while FileManager.default.fileExists(atPath: path) { path = "\(CFG.notesDir)/(Term) \(name) \(n).md"; n += 1 }
            let day = String(stamp().prefix(10))
            var body = "---\ntitle: \"\(a.title.replacingOccurrences(of: "\"", with: "'"))\"\ntype: term\ntags:\n  - \"#study\"\n  - \"#term\"\ncreated: \"\(day)\"\n---\n\n# \(a.title)\n\n"
            body += quote(src) + "\n\n"
            body += "In plain words: \(a.plain)\n\n"
            if !a.example.isEmpty { body += "Example: \(a.example)\n\n" }
            if let c = a.code { body += "```\n\(c)\n```\n\n" }
            if let f = a.flow { body += "Flow: " + f.joined(separator: " > ") + "\n\n" }
            if let r = a.related, !r.isEmpty { body += "Related: " + r.joined(separator: ", ") + "\n\n" }
            body += "Saved from Explain Anywhere on \(stamp()).\n"
            let ok = FileManager.default.createFile(atPath: path, contents: body.data(using: .utf8))
            DispatchQueue.main.async { self.js(ok ? "flash('Saved')" : "flash('Could not save the note')") }
        }
    }

    func resize(to contentH: CGFloat) {
        let h = min(PANEL_MAX_H, max(PANEL_MIN_H, contentH))
        var f = panel.frame
        if abs(f.height - h) < 1 { return }
        f.origin.y = topY - h
        f.size.height = h
        resizing = true
        panel.setFrame(f, display: true, animate: false)
        resizing = false
        writeInfo()
    }

    func writeInfo() {
        guard let p = infoPath else { return }
        let f = panel.frame
        let s = "\(panel.windowNumber) \(Int(f.origin.x)) \(Int(f.origin.y)) \(Int(f.width)) \(Int(f.height))\n"
        try? s.write(toFile: p, atomically: true, encoding: .utf8)
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let d = m.body as? [String: Any], let type = d["type"] as? String else { return }
        switch type {
        case "height": if let h = d["h"] as? Double { resize(to: CGFloat(h)) }
        case "ask": if let t = d["text"] as? String { followUp(t) }
        case "term": if let t = d["text"] as? String { explainTerm(String(t.prefix(80))) }
        case "retry":
            if let a = last { _ = a; followUp("Please try again.") }
            else { explain(prompt: firstPrompt(selection), loadingTitle: shortTitle(selection), logHead: selection, followup: nil) }
        case "close": closePanel()
        case "pin": if let on = d["on"] as? Bool { keep = on }
        case "save": saveNote()
        default: break
        }
    }
}

// MARK: - Page (our own HTML; model text goes in through textContent only)

let PAGE = """
<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:">
<style>
/* Design tokens: an Apple-style dark set (macOS label, fill and separator values). */
:root{
  color-scheme:dark;
  --ap-bg:#131315; --ap-bg-2:#1C1C1E; --ap-bg-3:#242427; --ap-bg-4:#2E2E31;
  --ap-bg-elevated:#1A1A1C; --ap-bg-elevated-2:#222225;
  --ap-label:rgba(255,255,255,.847); --ap-label-2:rgba(255,255,255,.549); --ap-label-3:rgba(255,255,255,.247); --ap-label-4:rgba(255,255,255,.098);
  --ap-sep:rgba(84,84,88,.42); --ap-sep-list:rgba(255,255,255,.065);
  --ap-fill-3:rgba(118,118,128,.24); --ap-fill-4:rgba(116,116,128,.18);
  --ap-red:#FF4245; --ap-accent:var(--ap-red);
  --ap-focus-ring:color-mix(in srgb,var(--ap-label) 45%,transparent);
  --ap-glass-tint:rgba(255,255,255,.055); --ap-glass-tint-press:rgba(255,255,255,.12);
  --ap-glass-rim:inset 0 0 0 1px rgba(255,255,255,.10),inset 0 1px 0 rgba(255,255,255,.05);
  --ap-glass-lift:0 1px 2px rgba(0,0,0,.35);
  --ap-glass-shadow:var(--ap-glass-rim),var(--ap-glass-lift);
  --ap-font-text:-apple-system,BlinkMacSystemFont,"SF Pro Text","SF Pro Display","Avenir Next",system-ui,"Helvetica Neue",sans-serif;
  --ap-font-display:-apple-system,BlinkMacSystemFont,"SF Pro Display","SF Pro Text","Avenir Next",system-ui,"Helvetica Neue",sans-serif;
  --ap-font-mono:ui-monospace,"SF Mono",Menlo,monospace;
  --ap-r-md:10px; --ap-r-lg:12px; --ap-r-group:12px; --ap-r-capsule:9999px;
  --ap-ease-sheet:cubic-bezier(0.32,0.72,0,1); --ap-ease-out:cubic-bezier(0.25,0.1,0.25,1);
  --ap-dur-snappy:350ms; --ap-dur-out:200ms;
}
@media (prefers-reduced-motion:reduce){:root{--ap-dur-snappy:0ms;--ap-dur-out:150ms}}
*{box-sizing:border-box;margin:0;padding:0}
html,body{background:transparent;color:var(--ap-label);font-family:var(--ap-font-text);-webkit-font-smoothing:antialiased;cursor:default}
/* Panel ground: the Mac window ground, a touch translucent over the native blur. */
body{background:color-mix(in srgb,var(--ap-bg) 80%,transparent);height:100vh;display:flex;flex-direction:column;overflow:hidden;-webkit-user-select:text}
#wrap{flex:1 1 auto;min-height:0;overflow-y:auto;overscroll-behavior:contain;padding:16px 16px 4px}
#wrap::-webkit-scrollbar{width:8px}#wrap::-webkit-scrollbar-thumb{background:var(--ap-label-4);border-radius:4px}#wrap::-webkit-scrollbar-track{background:transparent}
/* Open: content unblurs 12px to 0 with the native fade and scale (240ms, sheet curve). Close: reverse, 160ms. */
html{animation:enter 240ms var(--ap-ease-sheet) both}
@keyframes enter{from{filter:blur(12px)}}
html.leaving{filter:blur(12px);transition:filter 160ms cubic-bezier(.4,0,1,1)}
#inner{transition:opacity 120ms var(--ap-ease-out)}
#inner.out{opacity:0}
#inner.dim{opacity:.38}
#foot.busy{background:linear-gradient(100deg,transparent 20%,#FFFFFF10 40%,transparent 60%) 0 0/300% 100%;animation:shimmer 1.6s linear infinite}
@media (prefers-reduced-motion:reduce){#foot.busy{animation:none}}
/* Sections stagger in: opacity plus a 7px rise, 50ms apart. */
.grp,h1{animation:rise 320ms var(--ap-ease-sheet) both;animation-delay:calc(var(--i,0) * 50ms)}
@keyframes rise{from{opacity:0;transform:translateY(7px)}}
/* Flow: boxes pop in one by one, arrows draw. */
.box{animation:boxin 280ms var(--ap-ease-sheet) both;animation-delay:calc(var(--d,0) * 70ms + 150ms)}
@keyframes boxin{from{opacity:0;transform:scale(.92)}}
.arrow path{stroke-dasharray:16;stroke-dashoffset:16;animation:draw 260ms var(--ap-ease-out) forwards;animation-delay:calc(var(--d,0) * 70ms + 190ms)}
@keyframes draw{to{stroke-dashoffset:0}}
@media (prefers-reduced-motion:reduce){
  html{animation:none}html.leaving{filter:none}
  .grp,h1,.box{animation:fade 150ms var(--ap-ease-out) both;animation-delay:0ms}
  .arrow path{animation:none;stroke-dashoffset:0}
}
@keyframes fade{from{opacity:0}}
/* ap-title1 (Mac): 22/26, -0.26, 700 */
h1{font-family:var(--ap-font-display);font-size:22px;line-height:26px;letter-spacing:-.26px;font-weight:700;color:var(--ap-label);margin:2px 104px 14px 4px;word-break:break-word}
/* ap-group-header (Mac): 13/16 bold, primary label */
.hd{font-size:13px;line-height:16px;letter-spacing:-.08px;font-weight:700;color:var(--ap-label);padding:0 10px 6px}
.grp{margin:0 0 16px}
/* Inset card */
.card{background:var(--ap-fill-4);border-radius:var(--ap-r-group);padding:10px 12px}
.txt{font-size:13px;line-height:18px;letter-spacing:-.08px;color:var(--ap-label)}
.card .txt+pre{margin-top:10px}
pre{font:12px/17px var(--ap-font-mono);color:var(--ap-label);background:var(--ap-bg);border-radius:var(--ap-r-md);box-shadow:inset 0 0 0 1px var(--ap-sep-list);padding:9px 11px;white-space:pre-wrap;word-break:break-word}
.flow{display:flex;flex-wrap:wrap;align-items:center;gap:6px}
.box{font-size:12px;line-height:15px;font-weight:500;color:var(--ap-label);background:var(--ap-bg-3);border-radius:var(--ap-r-md);box-shadow:var(--ap-glass-rim);padding:7px 10px;max-width:190px}
.box.end{background:var(--ap-bg-4)}
.arrow{width:14px;height:10px;flex:none;stroke:var(--ap-label-3)}
.chips{display:flex;flex-wrap:wrap;gap:6px;padding:0 2px}
/* ap-capsule, fill variant */
.chip{height:28px;padding:0 12px;border:0;border-radius:var(--ap-r-capsule);background:var(--ap-fill-3);color:var(--ap-label);font:500 12px/1 var(--ap-font-text);cursor:pointer;transition:background-color var(--ap-dur-out) var(--ap-ease-out)}
.chip:hover{background:var(--ap-glass-tint-press)}
.chip:active{transform:scale(.96);background:rgba(255,255,255,.16)}
.chip{transition:background-color var(--ap-dur-out) var(--ap-ease-out),transform 120ms var(--ap-ease-out)}
.rb:active{transform:scale(.94)}
@media (prefers-reduced-motion:reduce){.chip:active,.rb:active{transform:none}}
.err{color:var(--ap-accent)}
.btn{margin-top:10px;height:28px;padding:0 12px;border:0;border-radius:var(--ap-r-capsule);background:var(--ap-glass-tint);box-shadow:var(--ap-glass-shadow);color:var(--ap-label);font:500 12px/1 var(--ap-font-text);cursor:pointer}
/* Skeleton bars */
.bar{display:block;height:11px;margin:5px 0;border-radius:6px;background:linear-gradient(100deg,#FFFFFF0F 20%,#FFFFFF24 40%,#FFFFFF0F 60%) 0 0/300% 100%;animation:shimmer 1.6s linear infinite}
@keyframes shimmer{from{background-position:100% 0}to{background-position:-50% 0}}
.bar.t{height:22px;width:58%;margin:2px 0 16px 4px}
@keyframes skel{50%{opacity:.55}}
@media (prefers-reduced-motion:reduce){.bar{animation:none;background:#FFFFFF14}}
/* Footer: a search-style capsule */
#foot{flex:none;padding:10px 12px 12px;border-top:1px solid var(--ap-sep-list)}
#ask{width:100%;height:30px;border:0;border-radius:var(--ap-r-capsule);background:var(--ap-glass-tint);box-shadow:var(--ap-glass-shadow);color:var(--ap-label);font:13px/16px var(--ap-font-text);letter-spacing:-.08px;padding:0 12px;outline:none}
#ask::placeholder{color:var(--ap-label-3)}
#ask:focus-visible{outline:3px solid var(--ap-focus-ring);outline-offset:1px}
#ask:disabled{opacity:.5}
/* Round glass buttons (ap-roundbtn ap-btn--glass), 28px */
#tools{position:fixed;top:12px;right:12px;display:flex;gap:6px;z-index:5}
.rb{width:28px;height:28px;padding:0;border:0;border-radius:var(--ap-r-capsule);background:var(--ap-glass-tint);box-shadow:var(--ap-glass-shadow);display:inline-flex;align-items:center;justify-content:center;cursor:pointer;transition:background-color var(--ap-dur-out) var(--ap-ease-out)}
.rb:hover,.rb.on{background:var(--ap-glass-tint-press)}
.rb svg{width:12px;height:12px;fill:none;stroke:var(--ap-label-2);stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round}
.rb.on svg,.rb:hover svg{stroke:var(--ap-label)}
#toast{position:fixed;top:48px;right:12px;height:24px;padding:0 10px;display:flex;align-items:center;border-radius:var(--ap-r-capsule);background:var(--ap-bg-4);box-shadow:var(--ap-glass-shadow);font:500 11px/1 var(--ap-font-text);color:var(--ap-label);opacity:0;transition:opacity var(--ap-dur-out) var(--ap-ease-out)}
#toast.on{opacity:1}
</style></head>
<body>
<div id="wrap"><div id="inner"></div></div>
<div id="foot"><input id="ask" type="text" placeholder="Add context or ask a follow-up" autocomplete="off" spellcheck="false"></div>
<div id="tools">
<button class="rb" id="save" title="Save as a note"><svg viewBox="0 0 12 12"><path d="M3 1.5h6v9L6 8.3 3 10.5z"/></svg></button>
<button class="rb" id="pin" title="Keep open"><svg viewBox="0 0 12 12"><path d="M4.2 1.5h3.6M4.8 1.5v3.3L3 6.8h6L7.2 4.8V1.5M6 6.8v3.7"/></svg></button>
<button class="rb" id="close" title="Close (Esc)"><svg viewBox="0 0 12 12"><path d="M3.2 3.2l5.6 5.6M8.8 3.2l-5.6 5.6"/></svg></button>
</div>
<div id="toast">Copied</div>
<script>
const post=m=>window.webkit.messageHandlers.explain.postMessage(m);
const W=document.getElementById('inner'),ask=document.getElementById('ask'),F=document.getElementById('foot');
function el(tag,cls,text){const e=document.createElement(tag);if(cls)e.className=cls;if(text!=null)e.textContent=text;return e}
let gi=0;
function grp(label,card){const g=el('div','grp');g.style.setProperty('--i',++gi);if(label)g.appendChild(el('div','hd',label));const b=card?el('div','card'):el('div');g.appendChild(b);W.appendChild(g);return b}
function report(){post({type:'height',h:Math.ceil(W.offsetHeight+20+F.offsetHeight)})}
new ResizeObserver(report).observe(W);
function arrow(){const ns='http://www.w3.org/2000/svg';const s=document.createElementNS(ns,'svg');s.setAttribute('viewBox','0 0 14 10');s.setAttribute('class','arrow');const p=document.createElementNS(ns,'path');p.setAttribute('d','M1 5h11M8.5 1.5 12 5l-3.5 3.5');p.setAttribute('fill','none');p.setAttribute('stroke-width','1.4');p.setAttribute('stroke-linecap','round');p.setAttribute('stroke-linejoin','round');s.appendChild(p);return s}
function bars(parent,ws){ws.forEach(w=>{const b=el('span','bar');b.style.width=w;parent.appendChild(b)})}
function showLoading(d){
  if(d.keep&&W.dataset.state==='answer'){W.classList.add('dim');F.classList.add('busy');ask.disabled=true;return}
  W.replaceChildren();gi=0;
  if(d.title){W.appendChild(el('h1',null,d.title))}else{bars(W,[]);const t=el('span','bar t');W.appendChild(t)}
  bars(grp('In plain words',true),['96%','90%','64%']);
  bars(grp('Example',true),['92%','52%']);
  W.dataset.state='loading';ask.disabled=true;report();
}
let shown=false;
function leave(){document.documentElement.classList.add('leaving')}
function render(d){
  F.classList.remove('busy');  if(shown&&!W.classList.contains('out')&&!matchMedia('(prefers-reduced-motion: reduce)').matches&&W.dataset.state==='answer'){W.classList.add('out');setTimeout(()=>{W.classList.remove('out','dim');draw(d)},120);return}
  W.classList.remove('dim');
  draw(d);
}
function draw(d){
  W.replaceChildren();gi=0;shown=true;W.dataset.state='answer';
  W.appendChild(el('h1',null,d.title));
  grp('In plain words',true).appendChild(el('div','txt',d.plain));
  if(d.example||d.code){const c=grp('Example',true);if(d.example)c.appendChild(el('div','txt',d.example));if(d.code)c.appendChild(el('pre',null,d.code))}
  if(d.flow&&d.flow.length>1){const c=grp('How it flows',true);const row=el('div','flow');d.flow.forEach((t,i)=>{if(i){const a=arrow();a.style.setProperty('--d',i);row.appendChild(a)}const bx=el('div','box'+(i==d.flow.length-1?' end':''),t);bx.style.setProperty('--d',i);row.appendChild(bx)});c.appendChild(row)}
  if(d.related&&d.related.length){const c=grp('Related',false);c.className='chips';d.related.forEach(t=>{const b=el('button','chip',t);b.onclick=()=>post({type:'term',text:t});c.appendChild(b)})}
  ask.disabled=false;ask.value='';ask.focus();report();
}
function showError(d){
  F.classList.remove('busy');W.classList.remove('dim');W.dataset.state='error';  W.replaceChildren();W.appendChild(el('h1',null,'Explain'));
  const c=grp(null,true);c.appendChild(el('div','txt err',d.msg));
  if(d.retry){const b=el('button','btn','Try again');b.onclick=()=>post({type:'retry'});c.appendChild(b)}
  ask.disabled=false;report();
}
function currentSelection(){
  const a=document.activeElement;
  if(a&&a.tagName==='INPUT'&&a.selectionStart!==a.selectionEnd)return a.value.substring(a.selectionStart,a.selectionEnd);
  return String(window.getSelection()||'');
}
function flash(m){const t=document.getElementById('toast');t.textContent=m;t.classList.add('on');clearTimeout(t._h);t._h=setTimeout(()=>t.classList.remove('on'),1300)}
function flashCopied(){flash('Copied')}
let pinned=false;
function setPinned(on){pinned=on;document.getElementById('pin').classList.toggle('on',on)}
document.getElementById('pin').onclick=()=>{setPinned(!pinned);post({type:'pin',on:pinned})};
document.getElementById('close').onclick=()=>post({type:'close'});
document.getElementById('save').onclick=()=>post({type:'save'});
ask.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.isComposing&&ask.value.trim()){e.preventDefault();post({type:'ask',text:ask.value.trim()})}});
document.addEventListener('contextmenu',e=>e.preventDefault());
report();
</script></body></html>
"""

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
