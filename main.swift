// Streamed for macOS — multiview player for streamed.pk
// Port of the Fire TV app: auto best stream + failover, learned source scores, ad blocking, anti-sandbox shim.
// On the Mac every tile plays at the same time (muted except the selected one).

import AppKit
import WebKit
import UserNotifications
import Network

// MARK: - Basics

let API = "https://streamed.pk/api"
let UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
let MAX_TILES = 6
let UD = UserDefaults.standard
let BG = ProcessInfo.processInfo.arguments.contains("--bg")

func rgb(_ h: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
let C_BG = rgb(0x0B0F17), C_CARD = rgb(0x161C28), C_ACCENT = rgb(0xE5484D), C_TEXT = rgb(0xEDEFF3), C_MUTED = rgb(0x8A93A6)

func nowMs() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Streamed.log")
let logQ = DispatchQueue(label: "streamed.log")
/// Keep the log small: above 5 MB it is moved to Streamed.old.log at launch.
func rotateLog() {
    let fm = FileManager.default
    guard let sz = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? NSNumber, sz.intValue > 5_000_000 else { return }
    let old = logURL.deletingLastPathComponent().appendingPathComponent("Streamed.old.log")
    try? fm.removeItem(at: old)
    try? fm.moveItem(at: logURL, to: old)
}
let logFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
nonisolated(unsafe) var logHandle: FileHandle?
func log(_ s: String) {
    let d = Date()
    logQ.async {
        let line = logFmt.string(from: d) + " [\(getpid())] " + s + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if logHandle == nil {
            if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
            logHandle = try? FileHandle(forWritingTo: logURL)
        }
        guard let h = logHandle else { return }
        h.seekToEndOfFile(); h.write(data)
    }
}

func host(_ u: String) -> String { URL(string: u)?.host?.lowercased() ?? "" }
func str(_ a: Any?) -> String {
    if let s = a as? String { return s }
    if let n = a as? NSNumber { return n.stringValue }
    return ""
}
func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
func catName(_ c: String) -> String {
    switch c {
    case "football": return "Fußball"
    case "basketball": return "Basketball"
    case "american-football": return "Football (NFL)"
    case "hockey": return "Eishockey"
    case "tennis": return "Tennis"
    case "fight": return "Kampfsport"
    case "motor-sports": return "Motorsport"
    case "baseball": return "Baseball"
    default: return cap(c.replacingOccurrences(of: "-", with: " "))
    }
}
func srcOf(_ title: String) -> String { String(title.split(separator: " ").first ?? "").lowercased() }
func score(_ src: String) -> Float { UD.float(forKey: "score:" + src) }

func makeLabel(_ size: CGFloat, bold: Bool = false, color: NSColor = C_TEXT) -> NSTextField {
    let l = NSTextField(labelWithString: "")
    l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    l.maximumNumberOfLines = 1
    return l
}

class FlippedView: NSView { override var isFlipped: Bool { true } }

func sym(_ name: String, _ size: CGFloat = 13, _ weight: NSFont.Weight = .semibold) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
}
func sportSymbol(_ c: String) -> String {
    switch c {
    case "football": return "soccerball"
    case "basketball": return "basketball.fill"
    case "american-football": return "football.fill"
    case "hockey": return "hockey.puck.fill"
    case "tennis": return "tennis.racket"
    case "fight": return "figure.boxing"
    case "motor-sports": return "flag.checkered"
    case "baseball": return "baseball.fill"
    default: return "sportscourt.fill"
    }
}
/// Round translucent HUD button with an SF Symbol (like the QuickTime / TV app controls).
final class HUDButton: NSButton {
    init(_ symbol: String, size: CGFloat = 13, tip: String) {
        super.init(frame: .zero)
        isBordered = false
        image = sym(symbol, size) ?? NSImage()
        imagePosition = .imageOnly
        contentTintColor = .white
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
        toolTip = tip
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }
}
/// Gradient so the controls stay readable on any video frame.
final class GradientView: PassView {
    let g = CAGradientLayer()
    var top = true
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        g.colors = [NSColor(white: 0, alpha: 0.75).cgColor, NSColor(white: 0, alpha: 0).cgColor]
        layer?.addSublayer(g)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); g.frame = bounds; g.startPoint = CGPoint(x: 0.5, y: 1); g.endPoint = CGPoint(x: 0.5, y: 0) }
}
func hud() -> NSVisualEffectView {
    let v = NSVisualEffectView()
    v.material = .hudWindow; v.blendingMode = .withinWindow; v.state = .active
    v.wantsLayer = true; v.layer?.cornerRadius = 12; v.layer?.masksToBounds = true
    return v
}
class PassView: FlippedView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }

// MARK: - Models / API

struct Match {
    let id: String, title: String, category: String, date: Int64, popular: Bool
    let home: String, away: String
    let homeBadge: String, awayBadge: String
    let raw: [String: Any]
    let sources: [(source: String, id: String)]
    init?(_ d: [String: Any]) {
        id = str(d["id"]); title = str(d["title"]); category = str(d["category"])
        date = (d["date"] as? NSNumber)?.int64Value ?? 0
        popular = (d["popular"] as? NSNumber)?.boolValue ?? false
        let teams = d["teams"] as? [String: Any]
        var h = str((teams?["home"] as? [String: Any])?["name"]), a = str((teams?["away"] as? [String: Any])?["name"])
        if h.isEmpty || a.isEmpty {
            let parts = str(d["title"]).components(separatedBy: " vs ")
            if parts.count == 2 { h = parts[0]; a = parts[1] }
        }
        home = h; away = a
        homeBadge = str((teams?["home"] as? [String: Any])?["badge"]); awayBadge = str((teams?["away"] as? [String: Any])?["badge"])
        raw = d
        let src = (d["sources"] as? [[String: Any]]) ?? []
        sources = src.map { (source: str($0["source"]), id: str($0["id"])) }.filter { !$0.source.isEmpty && !$0.id.isEmpty }
        if sources.isEmpty || title.isEmpty { return nil }
    }
    var is247: Bool { date < 100_000_000_000 }
    var isLive: Bool { date > 0 && date <= Int64(Date().timeIntervalSince1970 * 1000) }
}

struct StreamInfo { let url: String; let title: String; let hd: Bool }

func getJSON(_ path: String, timeout: TimeInterval = 10) async -> Any? {
    guard let url = URL(string: API + path) else { return nil }
    var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    r.setValue(UA, forHTTPHeaderField: "User-Agent")
    r.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let (d, _) = try? await URLSession.shared.data(for: r) else { return nil }
    return try? JSONSerialization.jsonObject(with: d)
}

func sortStreams(_ raw: [StreamInfo]) -> [StreamInfo] {
    func lang(_ s: StreamInfo) -> Int { let l = s.title.lowercased(); return l.contains("english") || l.contains("german") ? 0 : 1 }
    var seen = Set<String>()
    return raw.filter { seen.insert($0.url).inserted }.sorted { a, b in
        if a.hd != b.hd { return a.hd }
        if lang(a) != lang(b) { return lang(a) < lang(b) }
        return a.title < b.title
    }
}

/// onFirst: called once as soon as the first source delivers an HD stream (so playback can start before slow sources answer).
func fetchStreams(_ m: Match, onFirst: (@Sendable ([StreamInfo]) async -> Void)? = nil) async -> [StreamInfo] {
    let srcs = m.sources.map { ($0.source, $0.id) }
    let raw = await withTaskGroup(of: [StreamInfo].self) { g -> [StreamInfo] in
        for (source, id) in srcs {
            g.addTask {
                guard let arr = await getJSON("/stream/\(source)/\(id)", timeout: 6) as? [[String: Any]] else { return [] }
                return arr.compactMap { x -> StreamInfo? in
                    let url = str(x["embedUrl"])
                    if url.isEmpty { return nil }
                    let s = str(x["source"]).isEmpty ? source : str(x["source"])
                    let lang = str(x["language"])
                    let title = cap(s) + " " + str(x["streamNo"]) + (lang.isEmpty ? "" : " · " + lang)
                    return StreamInfo(url: url, title: title, hd: (x["hd"] as? NSNumber)?.boolValue ?? false)
                }
            }
        }
        var out: [StreamInfo] = []
        var fired = false
        for await part in g {
            out += part
            if !fired, let onFirst, out.contains(where: { $0.hd }) {
                fired = true
                await onFirst(sortStreams(out))
            }
        }
        return out
    }
    return sortStreams(raw)
}

// MARK: - Team badges (streamed.pk image API, cached in memory)

@MainActor final class Badges {
    static var cache: [String: NSImage] = [:]
    static var loading = Set<String>()
    static var onLoad: (() -> Void)?
    static var pending = false
    static func get(_ id: String) -> NSImage? {
        if id.isEmpty { return nil }
        if let i = cache[id] { return i }
        if loading.contains(id) { return nil }
        loading.insert(id)
        Task { @MainActor in
            guard let url = URL(string: "https://streamed.pk/api/images/badge/\(id).webp") else { return }
            var r = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
            r.setValue(UA, forHTTPHeaderField: "User-Agent")
            if let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: d) {
                cache[id] = img
                if !pending {   // coalesce: one list refresh for a burst of badges
                    pending = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { pending = false; onLoad?() } }
                }
            }
        }
        return nil
    }
}

// MARK: - Live scores (ESPN public scoreboard) + goal alerts

struct Score: Equatable { var h: Int; var a: Int; var clock: String; var state: String }

let ESPN_LEAGUES = ["ger.1", "ger.2", "aut.1", "eng.1", "eng.2", "esp.1", "ita.1", "fra.1", "ned.1", "por.1", "sco.1", "tur.1", "bel.1",
                    "uefa.champions", "uefa.europa", "uefa.europa.conf", "uefa.nations", "fifa.world", "fifa.worldq.uefa", "usa.1", "ger.dfb_pokal", "eng.fa", "esp.copa_del_rey", "ita.coppa_italia"]
let WEAK_TOKENS: Set<String> = ["real", "city", "united", "borussia", "sporting", "atletico", "athletic", "olympique", "saint", "inter", "racing", "dynamo", "union", "town", "rovers", "wanderers", "hotspur", "albion"]
let STOP_TOKENS: Set<String> = ["fc", "sc", "sv", "cf", "ac", "afc", "club", "the", "fk", "vfb", "vfl", "tsg", "bsc", "ssc", "rcd", "cd", "ud", "sd", "de", "of", "and", "calcio", "1899", "1900", "1909", "1846", "1904", "1910"]

func nameTokens(_ s: String) -> Set<String> {
    let f = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    let parts = f.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
    return Set(String(parts).split(separator: " ").map(String.init).filter { $0.count >= 3 && !STOP_TOKENS.contains($0) && Int($0) == nil })
}
func sideScore(_ a: Set<String>, _ b: Set<String>) -> Double {
    var sc = 0.0
    for x in a {
        if b.contains(x) || b.contains(where: { ($0.count >= 5 && x.count >= 5) && ($0.hasPrefix(x) || x.hasPrefix($0)) }) {
            sc += WEAK_TOKENS.contains(x) ? 0.4 : 1
        }
    }
    return sc
}

func fetchURL(_ u: String) async -> Any? {
    guard let url = URL(string: u) else { return nil }
    var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
    r.setValue(UA, forHTTPHeaderField: "User-Agent")
    guard let (d, _) = try? await URLSession.shared.data(for: r) else { return nil }
    return try? JSONSerialization.jsonObject(with: d)
}

struct EspnEvent { let id: String; let home: Set<String>; let away: Set<String>; let score: Score }

@MainActor final class Scores {
    static let shared = Scores()
    var delay: Double = (UD.object(forKey: "spoilerDelay") as? NSNumber)?.doubleValue ?? 45
    var events: [String: EspnEvent] = [:]
    var hist: [String: [(Double, Score)]] = [:]
    var shown: [String: Score] = [:]
    var matches: [String: Match] = [:]
    var map: [String: (String, Bool)] = [:]   // streamed id -> (espn id, swapped)
    var onChange: (() -> Void)?
    var onGoal: ((String, String, String) -> Void)?   // streamed id, headline, detail
    var started = false

    func start() {
        guard !started else { return }
        started = true
        fetch()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in MainActor.assumeIsolated { Scores.shared.fetch() } }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in MainActor.assumeIsolated { Scores.shared.tick() } }
    }

    func setDelay(_ d: Double) { delay = d; UD.set(d, forKey: "spoilerDelay"); tick() }

    func register(_ ms: [Match]) {
        var added = false
        for m in ms where m.category == "football" && !m.home.isEmpty {
            if matches[m.id] == nil { added = true }
            matches[m.id] = m
        }
        if added { remap() }
    }

    func fetch() {
        Task { @MainActor in
            let lists = await withTaskGroup(of: [EspnEvent].self) { g -> [EspnEvent] in
                for l in ESPN_LEAGUES {
                    g.addTask {
                        guard let d = await fetchURL("https://site.api.espn.com/apis/site/v2/sports/soccer/\(l)/scoreboard") as? [String: Any],
                              let evs = d["events"] as? [[String: Any]] else { return [] }
                        return evs.compactMap { e -> EspnEvent? in
                            guard let comp = (e["competitions"] as? [[String: Any]])?.first,
                                  let cs = comp["competitors"] as? [[String: Any]], cs.count == 2,
                                  let st = e["status"] as? [String: Any], let ty = st["type"] as? [String: Any] else { return nil }
                            var hT = Set<String>(), aT = Set<String>(), hS = 0, aS = 0
                            for c in cs {
                                let t = c["team"] as? [String: Any] ?? [:]
                                var tk = Set<String>()
                                for k in ["displayName", "shortDisplayName", "location", "name"] { tk.formUnion(nameTokens(str(t[k]))) }
                                let sc = Int(str(c["score"])) ?? 0
                                if str(c["homeAway"]) == "home" { hT = tk; hS = sc } else { aT = tk; aS = sc }
                            }
                            let state = str(ty["state"])
                            var clock = str(ty["shortDetail"])
                            if state == "post" { clock = "Ende" } else if clock == "HT" || clock == "Halftime" { clock = "Pause" }
                            return EspnEvent(id: str(e["id"]), home: hT, away: aT, score: Score(h: hS, a: aS, clock: clock, state: state))
                        }
                    }
                }
                var out: [EspnEvent] = []
                for await x in g { out += x }
                return out
            }
            if lists.isEmpty { return }
            let now = nowMs() / 1000
            for e in lists where e.score.state != "pre" {
                events[e.id] = e
                var h = hist[e.id] ?? []
                if h.last?.1 != e.score { h.append((now, e.score)) }
                if h.count > 40 { h.removeFirst(h.count - 40) }
                hist[e.id] = h
            }
            remap()
            tick()
        }
    }

    func remap() {
        for (id, m) in matches where map[id] == nil {
            let mh = nameTokens(m.home), ma = nameTokens(m.away)
            var best: (String, Bool, Double)?
            for e in events.values {
                let s1 = (sideScore(mh, e.home), sideScore(ma, e.away))
                let s2 = (sideScore(mh, e.away), sideScore(ma, e.home))
                if s1.0 >= 1 && s1.1 >= 1, s1.0 + s1.1 > (best?.2 ?? 0) { best = (e.id, false, s1.0 + s1.1) }
                if s2.0 >= 1 && s2.1 >= 1, s2.0 + s2.1 > (best?.2 ?? 0) { best = (e.id, true, s2.0 + s2.1) }
            }
            if let b = best { map[id] = (b.0, b.1); log("score match: \(m.title) -> espn \(b.0)\(b.1 ? " (swapped)" : "")") }
        }
    }

    func tick() {
        let now = nowMs() / 1000
        var changed = false
        for (eid, h) in hist {
            guard let first = h.first else { continue }
            let cur = h.last(where: { $0.0 <= now - delay })?.1 ?? (shown[eid] == nil ? first.1 : nil)
            guard let cur, cur != shown[eid] else { continue }
            let old = shown[eid]
            shown[eid] = cur
            changed = true
            if let old, cur.h + cur.a > old.h + old.a {
                for (mid, (e2, sw)) in map where e2 == eid {
                    guard let m = matches[mid] else { continue }
                    let homeScored = cur.h > old.h
                    let scorer = (homeScored != sw) ? m.home : m.away
                    let (l, r) = sw ? (cur.a, cur.h) : (cur.h, cur.a)
                    onGoal?(mid, "TOR! \(scorer)", "\(m.home) \(l):\(r) \(m.away)  ·  \(cur.clock)")
                }
            }
        }
        if changed { onChange?() }
    }

    /// Score in the streamed match's own home/away orientation.
    func score(_ m: Match) -> Score? {
        guard let (eid, sw) = map[m.id], var s = shown[eid] else { return nil }
        if sw { s = Score(h: s.a, a: s.h, clock: s.clock, state: s.state) }
        return s
    }
}

func notifyGoal(_ title: String, _ body: String) {
    if BG { return }
    let c = UNMutableNotificationContent()
    c.title = title; c.body = body; c.sound = .default
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
        if let err { log("notify error: \(err)") }
    }
}

// MARK: - Auto update from GitHub releases

let UPDATE_API = "https://api.github.com/repos/6nilsss/streamed-mac/releases/latest"

@MainActor final class Updater {
    static let shared = Updater()
    var pendingScript: String?
    var busy = false
    var onStatus: ((String) -> Void)?

    var current: String {
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "--fake-version"), i + 1 < a.count { return a[i + 1] }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func check(manual: Bool, canRestartNow: @escaping () -> Bool) {
        guard !busy, pendingScript == nil else { if manual, pendingScript != nil { onStatus?("Update ist schon bereit und wird beim Beenden installiert") }; return }
        busy = true
        Task { @MainActor in
            defer { self.busy = false }
            guard let d = await fetchURL(UPDATE_API) as? [String: Any] else {
                if manual { onStatus?("Update-Check fehlgeschlagen – kein Internet?") }
                return
            }
            let tag = str(d["tag_name"]).trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            log("[update] installed \(current), latest \(tag)")
            guard Updater.newer(tag, than: current) else { if manual { onStatus?("Streamed ist aktuell (\(current))") }; return }
            let assets = d["assets"] as? [[String: Any]] ?? []
            guard let a = assets.first(where: { str($0["name"]).hasSuffix(".zip") }), let url = URL(string: str(a["browser_download_url"])) else { return }
            let appPath = Bundle.main.bundlePath
            let parent = (appPath as NSString).deletingLastPathComponent
            if appPath.contains("/AppTranslocation/") || !FileManager.default.isWritableFile(atPath: parent) {
                onStatus?("Update \(tag) verfügbar – zieh Streamed in den Programme-Ordner, dann installiert es sich automatisch")
                return
            }
            onStatus?("Lade Update \(tag)…")
            guard let (tmp, resp) = try? await URLSession.shared.download(from: url), (resp as? HTTPURLResponse)?.statusCode == 200 else {
                onStatus?("Update-Download fehlgeschlagen"); return
            }
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("streamed-update-\(tag)-\(getpid())")
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let zip = dir.appendingPathComponent("Streamed.zip")
            try? fm.moveItem(at: tmp, to: zip)
            let unz = Process()
            unz.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unz.arguments = ["-x", "-k", zip.path, dir.path]
            try? unz.run(); unz.waitUntilExit()
            let newApp = dir.appendingPathComponent("Streamed.app")
            guard let b = Bundle(path: newApp.path), b.bundleIdentifier == Bundle.main.bundleIdentifier ?? "at.nils.streamed" else {
                onStatus?("Update-Paket ungültig – übersprungen"); return
            }
            let script = dir.appendingPathComponent("install.sh")
            let sh = """
            #!/bin/sh
            while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
            OLD='\(appPath)'
            NEW='\(newApp.path)'
            rm -rf "$OLD.old"
            if mv "$OLD" "$OLD.old" && mv "$NEW" "$OLD"; then rm -rf "$OLD.old"; else [ -d "$OLD.old" ] && [ ! -d "$OLD" ] && mv "$OLD.old" "$OLD"; fi
            xattr -dr com.apple.quarantine "$OLD" 2>/dev/null
            if [ "$1" = "relaunch" ]; then open "$OLD"; fi
            """
            do { try sh.write(to: script, atomically: true, encoding: .utf8) } catch { onStatus?("Update konnte nicht vorbereitet werden"); return }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            pendingScript = script.path
            log("[update] \(tag) downloaded, ready to install")
            if canRestartNow() {
                onStatus?("Update \(tag) wird installiert – Streamed startet gleich neu…")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                runPending(relaunch: true)
                NSApp.terminate(nil)
            } else {
                onStatus?("Update \(tag) ist bereit und wird beim Beenden installiert")
            }
        }
    }

    func runPending(relaunch: Bool) {
        guard let s = pendingScript else { return }
        pendingScript = nil
        log("[update] installing (relaunch=\(relaunch))")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [s] + (relaunch ? ["relaunch"] : [])
        try? p.run()
    }
}

// MARK: - Ad blocking (WebKit content rules, same lists as on the TV)

let ALLOW = ["embed.st", "strmd.st", "strmd.b-cdn.net", "tiktokcdn.com", "jsdelivr.net", "streamed.pk"]
let BLOCK = ["onepyrincehyarey.org", "stuins.com", "toxsales1.com", "togglevpn.net", "stripe.com", "stripe.network",
             "solidgate.com", "googletagmanager.com", "google-analytics.com", "doubleclick.net", "cdn-lab.shop", "datapointhq.com",
             "ip234.in", "veltrix42", "zinitelophich.com", "pages.dev", "histats.com", "yandex", "facebook", "hotjar", "clarity.ms",
             "adexchangerapid", "usrpubtrk", "ntwkbc"]
let BLOCK_TLD = ["top", "sbs", "cyou", "xyz", "click", "online", "site", "lol", "icu", "cfd"]

func adRulesJSON() -> String {
    var r: [[String: Any]] = []
    func esc(_ s: String) -> String { s.replacingOccurrences(of: ".", with: "\\.") }
    func rule(_ filter: String, _ action: String, types: [String]? = nil, load: String? = nil) {
        var t: [String: Any] = ["url-filter": filter]
        if let types { t["resource-type"] = types }
        if let load { t["load-type"] = [load] }
        r.append(["trigger": t, "action": ["type": action]])
    }
    // unknown third-party documents (ad iframes / popunders) unless they look like a player
    rule(".*", "block", types: ["document"], load: "third-party")
    for p in ["embed", "player", "stream", "source", "\\.m3u8", "\\.php"] { rule(p, "ignore-previous-rules", types: ["document"]) }
    for b in BLOCK { rule("^[^:]+://[^/]*" + esc(b), "block") }
    for t in BLOCK_TLD { rule("^[^:]+://[^/:]*\\." + t + "[:/]", "block") }
    // never block the page we deliberately opened
    rule(".*", "ignore-previous-rules", types: ["document"], load: "first-party")
    for a in ALLOW { rule("^[^:]+://([^/]*\\.)?" + esc(a) + "[:/]", "ignore-previous-rules") }
    rule("/ad\\.html", "block")
    rule("clappr-chromecast-plugin", "block")
    let d = try! JSONSerialization.data(withJSONObject: r)
    return String(data: d, encoding: .utf8)!
}
var ruleList: WKContentRuleList?

// MARK: - Injected JS

let SHIM = #"""
(function(){
try{performance.setResourceTimingBufferSize(5000)}catch(e){}
try{['MediaSource','ManagedMediaSource','WebKitMediaSource'].forEach(function(n){var M=window[n];if(M&&M.prototype&&M.prototype.setLiveSeekableRange){M.prototype.setLiveSeekableRange=function(){};M.prototype.clearLiveSeekableRange=function(){};}})}catch(e){}
try{Object.defineProperty(window,'sandDetect',{get:function(){return function(){};},set:function(){},configurable:false});}catch(e){}
var f=function(){return {closed:false,close:function(){},focus:function(){},blur:function(){},postMessage:function(){},location:{href:'',replace:function(){},assign:function(){}},document:{write:function(){},close:function(){},open:function(){}}};};
try{window.open=function(){return f();};}catch(e){}
try{var fe={destroy:function(){},on:function(){},off:function(){}};Object.defineProperty(window,'__wasm_jw_engine',{get:function(){return fe;},set:function(){},configurable:false});}catch(e){}
try{var _jw;Object.defineProperty(window,'jwplayer',{configurable:true,get:function(){return _jw},set:function(f){if(typeof f!=='function'||f.__w){_jw=f;return}
var w=function(){var p=f.apply(this,arguments);if(p&&p.setup&&!p.__ws){var o=p.setup;p.setup=function(c){try{if(c&&typeof c==='object'){c.safarihlsjs=true;c.hlsjsdefault=true;c.hlsjsConfig=Object.assign({},c.hlsjsConfig||{},{backBufferLength:90,maxBufferLength:30});try{delete c.hlsjsConfig.p2pConfig}catch(e){}}}catch(e){}return o.apply(this,arguments)};p.__ws=1}return p};
for(var k in f){try{w[k]=f[k]}catch(e){}}w.__w=1;_jw=w}})}catch(e){}
if(window.__mute===undefined)window.__mute=true;
var n=0,iv=setInterval(function(){n++;if(n>150){clearInterval(iv);return;}
if(window.__userPaused)return;
try{var p=window.jwplayer&&jwplayer();if(p&&p.getState){var s=p.getState();if(s!=='playing'&&s!=='buffering'){p.setMute(!!window.__mute);p.play();}}}catch(e){}
},250);
})();
"""#

let FS_HOOK = #"""
(function(){function go(){try{window.webkit.messageHandlers.fs.postMessage(1)}catch(e){}return Promise.resolve()}
var P=Element.prototype;P.requestFullscreen=go;P.webkitRequestFullscreen=go;P.webkitRequestFullScreen=go;
try{HTMLVideoElement.prototype.webkitEnterFullscreen=go;HTMLVideoElement.prototype.webkitEnterFullScreen=go}catch(e){}
document.exitFullscreen=go;document.webkitExitFullscreen=go;document.webkitCancelFullScreen=go;
try{Object.defineProperty(document,'fullscreenEnabled',{get:function(){return true}});Object.defineProperty(document,'webkitFullscreenEnabled',{get:function(){return true}})}catch(e){}
})();
"""#

final class FSProxy: NSObject, WKScriptMessageHandler {
    weak var tile: Tile?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { if let t = tile { t.area?.toggleSolo(t) } }
    }
}

let MONITOR = #"""
(function(){var b=(document.body&&document.body.innerText)||'';
var bad=b.indexOf('Remove sandbox')>=0;
var c=document.querySelector('.jwplayer');var ads=!!(c&&/jw-flag-ads/.test(c.className));
if(!ads){var vs=document.querySelectorAll('video');for(var i=0;i<vs.length;i++){var x=vs[i];if(!x.paused&&x.closest&&x.closest('.jw-ads,.jw-ads-view,[class*=ima],[id*=ima],[class*=ad-container],[class*=preroll]')){ads=true;break;}}}
var m=0;try{m=performance.getEntriesByType('resource').some(function(e){return e.name.indexOf('.m3u8')>=0})?1:0}catch(e){}
var v=document.querySelector('.jw-media video')||document.querySelector('video');
if(!v)return JSON.stringify({v:0,bad:bad,ads:ads,m:m});
try{var be=0;if(v.buffered&&v.buffered.length)be=v.buffered.end(v.buffered.length-1);if(v.seekable&&v.seekable.length)be=Math.max(be,v.seekable.end(v.seekable.length-1));if(be>0&&isFinite(be)){var off=be-performance.now()/1000;if(window.__edge===undefined||off>window.__edge)window.__edge=off}}catch(e){}
var mute=!!window.__mute;if(v.muted!==mute){v.muted=mute;try{jwplayer().setMute(mute)}catch(e){}}
if(v.paused&&!window.__userPaused&&!ads){try{jwplayer().play()}catch(e){v.play()}}
return JSON.stringify({v:1,bad:bad,ads:ads,m:m,t:v.currentTime,p:v.paused,h:v.videoHeight,err:!!v.error});})()
"""#

let GO_LIVE = #"""
(function(){var v=document.querySelector('.jw-media video')||document.querySelector('video');if(!v)return;
window.__userPaused=false;
try{if(v.seekable&&v.seekable.length){var e=v.seekable.end(v.seekable.length-1);if(e-v.currentTime>6)v.currentTime=e-4;}}catch(x){}
try{jwplayer().play()}catch(x){v.play()}})()
"""#

func seekJS(_ d: Double) -> String { #"""
(function(){var v=document.querySelector('.jw-media video')||document.querySelector('video');if(!v)return JSON.stringify({ok:0,why:'novideo'});
function rng(r){var a=[];for(var i=0;i<r.length;i++)a.push([+r.start(i).toFixed(1),+r.end(i).toFixed(1)]);return a}
var sk=v.seekable,bf=v.buffered,s=null,e=null;
if(sk&&sk.length){s=sk.start(0);e=sk.end(sk.length-1)}
if(bf&&bf.length){var bs=bf.start(0),be=bf.end(bf.length-1);if(s===null||bs<s)s=bs;if(e===null||be>e)e=be}
var diag={sk:rng(sk||[]),bf:rng(bf||[]),ct:+v.currentTime.toFixed(1),src:(v.currentSrc||'').slice(0,12),dur:v.duration};
if(s===null)return JSON.stringify({ok:0,why:'nobuf',diag:diag});
var want=v.currentTime+(\#(d));var t=Math.min(e-1.5,Math.max(s+0.3,want));
if(bf&&bf.length){var ok=false,best=null;for(var i=0;i<bf.length;i++){var a=bf.start(i)+0.3,b=bf.end(i)-0.5;if(t>=a&&t<=b){ok=true;break}if(b>t&&(best===null||a<best))best=a}
if(!ok){if(best!==null&&best<v.currentTime)t=best;else if(\#(d)<0){var ci=null;for(var j=0;j<bf.length;j++){if(v.currentTime>=bf.start(j)&&v.currentTime<=bf.end(j))ci=j}if(ci!==null)t=Math.max(t,bf.start(ci)+0.3)}}}
v.currentTime=t;window.__userPaused=false;try{jwplayer().play()}catch(x){v.play()}
return JSON.stringify({ok:1,behind:Math.max(0,Math.round(e-t)),win:Math.round(e-s),clamped:(t>want+1)?1:0,diag:diag});})()
"""# }

let STATE_JS = #"""
(function(){var v=document.querySelector('.jw-media video')||document.querySelector('video');if(!v||window.__edge===undefined)return JSON.stringify({});
var e=window.__edge+performance.now()/1000;return JSON.stringify({behind:Math.max(0,e-v.currentTime),paused:v.paused});})()
"""#

func seekBehindJS(_ b: Double) -> String { #"""
(function(){var v=document.querySelector('.jw-media video')||document.querySelector('video');if(!v||window.__edge===undefined)return 'no';
var e=window.__edge+performance.now()/1000,t=e-(\#(b));var bf=v.buffered;if(bf&&bf.length){var lo=bf.start(0)+0.3,hi=bf.end(bf.length-1)-0.5;t=Math.max(lo,Math.min(hi,t))}
v.currentTime=t;if(!window.__userPaused){try{jwplayer().play()}catch(x){v.play()}}return 'ok '+t.toFixed(1)})()
"""# }

let PAUSE_JS = #"""
(function(){var v=document.querySelector('.jw-media video')||document.querySelector('video');if(!v)return 'none';
if(v.paused){window.__userPaused=false;try{jwplayer().play()}catch(e){v.play()}return 'play'}
window.__userPaused=true;try{jwplayer().pause()}catch(e){v.pause()}return 'pause'})()
"""#

// MARK: - Watch party (MQTT 3.1.1 over TLS, public broker, QoS 0)

final class MQTT {
    let host: String, port: UInt16, clientId: String, topic: String
    var conn: NWConnection?
    var buf = Data()
    var ping: Timer?
    var closed = false
    var onMessage: ((Data) -> Void)?
    var onState: ((Bool) -> Void)?
    init(host: String, port: UInt16, clientId: String, topic: String) { self.host = host; self.port = port; self.clientId = clientId; self.topic = topic }

    static func str(_ s: String) -> Data { let b = Data(s.utf8); var d = Data([UInt8(b.count >> 8), UInt8(b.count & 255)]); d.append(b); return d }
    static func packet(_ type: UInt8, _ body: Data) -> Data {
        var d = Data([type]); var n = body.count
        repeat { var byte = UInt8(n % 128); n /= 128; if n > 0 { byte |= 128 }; d.append(byte) } while n > 0
        d.append(body); return d
    }
    func start() {
        closed = false
        buf = Data()
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tls)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            DispatchQueue.main.async {
                guard let self, self.conn === c else { return }
                switch st {
                case .ready:
                    var b = MQTT.str("MQTT"); b.append(contentsOf: [4, 0x02, 0, 60]); b.append(MQTT.str(self.clientId))
                    self.send(MQTT.packet(0x10, b))
                    self.receive()
                case .failed, .cancelled:
                    self.conn = nil; self.ping?.invalidate(); self.onState?(false)
                    if !self.closed { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in if let s = self, !s.closed, s.conn == nil { s.start() } } }
                default: break
                }
            }
        }
        c.start(queue: .main)
    }
    func send(_ d: Data) { conn?.send(content: d, completion: .contentProcessed { _ in }) }
    func publish(_ payload: Data) { var b = MQTT.str(topic); b.append(payload); send(MQTT.packet(0x30, b)) }
    func receive() {
        guard let c = conn else { return }
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            DispatchQueue.main.async {
                guard let self, self.conn === c else { return }
                if let data { self.buf.append(data); self.parse() }
                if done || err != nil { c.cancel(); return }
                self.receive()
            }
        }
    }
    func parse() {
        while buf.count >= 2 {
            let bytes = [UInt8](buf)
            var mult = 1, len = 0, i = 1
            while true {
                guard i < bytes.count else { return }
                let b = Int(bytes[i]); len += (b & 127) * mult; mult *= 128; i += 1
                if b & 128 == 0 { break }
                if i > 4 { buf = Data(); return }
            }
            guard bytes.count >= i + len else { return }
            let type = bytes[0] >> 4, qos = (bytes[0] >> 1) & 3
            let body = [UInt8](bytes[i..<(i + len)])
            buf = Data(bytes[(i + len)...])
            if type == 2 {
                var sub = Data([0, 1]); sub.append(MQTT.str(topic)); sub.append(0)
                send(MQTT.packet(0x82, sub))
                ping?.invalidate()
                ping = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.send(Data([0xC0, 0])) }
                onState?(true)
            } else if type == 3, body.count >= 2 {
                var off = 2 + (Int(body[0]) << 8 | Int(body[1]))
                if qos > 0 { off += 2 }
                if body.count >= off { onMessage?(Data(body[off...])) }
            }
        }
    }
    func stop() { closed = true; ping?.invalidate(); send(Data([0xE0, 0])); let c = conn; conn = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { c?.cancel() } }
}

@MainActor final class Party {
    static let shared = Party()
    weak var area: PlayerArea?
    var mqtt: MQTT?
    var code: String?
    var isHost = false
    let me = String(UUID().uuidString.prefix(8)).lowercased()
    var myName: String {
        if let n = ProcessInfo.processInfo.environment["STREAMED_NAME"] { return n }
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? "Freund"
    }
    var peerName: String?
    var peerSeen = 0.0
    var connected = false
    var applying = false
    var lastCorrection = 0.0
    var lastChat: String?
    var hb: Timer?
    var onUI: (() -> Void)?
    var active: Bool { code != nil }

    static func newCode() -> String {
        let a = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<4).map { _ in a.randomElement()! }) + "-" + String((0..<4).map { _ in a.randomElement()! })
    }

    var status: String {
        guard let code else { return "Mit einem Freund synchron schauen: Pause, Spulen und Stream gelten für beide." }
        var s = "Code: \(code)  ·  "
        s += !connected ? "verbinde…" : (peerName.map { "mit \($0) verbunden" } ?? "warte auf deinen Freund…")
        if let c = lastChat { s += "\n💬 " + c }
        return s
    }

    func start(host: Bool, code c: String) {
        leave(silent: true)
        let cc = c.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        code = cc; isHost = host; lastChat = nil
        let m = MQTT(host: "test.mosquitto.org", port: 8886, clientId: "streamed-" + me, topic: "streamed-mac/party/" + cc)
        m.onState = { [weak self] ok in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.connected = ok
                log("[party \(self.isHost ? "host" : "guest")] connected=\(ok)")
                if ok { self.send(["t": "hi"]); if self.isHost { self.sendState(act: true) } }
                self.onUI?()
            }
        }
        m.onMessage = { [weak self] d in MainActor.assumeIsolated { self?.receive(d) } }
        mqtt = m
        m.start()
        hb?.invalidate()
        hb = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in MainActor.assumeIsolated { Party.shared.beat() } }
        log("[party \(host ? "host" : "guest")] start \(cc)")
        onUI?()
    }

    func leave(silent: Bool = false) {
        if mqtt != nil { send(["t": "bye"]) }
        mqtt?.stop(); mqtt = nil
        hb?.invalidate(); hb = nil
        code = nil; peerName = nil; connected = false; lastChat = nil
        if !silent { onUI?() }
    }

    func send(_ d: [String: Any]) {
        guard let mqtt else { return }
        var m = d
        m["from"] = me; m["name"] = myName; m["host"] = isHost
        guard let data = try? JSONSerialization.data(withJSONObject: m) else { return }
        mqtt.publish(data)
    }

    func beat() {
        if let _ = peerName, nowMs() - peerSeen > 15000 { peerName = nil; onUI?() }
        sendState(act: false)
    }

    func chat(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active, !t.isEmpty else { return }
        send(["t": "chat", "text": t])
        lastChat = "Du: " + t
        area?.active?.toast("💬 Du: " + t)
        onUI?()
    }

    /// The local viewer did something (pause, seek, other stream, other game) -> tell the partner.
    func local(_ t: Tile) {
        guard active, !applying, t === area?.active else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { Party.shared.sendState(act: true) } }
    }

    func sendState(act: Bool) {
        guard active, connected, let t = area?.active, t.current >= 0, t.current < t.streams.count else { return }
        let url = t.streams[t.current].url, title = t.streams[t.current].title, started = t.started, paused = t.userPaused, raw = t.match.raw
        t.web.evaluateJavaScript(STATE_JS) { [weak self] r, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var msg: [String: Any] = ["t": "state", "act": act, "match": raw, "url": url, "stitle": title, "started": started, "paused": paused]
                if let s = r as? String, let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any], let b = o["behind"] { msg["behind"] = b }
                self.send(msg)
            }
        }
    }

    func receive(_ d: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], str(o["from"]) != me else { return }
        let name = str(o["name"]).isEmpty ? "Freund" : str(o["name"])
        let isNew = peerName == nil
        peerSeen = nowMs()
        switch str(o["t"]) {
        case "bye":
            area?.active?.toast("👋 \(name) hat die Watch-Party verlassen")
            peerName = nil; onUI?(); return
        default: break
        }
        peerName = name
        if isNew { area?.active?.toast("🎉 \(name) ist in der Watch-Party"); onUI?(); log("[party] peer \(name) joined") }
        switch str(o["t"]) {
        case "hi": if isHost { sendState(act: true) }
        case "chat":
            let txt = str(o["text"])
            lastChat = "\(name): \(txt)"
            area?.active?.toast("💬 \(name): \(txt)")
            log("[party] chat from \(name): \(txt)")
            if !NSApp.isActive { notifyGoal("💬 \(name)", txt) }
            onUI?()
        case "state": apply(o)
        default: break
        }
    }

    func apply(_ o: [String: Any]) {
        guard let area else { return }
        let act = (o["act"] as? NSNumber)?.boolValue ?? false
        let fromHost = (o["host"] as? NSNumber)?.boolValue ?? false
        if !act && !fromHost { return }   // only the host's heartbeat corrects drift
        guard let raw = o["match"] as? [String: Any], let m = Match(raw) else { return }
        let url = str(o["url"]), stitle = str(o["stitle"])
        applying = true
        defer { applying = false }
        if area.active == nil || area.active!.match.id != m.id {
            log("[party] open \(m.title)")
            area.add(m, replace: true)
            area.active?.toast("🎉 Watch-Party: \(m.title)")
        }
        guard let t = area.active else { return }
        if t.current < 0 || t.current >= t.streams.count || t.streams[t.current].url != url {
            log("[party] stream -> \(stitle)")
            t.playURL(url, title: stitle)
            return
        }
        guard t.started, (o["started"] as? NSNumber)?.boolValue == true else { return }
        let paused = (o["paused"] as? NSNumber)?.boolValue ?? false
        if paused != t.userPaused { t.setPaused(paused) }
        guard let theirs = (o["behind"] as? NSNumber)?.doubleValue else { return }
        t.web.evaluateJavaScript(STATE_JS) { [weak self] r, _ in
            MainActor.assumeIsolated {
                guard let self, let s = r as? String, let mo = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
                      let mine = (mo["behind"] as? NSNumber)?.doubleValue else { return }
                let diff = mine - theirs
                let now = nowMs()
                if abs(diff) > (act ? 1.0 : 2.5) && (act || now - self.lastCorrection > 8000) {
                    self.lastCorrection = now
                    log("[party] sync: mine \(String(format: "%.1f", mine))s theirs \(String(format: "%.1f", theirs))s -> seek (act=\(act))")
                    t.seekToBehind(theirs)
                } else if !act {
                    log("[party] in sync: diff \(String(format: "%.1f", diff))s")
                }
            }
        }
    }
}

final class Probe {
    let web: WKWebView, url: String
    let start = nowMs()
    var lastT = -1.0, h = 0, startedAt = 0.0, lastProgress = nowMs()
    var dead = false
    var goodSince = 0.0
    init(web: WKWebView, url: String) { self.web = web; self.url = url }
}

// MARK: - Tile (one game)

final class Tile: FlippedView, WKNavigationDelegate, WKUIDelegate {
    weak var area: PlayerArea?
    var web: WKWebView!
    var match: Match
    var streams: [StreamInfo] = []
    var failed: [Bool] = [], heights: [Int] = []
    var auto = true, listReady = false
    var current = -1
    var homeHost = ""
    var manifestSeen = false, hardError = false
    var hardErrorAt = 0.0, streamStart = 0.0, lastProgressAt = 0.0, freezeStart = 0.0, lastT = -1.0, lastPollAt = 0.0
    var started = false, userPaused = false
    var deadUrl: String?
    var errCount = 0
    var stalls: [Double] = []
    var openToken = 0
    var isActive = false { didSet { updateChrome() } }

    let bar = FlippedView()
    let barBG = GradientView()
    let titleL = makeLabel(14, bold: true)
    let infoL = makeLabel(11, color: NSColor(white: 1, alpha: 0.72))
    let streamBtn = HUDButton("list.bullet", tip: "Streams wählen")
    let closeBtn = HUDButton("xmark", size: 11, tip: "Spiel schließen")
    let backBtn = HUDButton("gobackward.10", tip: "10 Sekunden zurück (←)")
    let fwdBtn = HUDButton("goforward.10", tip: "10 Sekunden vor (→)")
    let liveBtn = HUDButton("dot.radiowaves.left.and.right", tip: "Zum Live-Punkt (L)")
    let toastBox = hud()
    let toastL = NSTextField(wrappingLabelWithString: "")
    let border = PassView()
    let goalBox = hud()
    let goalL = NSTextField(wrappingLabelWithString: "")
    var goalTask: Task<Void, Never>?
    var barTask: Task<Void, Never>?
    var toastTask: Task<Void, Never>?

    var muted: Bool { !isActive || (area?.muteAll ?? false) }

    init(match: Match, area: PlayerArea) {
        self.match = match
        self.area = area
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        makeWeb()

        bar.addSubview(barBG)
        for (b, a) in [(streamBtn, #selector(showMenu(_:))), (closeBtn, #selector(closeTapped)), (backBtn, #selector(backTapped)), (fwdBtn, #selector(fwdTapped)), (liveBtn, #selector(menuLive))] as [(NSButton, Selector)] {
            b.target = self
            b.action = a
            bar.addSubview(b)
        }
        titleL.textColor = .white
        let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.6); sh.shadowBlurRadius = 3; sh.shadowOffset = .zero
        titleL.shadow = sh
        bar.addSubview(titleL)
        bar.addSubview(infoL)
        addSubview(bar)

        toastL.font = .systemFont(ofSize: 13, weight: .medium)
        toastL.textColor = .white
        toastL.maximumNumberOfLines = 3
        toastBox.addSubview(toastL)
        toastBox.isHidden = true
        addSubview(toastBox)

        goalBox.layer?.cornerRadius = 22
        goalBox.layer?.borderWidth = 1
        goalBox.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        goalL.alignment = .center
        goalL.textColor = .white
        goalL.maximumNumberOfLines = 3
        goalBox.addSubview(goalL)
        goalBox.isHidden = true
        addSubview(goalBox)
        border.wantsLayer = true
        border.layer?.borderColor = NSColor.controlAccentColor.cgColor
        border.layer?.borderWidth = 0
        addSubview(border)
        showBar()
    }
    required init?(coder: NSCoder) { fatalError() }

    func makeWeb() {
        let w = newWeb()
        addSubview(w, positioned: .below, relativeTo: nil)
        web = w
    }

    func newWeb() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        if #available(macOS 14.0, *) { cfg.preferences.inactiveSchedulingPolicy = .none }
        if let rl = ruleList { cfg.userContentController.add(rl) }
        cfg.userContentController.addUserScript(WKUserScript(source: SHIM, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.addUserScript(WKUserScript(source: FS_HOOK, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let fp = FSProxy(); fp.tile = self
        cfg.userContentController.add(fp, name: "fs")
        let w = WKWebView(frame: bounds, configuration: cfg)
        w.customUserAgent = UA
        w.navigationDelegate = self
        w.uiDelegate = self
        w.underPageBackgroundColor = .black
        w.allowsMagnification = false
        if #available(macOS 13.3, *) { w.isInspectable = true }
        return w
    }

    // MARK: background pool – every other stream keeps playing muted (active tile)
    var probes: [Probe] = []
    var retryAt: [String: Double] = [:]
    var startFails: [Double] = []
    var restUntil = 0.0
    var hangSwitches: [Double] = []
    var lastAdoptAt = 0.0
    var openedAt = 0.0
    var rewound = false
    var hostFor: [ObjectIdentifier: String] = [:]
    static let POOL_MAX = 7

    func killProbe(_ p: Probe) {
        p.dead = true
        p.web.stopLoading(); p.web.loadHTMLString("", baseURL: nil); p.web.removeFromSuperview()
        hostFor[ObjectIdentifier(p.web)] = nil
    }
    func killProbes() { probes.forEach(killProbe); probes = [] }
    func ptitle(_ p: Probe) -> String { streams.first(where: { $0.url == p.url })?.title ?? "?" }
    var curURL: String { current >= 0 && current < streams.count ? streams[current].url : "" }
    var curH: Int { current >= 0 && current < heights.count ? heights[current] : 0 }

    var poolLimit: Int {
        guard auto, listReady, !streams.isEmpty else { return 0 }
        // fewer background decoders when several games are open (MacBook Air throttles, bandwidth adds up)
        let open = area?.tiles.count ?? 1
        if isActive { return open <= 1 ? Tile.POOL_MAX : (open == 2 ? 3 : 2) }
        return started ? 0 : (open >= 3 ? 2 : 4)
    }

    func spawnProbe(_ i: Int) {
        guard let url = URL(string: streams[i].url) else { return }
        let w = newWeb()
        w.frame = bounds
        addSubview(w, positioned: .below, relativeTo: web)
        hostFor[ObjectIdentifier(w)] = host(streams[i].url)
        var r = URLRequest(url: url)
        r.setValue("https://streamed.pk/", forHTTPHeaderField: "Referer")
        w.load(r)
        probes.append(Probe(web: w, url: streams[i].url))
    }

    /// Keep all other streams loaded and playing (muted), so a recovered or better stream can be taken over instantly.
    func maintainPool() {
        let now = nowMs()
        for p in probes where p.dead {
            killProbe(p)
            retryAt[p.url] = now + (p.startedAt > 0 ? 15000 : 30000)
        }
        probes.removeAll { $0.dead }
        let limit = poolLimit
        if limit == 0 { if !probes.isEmpty { killProbes() }; return }
        let cu = curURL
        for p in probes where p.url == cu { killProbe(p) }
        probes.removeAll { $0.dead }
        if probes.count > limit {
            let worst = probes.sorted { ($0.startedAt > 0 ? $0.h : -1) < ($1.startedAt > 0 ? $1.h : -1) }.prefix(probes.count - limit)
            for p in worst { killProbe(p) }
            probes.removeAll { $0.dead }
        }
        var have = Set(probes.map { $0.url }); have.insert(cu)
        var added: [String] = []
        for i in streams.indices where probes.count < limit {
            let u = streams[i].url
            if have.contains(u) || (retryAt[u] ?? 0) > now { continue }
            spawnProbe(i); have.insert(u); added.append(streams[i].title)
        }
        if !added.isEmpty { log("[\(match.title)] pool + \(added) (\(probes.count) im Hintergrund)") }
    }

    func pollProbes() {
        let now = nowMs()
        for p in probes where !p.dead {
            p.web.evaluateJavaScript("window.__mute=true;window.__userPaused=false;" + MONITOR) { [weak self, weak p] r, _ in
                guard let self, let p, !p.dead, let s = r as? String,
                      let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else { return }
                let v = (o["v"] as? NSNumber)?.intValue ?? 0, t = (o["t"] as? NSNumber)?.doubleValue ?? 0, h = (o["h"] as? NSNumber)?.intValue ?? 0
                let now = nowMs()
                if (o["bad"] as? NSNumber)?.boolValue == true { p.dead = true; return }
                if (o["ads"] as? NSNumber)?.boolValue == true { p.lastProgress = now; p.goodSince = 0; return }
                if v == 1 && h > 0 {
                    if p.lastT >= 0 && t > p.lastT + 0.05 {
                        if p.startedAt == 0 { p.startedAt = now; log("[\(self.match.title)] pool \(self.ptitle(p)) \(h)p nach \(Int(now - p.start))ms") }
                        if p.goodSince == 0 { p.goodSince = now }
                        p.h = h
                        p.lastProgress = now
                        if let i = self.streams.firstIndex(where: { $0.url == p.url }), i < self.heights.count {
                            self.heights[i] = h
                            if self.failed[i] { self.failed[i] = false; log("[\(self.match.title)] \(self.ptitle(p)) wieder da (\(h)p)") }
                        }
                    } else if now - p.lastProgress > 2500 { p.goodSince = 0 }
                    p.lastT = t
                }
            }
            if p.startedAt == 0 && now - p.start > 20000 { p.dead = true }
            if p.startedAt > 0 && now - p.lastProgress > 10000 { p.dead = true; log("[\(match.title)] pool \(ptitle(p)) hängt – später nochmal") }
        }
        decideProbes()
    }

    func bestReady(stable: Double = 0) -> Probe? {
        let now = nowMs()
        return probes.filter { !$0.dead && $0.startedAt > 0 && $0.goodSince > 0 && now - $0.goodSince >= stable }
            .max { $0.h != $1.h ? $0.h < $1.h : $0.goodSince > $1.goodSince }
    }

    func decideProbes() {
        guard auto, !probes.isEmpty else { return }
        let now = nowMs()
        if !started {
            if let b = bestReady(), b.h >= 1080 || now - b.startedAt > 2500 { adopt(b, why: "Schnellster Stream") }
            return
        }
        if userPaused || rewound { return }
        hangSwitches.removeAll { now - $0 > 60000 }
        // several hang-switches within a minute usually mean our own connection hiccups (all streams stall) -> be more patient
        let hangMs: Double = hangSwitches.count >= 2 ? 8000 : 3500
        if freezeStart != 0 && now - freezeStart > hangMs, let b = bestReady(stable: 1500) {
            hangSwitches.append(now)
            if hangSwitches.count == 2 { log("[\(match.title)] viele Hänger hintereinander – warte jetzt länger vor dem Wechsel") }
            adopt(b, why: "Hänger → sofort gewechselt", keepOld: true)
            return
        }
        let fresh = now - openedAt < 30000
        guard fresh || now - lastAdoptAt > 8000 else { return }
        if let b = bestReady(stable: fresh ? 500 : 3000), b.h > curH + 50 {
            adopt(b, why: "Bessere Qualität gefunden", keepOld: true)
        }
    }

    /// Swap a background stream that is already playing into the visible slot (no reload, no wait).
    func adopt(_ p: Probe, why: String, keepOld: Bool = false) {
        probes.removeAll { $0 === p }
        guard let i = streams.firstIndex(where: { $0.url == p.url }) else { killProbe(p); return }
        let old: WKWebView = web
        let oldURL = curURL, oldH = curH, oldOK = started && freezeStart == 0
        hostFor[ObjectIdentifier(p.web)] = nil
        addSubview(p.web, positioned: .above, relativeTo: old)
        web = p.web
        if keepOld && !oldURL.isEmpty && oldURL != p.url && old !== p.web {
            let q = Probe(web: old, url: oldURL)
            let n = nowMs()
            q.startedAt = n; q.h = oldH; q.lastProgress = n; q.goodSince = oldOK ? n : 0
            hostFor[ObjectIdentifier(old)] = host(oldURL)
            old.evaluateJavaScript("window.__mute=true;var v=document.querySelector('.jw-media video')||document.querySelector('video');if(v)v.muted=true;try{jwplayer().setMute(true)}catch(e){}", completionHandler: nil)
            probes.append(q)
        } else {
            old.stopLoading(); old.loadHTMLString("", baseURL: nil); old.removeFromSuperview()
        }
        current = i
        failed[i] = false
        retryAt[p.url] = nil
        homeHost = host(p.url)
        userPaused = false; hardError = false; manifestSeen = true; rewound = false
        lastT = -1; freezeStart = 0; stalls = []; errCount = 0; lastPollAt = 0
        streamStart = p.start; lastProgressAt = nowMs(); lastAdoptAt = nowMs()
        log("[\(match.title)] adopt \(streams[i].title) \(p.h)p (\(why))")
        applyAudio()
        onStarted(p.h)
        toast(streams[i].title + " · \(p.h)p\n" + why)
        Party.shared.local(self)
    }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        web.frame = bounds
        for p in probes { p.web.frame = bounds }
        // leave room for the traffic lights when this tile sits in the window's top-left corner
        var lead: CGFloat = 14
        if let win = window, !win.styleMask.contains(.fullScreen), let cv = win.contentView {
            let p = convert(NSPoint.zero, to: cv)
            if p.x < 10 && (cv.isFlipped ? p.y < 10 : p.y > cv.bounds.height - 10) { lead = 118 }
        }
        bar.frame = NSRect(x: 0, y: 0, width: w, height: 72)
        barBG.frame = bar.bounds
        let B: CGFloat = 28, y0: CGFloat = 12
        closeBtn.frame = NSRect(x: w - 12 - B, y: y0, width: B, height: B)
        streamBtn.frame = NSRect(x: closeBtn.frame.minX - 8 - B, y: y0, width: B, height: B)
        liveBtn.frame = NSRect(x: streamBtn.frame.minX - 8 - B, y: y0, width: B, height: B)
        fwdBtn.frame = NSRect(x: liveBtn.frame.minX - 8 - B, y: y0, width: B, height: B)
        backBtn.frame = NSRect(x: fwdBtn.frame.minX - 8 - B, y: y0, width: B, height: B)
        let narrow = w < 420
        backBtn.isHidden = narrow; fwdBtn.isHidden = narrow; liveBtn.isHidden = narrow
        let right = narrow ? streamBtn.frame.minX : backBtn.frame.minX
        let tw = max(40, right - lead - 10)
        titleL.frame = NSRect(x: lead, y: 10, width: tw, height: 19)
        infoL.frame = NSRect(x: lead, y: 29, width: tw, height: 15)
        let maxW = max(80, min(w - 44, 440))
        toastL.preferredMaxLayoutWidth = maxW
        var s = toastL.intrinsicContentSize
        s.width = min(maxW, ceil(s.width)); s.height = ceil(s.height)
        toastBox.frame = NSRect(x: (w - s.width - 32) / 2, y: h - s.height - 96, width: s.width + 32, height: s.height + 20)
        toastL.frame = NSRect(x: 16, y: 10, width: s.width, height: s.height)
        toastBox.layer?.cornerRadius = min(14, toastBox.frame.height / 2)
        border.frame = bounds
        let gw = min(w - 40, 520), big: CGFloat = w < 500 ? 26 : 38
        goalL.font = .systemFont(ofSize: big, weight: .bold)
        goalL.preferredMaxLayoutWidth = gw - 32
        let gs = goalL.intrinsicContentSize
        goalBox.frame = NSRect(x: (w - gw) / 2, y: (h - gs.height - 36) / 2, width: gw, height: ceil(gs.height) + 36)
        goalL.frame = NSRect(x: 16, y: 18, width: gw - 32, height: ceil(gs.height))
    }

    func goal(_ head: String, _ detail: String) {
        let a = NSMutableAttributedString(string: "⚽︎ " + head + "\n", attributes: [.font: NSFont.systemFont(ofSize: bounds.width < 500 ? 24 : 34, weight: .bold), .foregroundColor: NSColor.white])
        a.append(NSAttributedString(string: detail, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: bounds.width < 500 ? 13 : 16, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.8)]))
        let p = NSMutableParagraphStyle(); p.alignment = .center
        a.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: a.length))
        goalL.attributedStringValue = a
        goalBox.isHidden = false
        goalBox.alphaValue = 1
        needsLayout = true
        goalTask?.cancel()
        goalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.goalBox.isHidden = true
        }
    }

    // hover bar
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { showBar() }
    override func mouseMoved(with event: NSEvent) { showBar() }
    override func mouseExited(with event: NSEvent) { hideBar(after: 0.4) }
    func showBar() {
        if bar.alphaValue < 1 { NSAnimationContext.runAnimationGroup { _ in bar.animator().alphaValue = 1 } }
        hideBar(after: 2.5)
    }
    func hideBar(after sec: Double) {
        barTask?.cancel()
        if ProcessInfo.processInfo.arguments.contains("--uitest") { return }
        barTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(sec * 1e9))
            guard let self, !Task.isCancelled else { return }
            self.bar.animator().alphaValue = 0
            if self.window?.styleMask.contains(.fullScreen) == true { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }

    func toast(_ s: String) {
        toastL.stringValue = s
        toastBox.isHidden = false
        needsLayout = true
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.toastBox.isHidden = true
        }
    }

    func updateChrome() {
        let multi = (area?.tiles.count ?? 1) > 1
        let t = match.title
        titleL.stringValue = t
        var parts = [(isActive && multi && !(area?.muteAll ?? false) ? "🔊 " : "") + (auto ? "Auto" : "Manuell")]
        if current >= 0 && current < streams.count {
            parts.append(streams[current].title)
            let h = current < heights.count ? heights[current] : 0
            parts.append(h > 0 ? "\(h)p" : "lädt…")
        } else {
            parts.append(listReady ? "kein Stream" : "suche Streams…")
        }
        infoL.stringValue = parts.joined(separator: " · ")
        border.layer?.borderWidth = isActive && multi ? 2 : 0
    }

    // MARK: stream control

    func open(_ m: Match) {
        killProbes()
        restUntil = 0; startFails = []; hangSwitches = []
        retryAt = [:]
        openedAt = nowMs()
        match = m
        Scores.shared.register([m])
        listReady = false; auto = true; current = -1; deadUrl = nil
        streams = []; failed = []; heights = []
        openToken += 1
        let token = openToken
        toast(m.title + "\nSuche Streams…")
        updateChrome()
        if let last = UD.string(forKey: "last:" + m.title) {
            streams = [StreamInfo(url: last, title: UD.string(forKey: "lastTitle:" + m.title) ?? "Letzter Stream", hd: true)]
            failed = [false]; heights = [0]
            play(0, "Letzter funktionierender Stream")
        } else {
            web.loadHTMLString("<body style='background:#000'></body>", baseURL: nil)
        }
        let t0 = nowMs()
        Task { @MainActor [weak self] in
            let rows = await fetchStreams(m, onFirst: { [weak self] part in
                await MainActor.run {
                    guard let self, self.openToken == token, !self.listReady, self.current < 0 else { return }
                    log("[\(m.title)] early start: \(part.count) streams after \(Int(nowMs() - t0))ms")
                    self.onStreamList(part)
                }
            })
            guard let self, self.openToken == token else { return }
            log("[\(m.title)] stream list: \(rows.count) streams after \(Int(nowMs() - t0))ms")
            self.onStreamList(rows)
        }
    }

    func onStreamList(_ rows: [StreamInfo]) {
        if rows.isEmpty {
            listReady = true
            if current < 0 { toast("Keine Streams gefunden") }
            updateChrome()
            return
        }
        let last = UD.string(forKey: "last:" + match.title)
        var rank: [Float] = []
        for (i, r) in rows.enumerated() {
            let src = srcOf(r.title)
            let sc = score(src)
            let hg = Float(UD.integer(forKey: "h:" + src))
            var v: Float = r.url == last ? 1000 : 0
            v += sc > 0 ? hg / 10 : 0
            v += sc * 5
            v += r.hd ? 3 : 0
            v -= Float(i) * 0.01
            rank.append(v)
        }
        let order = rows.indices.sorted { rank[$0] > rank[$1] }
        let curUrl = current >= 0 && current < streams.count ? streams[current].url : nil
        let curFailed = current >= 0 && current < failed.count && failed[current]
        let curH = current >= 0 && current < heights.count ? heights[current] : 0
        streams = order.map { rows[$0] }
        failed = Array(repeating: false, count: streams.count)
        heights = Array(repeating: 0, count: streams.count)
        var newCur = -1
        for (i, s) in streams.enumerated() {
            if s.url == curUrl { newCur = i; failed[i] = curFailed; heights[i] = curH }
            if s.url == deadUrl { failed[i] = true }
        }
        listReady = true
        if newCur >= 0 && !curFailed {
            current = newCur
            updateChrome()
        } else {
            current = -1
            let f = nextCandidate(from: -1)
            if f >= 0 { play(f, "Auto") }
        }
        maintainPool()
    }

    func play(_ i: Int, _ why: String) {
        guard i >= 0, i < streams.count, let url = URL(string: streams[i].url) else { return }
        current = i
        rewound = false
        started = false; userPaused = false; hardError = false; manifestSeen = false
        lastT = -1; freezeStart = 0; stalls = []; errCount = 0; lastPollAt = 0
        streamStart = nowMs(); lastProgressAt = streamStart
        homeHost = host(streams[i].url)
        log("[\(match.title)] play \(streams[i].title) (\(why)) \(streams[i].url)")
        toast(streams[i].title + "\n" + why)
        updateChrome()
        web.stopLoading()
        var r = URLRequest(url: url)
        r.setValue("https://streamed.pk/", forHTTPHeaderField: "Referer")
        web.load(r)
        Party.shared.local(self)
    }

    func playURL(_ url: String, title: String) {
        auto = false
        killProbes()
        if let i = streams.firstIndex(where: { $0.url == url }) { failed[i] = false; play(i, "Watch-Party") }
        else {
            streams.append(StreamInfo(url: url, title: title.isEmpty ? "Party-Stream" : title, hd: true))
            failed.append(false); heights.append(0)
            play(streams.count - 1, "Watch-Party")
        }
    }
    func setPaused(_ p: Bool) {
        userPaused = p
        web.evaluateJavaScript("(function(){var v=document.querySelector('.jw-media video')||document.querySelector('video');if(!v)return;window.__userPaused=\(p);if(\(p)){try{jwplayer().pause()}catch(e){v.pause()}}else{try{jwplayer().play()}catch(e){v.play()}}})()", completionHandler: nil)
        toast(p ? "⏸ Pause (Watch-Party)" : "▶ Weiter (Watch-Party)")
        log("[party] remote \(p ? "pause" : "play")")
    }
    func seekToBehind(_ b: Double) {
        rewound = b > 5
        web.evaluateJavaScript(seekBehindJS(b)) { [weak self] r, _ in
            guard let self else { return }
            self.lastT = -1; self.freezeStart = 0; self.lastProgressAt = nowMs()
            log("[party] seek result \(String(describing: r))")
        }
    }

    func nextCandidate(from: Int) -> Int {
        let n = streams.count
        if n == 0 { return -1 }
        for pass in 0..<2 {
            for k in 1...n {
                let i = ((from + k) % n + n) % n
                if i == from || failed[i] { continue }
                if pass == 0 && !streams[i].hd { continue }
                return i
            }
        }
        return -1
    }

    func fail(_ reason: String) {
        guard current >= 0, current < streams.count else { return }
        let src = srcOf(streams[current].title)
        UD.set(score(src) * 0.8 - 1, forKey: "score:" + src)
        if streams[current].url == UD.string(forKey: "last:" + match.title) { UD.removeObject(forKey: "last:" + match.title) }
        failed[current] = true
        log("[\(match.title)] fail \(streams[current].title): \(reason)")
        if !listReady {
            deadUrl = streams[current].url
            current = -1
            web.stopLoading()
            toast(reason + " – suche weiter…")
            updateChrome()
            return
        }
        retryAt[streams[current].url] = nowMs() + 12000
        if !started {
            let now = nowMs()
            startFails.append(now)
            startFails.removeAll { now - $0 > 180000 }
            if startFails.count >= max(4, streams.count * 2) && bestReady() == nil {
                // every stream failed repeatedly: probably over / not started yet. Stop burning CPU, retry quietly.
                startFails = []
                restUntil = now + 60000
                killProbes()
                web.stopLoading()
                web.loadHTMLString("<body style='background:#000'></body>", baseURL: nil)
                log("[\(match.title)] kein Stream erreichbar – Pause 60 s")
                toast("Gerade kein Stream erreichbar\nVielleicht vorbei oder noch nicht gestartet – neuer Versuch in 60 s")
                current = -1
                updateChrome()
                return
            }
        }
        if auto, let sb = bestReady() {
            adopt(sb, why: reason + " → sofort gewechselt")
            return
        }
        var n = nextCandidate(from: current)
        if n < 0 {
            for i in failed.indices { failed[i] = false }
            failed[current] = true
            n = nextCandidate(from: current)
            if n < 0 { failed[current] = false; n = current }
        }
        play(n, reason + " → nächster Stream")
    }

    func onStarted(_ h: Int) {
        started = true
        heights[current] = h
        let src = srcOf(streams[current].title)
        let bonus: Float = h >= 1080 ? 1 : (h >= 720 ? 0.5 : 0)
        UD.set(score(src) * 0.8 + 1 + bonus, forKey: "score:" + src)
        UD.set(h, forKey: "h:" + src)
        UD.set(streams[current].url, forKey: "last:" + match.title)
        UD.set(streams[current].title, forKey: "lastTitle:" + match.title)
        web.evaluateJavaScript("window.__started=true;", completionHandler: nil)
        log("[\(match.title)] started \(streams[current].title) \(h)p after \(Int(nowMs() - streamStart))ms")
        toast(streams[current].title + " · \(h)p")
        updateChrome()
        if ProcessInfo.processInfo.arguments.contains("--seektest") {
            for (t, d) in [(30.0, -10.0), (33.0, -10.0), (36.0, -30.0), (40.0, 10.0)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.seek(d) }
            }
        }
    }

    func poll() {
        if restUntil > 0 {
            if nowMs() < restUntil { return }
            restUntil = 0
            log("[\(match.title)] neuer Versuch nach Pause")
            open(match)
            return
        }
        maintainPool()
        if !probes.isEmpty { pollProbes() }
        guard current >= 0 else { return }
        let cur = current
        web.evaluateJavaScript("window.__mute=\(muted);" + MONITOR) { [weak self] r, _ in
            guard let self, self.current == cur, let s = r as? String, let d = s.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
            self.onStatus(o)
        }
    }

    func onStatus(_ o: [String: Any]) {
        let now = nowMs()
        func b(_ k: String) -> Bool { (o[k] as? NSNumber)?.boolValue ?? false }
        func d(_ k: String) -> Double { (o[k] as? NSNumber)?.doubleValue ?? 0 }
        let dt = lastPollAt == 0 ? 0 : min(now - lastPollAt, 3000)
        lastPollAt = now
        if b("m") && !manifestSeen {
            manifestSeen = true
            log("[\(match.title)] manifest after \(Int(now - streamStart))ms")
        }
        if b("ads") {
            streamStart += dt; lastProgressAt = now; freezeStart = 0; lastT = -1; errCount = 0
            return
        }
        if b("bad") { fail("Stream kaputt"); return }
        if b("err") { errCount += 1; if errCount >= 6 { fail("Stream-Fehler"); return } } else { errCount = 0 }
        let v = Int(d("v")), t = d("t"), h = Int(d("h"))
        if !started {
            let el = now - streamStart
            if hardError && now - hardErrorAt > 1500 && !manifestSeen { fail("Server offline"); return }
            if v == 1 {
                if lastT >= 0 && t > lastT + 0.05 && h > 0 { lastT = t; lastProgressAt = now; onStarted(h); return }
                lastT = t
            }
            if !manifestSeen && el > 12000 { fail("Keine Antwort"); return }
            if el > 25000 { fail("Startet nicht") }
            return
        }
        if v == 0 { return }
        if h > 0 && current < heights.count && h != heights[current] { heights[current] = h; updateChrome() }
        let progressing = lastT >= 0 && t > lastT + 0.05
        lastT = t
        if b("p") && userPaused { lastProgressAt = now; freezeStart = 0; return }
        if progressing {
            if freezeStart != 0 && now - freezeStart >= 3000 { stalls.append(now) }
            freezeStart = 0
            lastProgressAt = now
        } else {
            if freezeStart == 0 { freezeStart = lastProgressAt }
            if now - freezeStart >= 9000 { fail("Lag erkannt"); return }
        }
        stalls.removeAll { now - $0 > 90000 }
        if stalls.count >= 3 { fail("Ruckelt oft") }
    }

    func step(_ dir: Int) {
        guard !streams.isEmpty else { return }
        auto = false
        killProbes()
        let n = streams.count
        let i = (((current < 0 ? 0 : current) + dir) % n + n) % n
        failed[i] = false
        play(i, "Manuell gewählt")
    }
    func setAuto() {
        auto = true
        toast("Automatisch aktiv")
        if !started {
            let b = nextCandidate(from: -1)
            if b >= 0 && b != current { play(b, "Auto") }
        }
        maintainPool()
        updateChrome()
    }
    func reload() { restUntil = 0; if current >= 0 { play(current, "Neu geladen") } else { open(match) } }
    func seek(_ d: Double) {
        web.evaluateJavaScript(seekJS(d)) { [weak self] r, err in
            log("seek raw \(String(describing: r).prefix(400)) err \(String(describing: err))")
            guard let self, let str = r as? String, let data = str.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            let ok = (o["ok"] as? NSNumber)?.intValue ?? 0
            if ok == 0 { self.toast("Spulen geht bei diesem Stream nicht"); return }
            let behind = (o["behind"] as? NSNumber)?.intValue ?? 0
            let win = (o["win"] as? NSNumber)?.intValue ?? 0
            let clamped = (o["clamped"] as? NSNumber)?.intValue ?? 0
            self.lastT = -1; self.freezeStart = 0; self.lastProgressAt = nowMs()
            self.rewound = behind > 5
            log("[\(self.match.title)] seek \(Int(d))s -> \(behind)s hinter Live (Puffer \(win)s)")
            if clamped == 1 { self.toast("Weiter zurück geht nicht – Stream puffert nur \(win) s\n\(behind) s hinter Live") }
            else { self.toast(behind <= 3 ? "Live" : "\(behind) s hinter Live  ·  → vor · L = Live") }
            Party.shared.local(self)
        }
    }
    func goLive() { web.evaluateJavaScript(GO_LIVE, completionHandler: nil); userPaused = false; rewound = false; toast("Live"); Party.shared.local(self) }
    func togglePause() {
        web.evaluateJavaScript(PAUSE_JS) { [weak self] r, _ in
            guard let self else { return }
            self.userPaused = (r as? String) == "pause"
            self.toast(self.userPaused ? "Pause" : "Play"); Party.shared.local(self)
        }
    }
    func applyAudio() {
        web.evaluateJavaScript("window.__mute=\(muted);var v=document.querySelector('.jw-media video')||document.querySelector('video');if(v)v.muted=window.__mute;try{jwplayer().setMute(window.__mute)}catch(e){}", completionHandler: nil)
        updateChrome()
    }
    func shutdown() {
        killProbes()
        openToken += 1
        current = -1
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
    }

    // MARK: menu

    @objc func showMenu(_ sender: NSButton) {
        area?.setActive(self)
        let m = NSMenu()
        m.autoenablesItems = false
        let a = NSMenuItem(title: "Automatisch (beste Qualität, Wechsel bei Lag)", action: #selector(menuAuto), keyEquivalent: "")
        a.target = self; a.state = auto ? .on : .off
        m.addItem(a)
        m.addItem(.separator())
        if streams.isEmpty {
            let i = NSMenuItem(title: listReady ? "Keine Streams" : "Suche Streams…", action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
        }
        for (i, s) in streams.enumerated() {
            let hh = heights[i] > 0 ? heights[i] : UD.integer(forKey: "h:" + srcOf(s.title))
            let q = hh > 0 ? "\(hh)p" : (s.hd ? "HD" : "SD")
            let it = NSMenuItem(title: (failed[i] ? "✕ " : "") + s.title + "  ·  " + q, action: #selector(menuStream(_:)), keyEquivalent: "")
            it.target = self; it.tag = i; it.state = i == current ? .on : .off
            m.addItem(it)
        }
        m.addItem(.separator())
        for (t, sel) in [("10 s zurück", #selector(backTapped)), ("10 s vor", #selector(fwdTapped)), ("Vollbild (dieses Spiel)", #selector(menuSolo)), ("Zum Live-Punkt", #selector(menuLive)), ("Neu laden", #selector(menuReload)), ("Spiel schließen", #selector(closeTapped))] {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            it.target = self
            m.addItem(it)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
    @objc func menuAuto() { setAuto() }
    @objc func menuStream(_ i: NSMenuItem) { auto = false; killProbes(); failed[i.tag] = false; play(i.tag, "Manuell gewählt") }
    @objc func menuLive() { goLive() }
    @objc func menuSolo() { area?.toggleSolo(self) }
    @objc func backTapped() { area?.setActive(self); seek(-10) }
    @objc func fwdTapped() { area?.setActive(self); seek(10) }
    @objc func menuReload() { reload() }
    @objc func closeTapped() { area?.close(self) }

    // MARK: WebKit delegates

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let tf = navigationAction.targetFrame else { decisionHandler(.cancel); return }
        if !tf.isMainFrame { decisionHandler(.allow); return }
        let u = navigationAction.request.url
        if u?.scheme == "about" { decisionHandler(.allow); return }
        let h = host(u?.absoluteString ?? "")
        let hh = hostFor[ObjectIdentifier(webView)] ?? homeHost
        if hh.isEmpty || h == hh || h.hasSuffix("." + hh) { decisionHandler(.allow); return }
        log("[\(match.title)] blocked navigation to \(h)")
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === web else { probes.first { $0.web === webView }?.dead = true; return }
        let e = error as NSError
        let hard = [NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorSecureConnectionFailed,
                    NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorServerCertificateUntrusted]
        if e.domain == NSURLErrorDomain && hard.contains(e.code) {
            hardError = true
            hardErrorAt = nowMs()
            log("[\(match.title)] hard error \(e.code)")
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === web else { probes.first { $0.web === webView }?.dead = true; return }
        log("[\(match.title)] web process gone")
        if current >= 0 { play(current, "Neu geladen") }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil // popups never open
    }
}

// MARK: - Player area (multiview)

final class PlayerArea: FlippedView {
    var tiles: [Tile] = []
    weak var active: Tile?
    var focusMode = false { didSet { needsLayout = true } }
    var muteAll = false
    var onChange: (() -> Void)?
    var onSolo: ((Bool) -> Void)?
    var multi = UD.bool(forKey: "multi") {
        didSet {
            UD.set(multi, forKey: "multi")
            if !multi, let a = active ?? tiles.last {
                for t in tiles where t !== a { close(t) }
                focusMode = false
            }
            changed()
        }
    }
    weak var solo: Tile? { didSet { for t in tiles { t.isHidden = solo != nil && t !== solo }; needsLayout = true } }
    func toggleSolo(_ t: Tile?) {
        if solo != nil { solo = nil } else if let t { setActive(t); solo = t }
        onSolo?(solo != nil)
    }
    let emptyL = NSTextField(wrappingLabelWithString: "Doppelklick auf ein Spiel, um es zu starten.\nMehrere Spiele gleichzeitig: Multistream oben in der Seitenleiste einschalten.")
    let emptyTitle = makeLabel(20, bold: true, color: NSColor(white: 1, alpha: 0.85))
    let emptyIcon = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        emptyL.alignment = .center
        emptyL.textColor = NSColor(white: 1, alpha: 0.5)
        emptyL.font = .systemFont(ofSize: 13)
        emptyTitle.stringValue = "Kein Spiel geöffnet"
        emptyTitle.alignment = .center
        emptyIcon.image = sym("sportscourt", 54, .light)
        emptyIcon.contentTintColor = NSColor(white: 1, alpha: 0.35)
        addSubview(emptyIcon); addSubview(emptyTitle); addSubview(emptyL)
    }
    required init?(coder: NSCoder) { fatalError() }

    func add(_ m: Match, replace: Bool) {
        if let t = tiles.first(where: { $0.match.id == m.id }) { setActive(t); t.toast("Läuft schon"); return }
        if let a = active, replace || !multi || tiles.count >= MAX_TILES {
            a.open(m)
            if !replace { a.toast("Max. \(MAX_TILES) Spiele – aktive Kachel ersetzt") }
            changed()
            return
        }
        let t = Tile(match: m, area: self)
        tiles.append(t)
        addSubview(t)
        setActive(t)
        t.open(m)
        changed()
    }

    func close(_ t: Tile) {
        if solo === t { solo = nil; onSolo?(false) }
        t.shutdown()
        t.removeFromSuperview()
        tiles.removeAll { $0 === t }
        if active === t || active == nil { setActive(tiles.last) }
        if tiles.count < 2 { focusMode = false }
        changed()
    }

    func setActive(_ t: Tile?) {
        let changed = active !== t
        active = t
        if changed, let t { Party.shared.local(t) }
        for x in tiles { x.isActive = x === t; x.applyAudio() }
        if focusMode { needsLayout = true }
    }

    func applyAudio() { for x in tiles { x.applyAudio() } }

    func changed() {
        emptyL.isHidden = !tiles.isEmpty; emptyTitle.isHidden = !tiles.isEmpty; emptyIcon.isHidden = !tiles.isEmpty
        for t in tiles { t.updateChrome() }
        needsLayout = true
        onChange?()
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height, n = tiles.count, gap: CGFloat = 2
        emptyIcon.frame = NSRect(x: W / 2 - 40, y: H / 2 - 96, width: 80, height: 64)
        emptyTitle.frame = NSRect(x: 40, y: H / 2 - 20, width: max(0, W - 80), height: 26)
        emptyL.frame = NSRect(x: 40, y: H / 2 + 14, width: max(0, W - 80), height: 40)
        guard n > 0 else { return }
        if let s = solo { s.frame = bounds; return }
        if focusMode && n > 1, let a = active {
            let others = tiles.filter { $0 !== a }
            let sideW = max(220, W * 0.24)
            a.frame = NSRect(x: 0, y: 0, width: W - sideW - gap, height: H)
            let th = min(H / CGFloat(others.count), sideW * 9 / 16 + 6)
            var y = (H - th * CGFloat(others.count)) / 2
            for o in others {
                o.frame = NSRect(x: W - sideW, y: y, width: sideW, height: th - gap)
                y += th
            }
        } else {
            let cols = n == 1 ? 1 : (n <= 4 ? 2 : 3)
            let rows = Int(ceil(Double(n) / Double(cols)))
            let cw = (W - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let ch = (H - gap * CGFloat(rows - 1)) / CGFloat(rows)
            for (i, t) in tiles.enumerated() {
                let r = i / cols, c = i % cols
                let inRow = r == rows - 1 ? n - r * cols : cols
                var x = CGFloat(c) * (cw + gap)
                if inRow < cols { x += CGFloat(cols - inRow) * (cw + gap) / 2 }
                t.frame = NSRect(x: x, y: CGFloat(r) * (ch + gap), width: cw, height: ch)
            }
        }
    }
}

// MARK: - Sidebar (match list)

final class MatchTable: NSTableView {
    var onEnter: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onEnter?() } else { super.keyDown(with: event) }
    }
}

final class MatchCell: NSTableCellView {
    let t = makeLabel(13, bold: true, color: .labelColor), s = makeLabel(11, color: .secondaryLabelColor), r = makeLabel(11, color: .secondaryLabelColor)
    let icon = NSImageView()
    let iconBG = NSView()
    let b1 = NSImageView(), b2 = NSImageView()
    let live = NSTextField(labelWithString: "LIVE")
    override var isFlipped: Bool { true }
    init(_ id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        r.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        r.alignment = .right
        iconBG.wantsLayer = true
        iconBG.layer?.cornerRadius = 8
        icon.imageScaling = .scaleProportionallyDown
        live.font = .systemFont(ofSize: 9, weight: .heavy)
        live.textColor = .white
        live.alignment = .center
        live.wantsLayer = true
        live.drawsBackground = true
        live.backgroundColor = .systemRed
        live.layer?.cornerRadius = 4
        live.layer?.masksToBounds = true
        for b in [b1, b2] { b.imageScaling = .scaleProportionallyUpOrDown; b.wantsLayer = true; b.shadow = { let x = NSShadow(); x.shadowColor = NSColor(white: 0, alpha: 0.5); x.shadowBlurRadius = 2; return x }() }
        addSubview(iconBG); addSubview(icon); addSubview(b1); addSubview(b2); addSubview(t); addSubview(s); addSubview(r); addSubview(live)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        iconBG.frame = NSRect(x: 6, y: (H - 32) / 2, width: 32, height: 32)
        icon.frame = iconBG.frame.insetBy(dx: 7, dy: 7)
        let o = iconBG.frame.origin
        b1.frame = NSRect(x: o.x + 1, y: o.y + 1, width: 19, height: 19)
        b2.frame = NSRect(x: o.x + 12, y: o.y + 12, width: 19, height: 19)
        r.sizeToFit()
        let rw = min(110, r.frame.width)
        let lw: CGFloat = live.isHidden ? 0 : 34
        r.frame = NSRect(x: W - rw - 8, y: H / 2 - 1, width: rw, height: 15)
        live.frame = NSRect(x: W - lw - 8, y: H / 2 - 17, width: lw, height: 14)
        let tx: CGFloat = 48
        t.frame = NSRect(x: tx, y: H / 2 - 18, width: W - tx - max(rw, lw) - 16, height: 18)
        s.frame = NSRect(x: tx, y: H / 2 + 1, width: W - tx - max(rw, lw) - 16, height: 15)
    }
    static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    func set(_ m: Match, open: Bool) {
        t.stringValue = m.title
        t.textColor = .labelColor
        s.stringValue = catName(m.category) + (m.popular ? " · Beliebt" : "")
        icon.image = sym(open ? "play.fill" : sportSymbol(m.category), 15, .semibold) ?? sym("sportscourt.fill", 15)
        icon.contentTintColor = open ? .white : .secondaryLabelColor
        var badges = false
        if !open, let i1 = Badges.get(m.homeBadge), let i2 = Badges.get(m.awayBadge) { b1.image = i1; b2.image = i2; badges = true }
        b1.isHidden = !badges; b2.isHidden = !badges; icon.isHidden = badges
        iconBG.layer?.backgroundColor = (open ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).cgColor
        let time = MatchCell.fmt.string(from: Date(timeIntervalSince1970: Double(m.date) / 1000))
        live.isHidden = !(m.isLive && !m.is247)
        r.stringValue = m.is247 ? "24/7" : time
        r.textColor = .secondaryLabelColor
        if !open, let sc = Scores.shared.score(m) {
            r.stringValue = "\(sc.h):\(sc.a) · \(sc.clock)"
            r.textColor = sc.state == "in" ? .labelColor : .secondaryLabelColor
        }
        needsLayout = true
    }
}

final class Sidebar: FlippedView, NSTableViewDataSource, NSTableViewDelegate {
    let fx = NSVisualEffectView()
    let sep = NSBox()
    let partyCard = NSView()
    let partyIcon = NSImageView()
    let keysBtn = NSButton()
    let keysPop = NSPopover()
    @objc func showKeys(_ b: NSButton) {
        let l = NSTextField(wrappingLabelWithString: hint.stringValue)
        l.font = .systemFont(ofSize: 12)
        l.preferredMaxLayoutWidth = 320
        let vc = NSViewController()
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 352, height: ceil(l.intrinsicContentSize.height) + 28))
        l.frame = NSRect(x: 16, y: 14, width: 320, height: ceil(l.intrinsicContentSize.height))
        v.addSubview(l)
        vc.view = v
        keysPop.contentViewController = vc
        keysPop.behavior = .transient
        keysPop.show(relativeTo: b.bounds, of: b, preferredEdge: .maxY)
    }
    var all: [Match] = [], shown: [Match] = []
    let tabs = NSSegmentedControl(labels: ["Live", "Fußball", "Heute"], trackingMode: .selectOne, target: nil, action: nil)
    let search = NSSearchField()
    let table = MatchTable()
    let scroll = NSScrollView()
    let logo = makeLabel(22, bold: true)
    let header = makeLabel(11, color: C_MUTED)
    let hint = NSTextField(wrappingLabelWithString: "")
    var onOpen: ((Match, Bool) -> Void)?
    var onForceNew: ((Match) -> Void)?
    let partyTitle = makeLabel(12, bold: true)
    let partyStatus = NSTextField(wrappingLabelWithString: "")
    let partyStart = NSButton(title: "Party starten", target: nil, action: nil)
    let partyJoin = NSButton(title: "Beitreten…", target: nil, action: nil)
    let partyCopy = NSButton(title: "Code kopieren", target: nil, action: nil)
    let partyLeave = NSButton(title: "Verlassen", target: nil, action: nil)
    let chatField = NSTextField()
    let emojiBtns: [NSButton] = ["⚽", "😂", "😡", "🔥", "👀"].map { NSButton(title: $0, target: nil, action: nil) }
    var onPartyStart: (() -> Void)?, onPartyJoin: (() -> Void)?, onPartyLeave: (() -> Void)?, onPartyCopy: (() -> Void)?
    @objc func pStart() { onPartyStart?() }
    @objc func pJoin() { onPartyJoin?() }
    @objc func pLeave() { onPartyLeave?() }
    @objc func pCopy() { onPartyCopy?() }
    @objc func pChat() { Party.shared.chat(chatField.stringValue); chatField.stringValue = "" }
    @objc func pEmoji(_ b: NSButton) { Party.shared.chat(b.title) }
    func updateParty() {
        let on = Party.shared.active
        partyTitle.stringValue = "Watch-Party"
        partyTitle.textColor = .labelColor
        partyIcon.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
        partyStatus.stringValue = Party.shared.status
        for v in [partyStart, partyJoin] as [NSView] { v.isHidden = on }
        for v in [partyCopy, partyLeave, chatField] as [NSView] { v.isHidden = !on }
        emojiBtns.forEach { $0.isHidden = !on }
        needsLayout = true
    }
    var onMulti: ((Bool) -> Void)?
    let multiBtn = NSButton(title: "", target: nil, action: nil)
    func setMulti(_ on: Bool) {
        multiBtn.state = on ? .on : .off
        multiBtn.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
        multiBtn.image = sym(on ? "square.grid.2x2.fill" : "square.grid.2x2", 15, .regular)
        hint.stringValue = (on ? "Multistream AN: Doppelklick / ↩ = neue Kachel  ·  ⌥ = aktive ersetzen\nKlick auf Kachel = Ton  ·  G Raster/Fokus  ·  1–6 Kachel\n" : "Doppelklick / ↩ = Spiel öffnen (ersetzt das laufende)\nRechtsklick = als zusätzliche Kachel (Multistream)\n") + "Doppelklick / F = Vollbild · Esc raus · S Liste\n← → 10 s spulen · L Live · [ ] Stream · A Auto · M Ton · ␣ Pause"
    }
    @objc func multiTapped() { onMulti?(multiBtn.state == .on) }
    var isOpen: ((String) -> Bool)?
    var loadToken = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        fx.material = .sidebar
        fx.blendingMode = .behindWindow
        fx.state = .followsWindowActiveState
        addSubview(fx)
        sep.boxType = .separator
        addSubview(sep)
        logo.stringValue = "Streamed"
        logo.font = .systemFont(ofSize: 22, weight: .bold)
        logo.textColor = .labelColor
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .tertiaryLabelColor
        partyCard.wantsLayer = true
        partyCard.layer?.cornerRadius = 12
        partyCard.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        partyCard.layer?.borderWidth = 0.5
        partyCard.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        addSubview(partyCard)
        partyIcon.image = sym("person.2.fill", 13, .semibold)
        addSubview(partyIcon)
        keysBtn.isBordered = false
        keysBtn.image = sym("keyboard", 13, .regular)
        keysBtn.imagePosition = .imageLeading
        keysBtn.imageHugsTitle = true
        keysBtn.attributedTitle = NSAttributedString(string: " Tastenkürzel", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        keysBtn.contentTintColor = .secondaryLabelColor
        keysBtn.target = self
        keysBtn.action = #selector(showKeys(_:))
        addSubview(keysBtn)
        tabs.selectedSegment = 0
        tabs.segmentDistribution = .fillEqually
        tabs.target = self
        tabs.action = #selector(tabChanged)
        search.placeholderString = "Spiel oder Sport suchen…"
        search.target = self
        search.action = #selector(filterChanged)
        search.sendsSearchStringImmediately = true
        let col = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 50
        table.style = .sourceList
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(dbl)
        table.onEnter = { [weak self] in self?.openSelected(replace: NSEvent.modifierFlags.contains(.option)) }
        let menu = NSMenu()
        menu.addItem(withTitle: "Als zusätzliche Kachel öffnen (Multistream)", action: #selector(ctxNew), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Öffnen (ersetzt aktive Kachel)", action: #selector(ctxReplace), keyEquivalent: "").target = self
        table.menu = menu
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        hint.stringValue = "Doppelklick / ↩ = neue Kachel  ·  ⌥ = aktive ersetzen\nKlick auf Kachel = Ton  ·  Doppelklick / F = Vollbild\n1–6 Kachel · G Raster/Fokus · S Liste · Esc raus\n←→ Stream · A Auto · M Ton · L Live · R Reload · ␣ Pause"
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = C_MUTED
        partyStatus.font = .systemFont(ofSize: 11)
        partyStatus.textColor = .secondaryLabelColor
        partyStatus.maximumNumberOfLines = 3
        for (b, sel) in [(partyStart, #selector(pStart)), (partyJoin, #selector(pJoin)), (partyCopy, #selector(pCopy)), (partyLeave, #selector(pLeave))] {
            b.bezelStyle = .rounded; b.controlSize = .regular; b.font = .systemFont(ofSize: 12); b.target = self; b.action = sel
        }
        chatField.placeholderString = "Nachricht an die Party… (↩)"
        chatField.font = .systemFont(ofSize: 12)
        chatField.target = self
        chatField.action = #selector(pChat)
        partyStart.keyEquivalent = ""
        partyStart.bezelColor = .controlAccentColor
        chatField.bezelStyle = .roundedBezel
        for b in emojiBtns { b.isBordered = false; b.font = .systemFont(ofSize: 17); b.target = self; b.action = #selector(pEmoji(_:)); b.wantsLayer = true; b.layer?.cornerRadius = 8; b.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor }
        multiBtn.setButtonType(.pushOnPushOff)
        multiBtn.isBordered = false
        multiBtn.imagePosition = .imageOnly
        multiBtn.target = self
        multiBtn.action = #selector(multiTapped)
        multiBtn.toolTip = "Multistream: mehrere Spiele gleichzeitig (⇧⌘N)"
        for v in [logo, multiBtn, tabs, search, header, scroll, partyTitle, partyStatus, partyStart, partyJoin, partyCopy, partyLeave, chatField] as [NSView] { addSubview(v) }
        emojiBtns.forEach { addSubview($0) }
        updateParty()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height, P: CGFloat = 16
        fx.frame = bounds
        sep.frame = NSRect(x: W - 1, y: 0, width: 1, height: H)
        let cw = W - 1   // content width without the separator
        multiBtn.frame = NSRect(x: cw - P - 28, y: 9, width: 28, height: 24)   // in the title bar, next to the traffic lights
        logo.frame = NSRect(x: P, y: 44, width: cw - 2 * P, height: 30)
        tabs.frame = NSRect(x: P, y: 82, width: cw - 2 * P, height: 24)
        search.frame = NSRect(x: P, y: 116, width: cw - 2 * P, height: 26)
        header.frame = NSRect(x: P + 2, y: 152, width: cw - 2 * P, height: 15)
        let on = Party.shared.active
        let keysH: CGFloat = 30
        let partyH: CGFloat = on ? 172 : 104
        let py = H - keysH - 10 - partyH
        partyCard.frame = NSRect(x: 10, y: py, width: cw - 20, height: partyH)
        let ix = partyCard.frame.minX + 12, iw = partyCard.frame.width - 24
        partyIcon.frame = NSRect(x: ix, y: py + 12, width: 18, height: 16)
        partyTitle.frame = NSRect(x: ix + 24, y: py + 11, width: iw - 24, height: 18)
        partyStatus.frame = NSRect(x: ix, y: py + 34, width: iw, height: on ? 44 : 30)
        let by = py + (on ? 82 : 68)
        let bw = (iw - 8) / 2
        partyStart.frame = NSRect(x: ix - 2, y: by, width: bw + 4, height: 28)
        partyJoin.frame = NSRect(x: ix + bw + 6, y: by, width: bw + 4, height: 28)
        partyCopy.frame = partyStart.frame
        partyLeave.frame = partyJoin.frame
        chatField.frame = NSRect(x: ix, y: by + 34, width: iw, height: 24)
        let ew = (iw - 4 * 6) / 5
        for (i, b) in emojiBtns.enumerated() { b.frame = NSRect(x: ix + CGFloat(i) * (ew + 6), y: by + 64, width: ew, height: 28) }
        scroll.frame = NSRect(x: 0, y: 172, width: cw, height: max(0, py - 172 - 8))
        keysBtn.frame = NSRect(x: P - 2, y: H - keysH - 4, width: 120, height: keysH)
        table.tableColumns.first?.width = max(50, scroll.contentSize.width - 28)
    }

    @objc func tabChanged() { all = []; shown = []; table.reloadData(); load() }
    @objc func filterChanged() { applyFilter() }

    func load() {
        loadToken += 1
        let token = loadToken
        let tab = max(0, tabs.selectedSegment)
        let path = ["/matches/live", "/matches/football", "/matches/all-today"][tab]
        if all.isEmpty { header.stringValue = "LADE SPIELE…" }
        Task { @MainActor [weak self] in
            let arr = await getJSON(path) as? [[String: Any]]
            guard let self, token == self.loadToken else { return }
            guard let arr else { self.header.stringValue = "FEHLER BEIM LADEN – INTERNET?"; return }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            var ms = arr.compactMap { Match($0) }
            if tab != 0 { ms = ms.filter { $0.is247 || $0.date > now - 4 * 3_600_000 } }
            var seen = Set<String>()
            ms = ms.filter { seen.insert($0.id).inserted }
            ms.sort { a, b in
                let fa = a.category == "football" ? 0 : 1, fb = b.category == "football" ? 0 : 1
                if fa != fb { return fa < fb }
                let pa = a.popular ? 0 : 1, pb = b.popular ? 0 : 1
                if pa != pb { return pa < pb }
                return a.date < b.date
            }
            self.all = ms
            Scores.shared.register(ms)
            self.applyFilter()
        }
    }

    func applyFilter() {
        let sel = table.selectedRow >= 0 && table.selectedRow < shown.count ? shown[table.selectedRow].id : nil
        let q = search.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        shown = q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) || catName($0.category).lowercased().contains(q) }
        table.reloadData()
        if let sel, let i = shown.firstIndex(where: { $0.id == sel }) { table.selectRowIndexes([i], byExtendingSelection: false) }
        header.stringValue = shown.isEmpty ? "GERADE KEINE SPIELE" : "\(shown.count) SPIELE"
    }

    func refreshMarks() {
        let sel = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(sel, byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let v = (tableView.makeView(withIdentifier: id, owner: nil) as? MatchCell) ?? MatchCell(id)
        let m = shown[row]
        v.set(m, open: isOpen?(m.id) ?? false)
        return v
    }

    @objc func dbl() {
        let r = table.clickedRow
        guard r >= 0, r < shown.count else { return }
        onOpen?(shown[r], NSEvent.modifierFlags.contains(.option))
    }
    func openSelected(replace: Bool) {
        let r = table.selectedRow
        guard r >= 0, r < shown.count else { return }
        onOpen?(shown[r], replace)
    }
    @objc func ctxNew() { let r = table.clickedRow; if r >= 0 && r < shown.count { onForceNew?(shown[r]) } }
    @objc func ctxReplace() { let r = table.clickedRow; if r >= 0 && r < shown.count { onOpen?(shown[r], true) } }
}

// MARK: - Window / app

final class RootView: FlippedView {
    let sidebar = Sidebar(frame: .zero)
    let area = PlayerArea(frame: .zero)
    var sidebarVisible = true { didSet { sidebar.isHidden = !sidebarVisible; needsLayout = true; area.needsLayout = true; area.tiles.forEach { $0.needsLayout = true } } }
    let sideBtn = NSButton()
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(area)
        addSubview(sidebar)
        sideBtn.isBordered = false
        sideBtn.image = sym("sidebar.left", 15, .regular)
        sideBtn.imagePosition = .imageOnly
        sideBtn.contentTintColor = .secondaryLabelColor
        sideBtn.toolTip = "Seitenleiste ein/aus (S)"
        sideBtn.target = nil
        sideBtn.action = #selector(AppDelegate.toggleSidebar)
        addSubview(sideBtn)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let sw: CGFloat = sidebarVisible ? 330 : 0
        sidebar.frame = NSRect(x: 0, y: 0, width: sw, height: bounds.height)
        area.frame = NSRect(x: sw, y: 0, width: bounds.width - sw, height: bounds.height)
        sideBtn.frame = NSRect(x: 80, y: 9, width: 28, height: 24)
        sideBtn.isHidden = window?.styleMask.contains(.fullScreen) ?? false
        sideBtn.contentTintColor = sidebarVisible ? .secondaryLabelColor : .white
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var win: NSWindow!
    var root: RootView!
    var activity: NSObjectProtocol?
    var sidebarBeforeFS = true
    var timers: [Timer] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        rotateLog()
        log("launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        buildMenu()
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "streamed-adblock-v4", encodedContentRuleList: adRulesJSON()) { list, err in
            MainActor.assumeIsolated {
                if let err { log("rules error: \(err)") } else { log("adblock rules ready") }
                ruleList = list
                self.setup()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { Updater.shared.runPending(relaunch: false) }
    @objc func checkUpdates() { Updater.shared.check(manual: true, canRestartNow: { [weak self] in self?.root.area.tiles.isEmpty ?? true }) }

    func setup() {
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 860), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        win.title = "Streamed"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.appearance = NSAppearance(named: .darkAqua)
        win.minSize = NSSize(width: 820, height: 480)
        win.collectionBehavior = [.fullScreenPrimary]
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false
        root = RootView(frame: win.contentView!.bounds)
        win.contentView = root
        win.delegate = self
        if BG { win.setFrame(NSRect(x: 40, y: 40, width: 960, height: 560), display: false) } else {
            if !win.setFrameUsingName("StreamedMain") { win.center() }
            win.setFrameAutosaveName("StreamedMain")
        }
        root.sidebar.onOpen = { [weak self] m, rep in self?.root.area.add(m, replace: rep) }
        root.sidebar.onForceNew = { [weak self] m in
            guard let self else { return }
            if !self.root.area.multi { self.setMulti(true) }
            self.root.area.add(m, replace: false)
        }
        root.sidebar.onMulti = { [weak self] on in self?.setMulti(on) }
        root.sidebar.setMulti(root.area.multi)
        root.sidebar.isOpen = { [weak self] id in self?.root.area.tiles.contains { $0.match.id == id } ?? false }
        root.area.onChange = { [weak self] in self?.areaChanged() }
        root.area.onSolo = { [weak self] on in
            guard let self else { return }
            if on != self.win.styleMask.contains(.fullScreen) { self.win.toggleFullScreen(nil) }
        }
        if BG { root.area.muteAll = true; win.title = "Streamed (Test)"; win.orderBack(nil) } else {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        Badges.onLoad = { [weak self] in self?.root.sidebar.refreshMarks() }
        root.sidebar.load()
        log("window \(win.windowNumber)")
        win.makeFirstResponder(root.sidebar.table)
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.root.area.tiles.forEach { $0.poll() } }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.root.sidebar.load() }
        })
        installMonitors()
        installRecovery()
        Scores.shared.onChange = { [weak self] in
            guard let self else { return }
            self.root.sidebar.refreshMarks()
            self.root.area.tiles.forEach { $0.updateChrome() }
        }
        Scores.shared.onGoal = { [weak self] mid, head, detail in
            guard let self else { return }
            log("goal: \(head) \(detail)")
            if self.root.area.tiles.contains(where: { $0.match.id == mid }) { return }   // no spoilers for games you watch
            self.root.area.active?.toast("⚽ " + head + "\n" + detail)
            if !NSApp.isActive { notifyGoal(head, detail) }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, err in log("notifications allowed: \(ok) \(String(describing: err))") }
        Scores.shared.start()
        Updater.shared.onStatus = { [weak self] msg in
            log("[update] " + msg)
            guard let self else { return }
            if let t = self.root.area.active { t.toast(msg) } else { self.root.sidebar.header.stringValue = msg }
        }
        if !BG { Updater.shared.check(manual: false, canRestartNow: { [weak self] in self?.root.area.tiles.isEmpty ?? true }) }
        Party.shared.area = root.area
        Party.shared.onUI = { [weak self] in self?.root.sidebar.updateParty() }
        root.sidebar.onPartyStart = { [weak self] in self?.partyStart() }
        root.sidebar.onPartyJoin = { [weak self] in self?.partyJoin() }
        root.sidebar.onPartyLeave = { Party.shared.leave() }
        root.sidebar.onPartyCopy = { [weak self] in if let c = Party.shared.code { self?.copyCode(c) } }
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--party-host"), i + 1 < ProcessInfo.processInfo.arguments.count { Party.shared.start(host: true, code: ProcessInfo.processInfo.arguments[i + 1]) }
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--party-join"), i + 1 < ProcessInfo.processInfo.arguments.count { Party.shared.start(host: false, code: ProcessInfo.processInfo.arguments[i + 1]) }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--failtest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in log("[test] force fail"); self?.root.area.active?.fail("Test-Ausfall") }
        }
        if args.contains("--partytest") {
            let a = self.root.area
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { Party.shared.chat("Test 😂") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 24) { log("[test] host pause"); a.active?.togglePause() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { log("[test] host play"); a.active?.togglePause() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 36) { log("[test] host seek -20"); a.active?.seek(-20) }
        }
        if args.contains("--uitest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
                guard let t = self?.root.area.tiles.first else { return }
                t.toast("Hotel 1 · Main · 1080p\nBessere Qualität gefunden")
                t.goal("TOR! \(t.match.home)", "\(t.match.home) 1:0 \(t.match.away)  ·  23'")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 16) { [weak self] in self?.toggleSidebar() }
        }
        if args.contains("--goaltest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, let t = self.root.area.tiles.first else { return }
                Scores.shared.onGoal?(t.match.id, "TOR! \(t.match.home)", "\(t.match.home) 1:0 \(t.match.away)  ·  Test")
            }
        }
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count, let n = Int(args[i + 1]) { autoOpen(n) }
    }

    func setMulti(_ on: Bool) {
        root.area.multi = on
        root.sidebar.setMulti(on)
        root.area.active?.toast(on ? "Multistream an – neue Spiele kommen als eigene Kachel dazu" : "Multistream aus")
    }
    @objc func toggleMulti() { setMulti(!root.area.multi) }
    func copyCode(_ c: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c, forType: .string)
        root.area.active?.toast("Party-Code \(c) kopiert")
    }
    @objc func partyStart() {
        let c = Party.newCode()
        Party.shared.start(host: true, code: c)
        copyCode(c)
        let a = NSAlert()
        a.messageText = "Watch-Party gestartet"
        a.informativeText = "Schick deinem Freund diesen Code (ist schon kopiert):\n\n\(c)\n\nEr klickt in Streamed auf „Beitreten…“ und gibt ihn ein. Danach gelten Spiel, Stream, Pause und Spulen für euch beide."
        a.addButton(withTitle: "OK")
        a.runModal()
    }
    @objc func partyJoin() {
        let a = NSAlert()
        a.messageText = "Watch-Party beitreten"
        a.informativeText = "Code von deinem Freund eingeben (z.B. kx7m-3pqa):"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "Beitreten")
        a.addButton(withTitle: "Abbrechen")
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn {
            let c = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !c.isEmpty { Party.shared.start(host: false, code: c) }
        }
    }
    var spoilerMenu: NSMenu?
    func updateSpoilerMenu() { spoilerMenu?.items.forEach { $0.state = Double($0.tag) == Scores.shared.delay ? .on : .off } }
    @objc func setSpoiler(_ i: NSMenuItem) {
        Scores.shared.setDelay(Double(i.tag)); updateSpoilerMenu()
        root.area.active?.toast(i.tag == 0 ? "Spoiler-Schutz aus" : "Spielstand und Tore kommen \(i.tag) s verzögert")
    }

    func autoOpen(_ n: Int) {
        if n > 1 { setMulti(true) }
        Task {
            guard let arr = await getJSON("/matches/live") as? [[String: Any]] else { return }
            var ms = arr.compactMap { Match($0) }.filter { !$0.is247 }.sorted {
                ($0.category == "football" ? 0 : 1, $0.popular ? 0 : 1) < ($1.category == "football" ? 0 : 1, $1.popular ? 0 : 1)
            }
            let av = ProcessInfo.processInfo.arguments
            if let j = av.firstIndex(of: "--match"), j + 1 < av.count { let q = av[j + 1].lowercased(); ms = ms.filter { $0.title.lowercased().contains(q) } }
            for m in ms.prefix(n) { root.area.add(m, replace: false) }
        }
    }

    func areaChanged() {
        let n = root.area.tiles.count
        if n > 0 && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Streams laufen")
        } else if n == 0, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        win.subtitle = n == 0 ? "" : "\(n) Spiel\(n == 1 ? "" : "e")"
        root.sidebar.refreshMarks()
    }

    var netMon: NWPathMonitor?
    var netWasDown = false
    func installRecovery() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                log("wake from sleep – reload")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { self?.recover(all: true) } }
            }
        }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if path.status != .satisfied { if !self.netWasDown { log("network down") }; self.netWasDown = true; return }
                    if self.netWasDown {
                        self.netWasDown = false
                        log("network back – reload")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { self.recover(all: false) } }
                    }
                }
            }
        }
        m.start(queue: DispatchQueue(label: "streamed.net"))
        netMon = m
    }
    /// After sleep or a network drop: refresh the list and restart streams that are stuck.
    func recover(all: Bool) {
        root.sidebar.load()
        for t in root.area.tiles where all || !t.started || t.freezeStart != 0 || t.current < 0 {
            t.retryAt = [:]
            t.reload()
        }
    }

    func installMonitors() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let handled = MainActor.assumeIsolated { self?.handleKey(e) ?? false }
            return handled ? nil : e
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            let consume = MainActor.assumeIsolated { self?.handleClick(e) ?? false }
            return consume ? nil : e
        }
    }

    func handleKey(_ e: NSEvent) -> Bool {
        guard e.window === win else { return false }
        if let tv = win.firstResponder as? NSTextView, tv.isFieldEditor {
            if e.keyCode == 53 { win.makeFirstResponder(root.sidebar.table); return true }
            return false
        }
        if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        let area = root.area
        let a = area.active
        switch e.keyCode {
        case 123: a?.seek(-10); return a != nil
        case 124: a?.seek(10); return a != nil
        case 49: a?.togglePause(); return a != nil
        case 53:
            if root.area.solo != nil { root.area.toggleSolo(nil); return true }
            if win.styleMask.contains(.fullScreen) { win.toggleFullScreen(nil); return true }
            return false
        default: break
        }
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if let d = Int(ch), d >= 1, d <= area.tiles.count { area.setActive(area.tiles[d - 1]); return true }
        switch ch {
        case "g": toggleLayout()
        case "f": if area.tiles.isEmpty { win.toggleFullScreen(nil) } else { area.toggleSolo(area.active) }
        case "s": toggleSidebar()
        case "m": toggleMute()
        case "[": a?.step(-1)
        case "]": a?.step(1)
        case "a": a?.setAuto()
        case "r": a?.reload()
        case "l": a?.goLive()
        default: return false
        }
        return true
    }

    /// Click on a tile selects it (audio follows). Clicks on inactive tiles are swallowed so the player doesn't pause.
    func handleClick(_ e: NSEvent) -> Bool {
        guard e.window === win else { return false }
        let area = root.area
        let p = area.convert(e.locationInWindow, from: nil)
        guard let t = area.tiles.first(where: { $0.frame.contains(p) }) else { return false }
        let lp = t.convert(e.locationInWindow, from: nil)
        let onBar = lp.y <= 40 && t.bar.alphaValue > 0.5
        if area.active !== t {
            area.setActive(t)
            return !onBar
        }
        if e.clickCount == 2 && !onBar { area.toggleSolo(t); return true }
        return false
    }

    @objc func toggleLayout() {
        let area = root.area
        guard area.tiles.count > 1 else { area.active?.toast("Erst Multistream einschalten und ein 2. Spiel öffnen"); return }
        area.focusMode.toggle()
        area.active?.toast(area.focusMode ? "Fokus-Ansicht" : "Raster-Ansicht")
    }
    @objc func toggleSidebar() { root.sidebarVisible.toggle() }
    @objc func toggleMute() {
        root.area.muteAll.toggle()
        root.area.applyAudio()
        root.area.active?.toast(root.area.muteAll ? "Ton aus" : "Ton an")
    }
    @objc func focusSearch() {
        if !root.sidebarVisible { root.sidebarVisible = true }
        win.makeFirstResponder(root.sidebar.search)
    }
    @objc func reloadList() { root.sidebar.load() }
    @objc func menuReload() { root.area.active?.reload() }
    @objc func menuNext() { root.area.active?.step(1) }
    @objc func menuBack() { root.area.active?.seek(-10) }
    @objc func menuFwd() { root.area.active?.seek(10) }
    @objc func menuPrev() { root.area.active?.step(-1) }
    @objc func menuAuto() { root.area.active?.setAuto() }
    @objc func menuLive() { root.area.active?.goLive() }
    @objc func menuClose() { if let a = root.area.active { root.area.close(a) } else { win.performClose(nil) } }

    func windowWillEnterFullScreen(_ notification: Notification) {
        sidebarBeforeFS = root.sidebarVisible
        root.sidebarVisible = false
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        root.sidebarVisible = sidebarBeforeFS
        if root.area.solo != nil { root.area.solo = nil }
    }

    func buildMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let mi = NSMenuItem()
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            mi.submenu = m
            main.addItem(mi)
        }
        func item(_ t: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            if responds(to: sel) { i.target = self }
            return i
        }
        sub("Streamed", [item("Nach Updates suchen…", #selector(checkUpdates), "u"),
                         item("Streamed ausblenden", #selector(NSApplication.hide(_:)), "h"),
                         .separator(),
                         item("Streamed beenden", #selector(NSApplication.terminate(_:)), "q")])
        sub("Bearbeiten", [item("Ausschneiden", #selector(NSText.cut(_:)), "x"),
                           item("Kopieren", #selector(NSText.copy(_:)), "c"),
                           item("Einsetzen", #selector(NSText.paste(_:)), "v"),
                           item("Alles auswählen", #selector(NSText.selectAll(_:)), "a")])
        sub("Spiel", [item("Suchen", #selector(focusSearch), "f"),
                      item("Spielliste neu laden", #selector(reloadList), "r", [.command, .shift]),
                      .separator(),
                      item("Stream neu laden", #selector(menuReload), "r"),
                      item("10 s zurück", #selector(menuBack), ""),
                      item("10 s vor", #selector(menuFwd), ""),
                      item("Nächster Stream", #selector(menuNext), "]"),
                      item("Vorheriger Stream", #selector(menuPrev), "["),
                      item("Automatisch", #selector(menuAuto), "a", [.command, .shift]),
                      item("Zum Live-Punkt", #selector(menuLive), "l"),
                      .separator(),
                      item("Kachel schließen", #selector(menuClose), "w")])
        sub("Ansicht", [item("Multistream ein/aus", #selector(toggleMulti), "n", [.command, .shift]),
                        item("Raster / Fokus", #selector(toggleLayout), "g"),
                        item("Spielliste ein/aus", #selector(toggleSidebar), "s", [.command, .control]),
                        item("Ton aus/an", #selector(toggleMute), "m", [.command, .shift]),
                        item("Vollbild", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])])
        let spoil = NSMenuItem(title: "Spoiler-Schutz (Spielstand verzögern)", action: nil, keyEquivalent: "")
        let sm = NSMenu(title: "Spoiler-Schutz")
        for d in [0, 30, 45, 60, 90, 120] {
            let it = NSMenuItem(title: d == 0 ? "Aus (sofort)" : "\(d) Sekunden", action: #selector(setSpoiler(_:)), keyEquivalent: "")
            it.target = self; it.tag = d
            sm.addItem(it)
        }
        spoil.submenu = sm
        main.items.first(where: { $0.submenu?.title == "Ansicht" })?.submenu?.addItem(.separator())
        main.items.first(where: { $0.submenu?.title == "Ansicht" })?.submenu?.addItem(spoil)
        spoilerMenu = sm
        updateSpoilerMenu()
        sub("Fenster", [item("Minimieren", #selector(NSWindow.performMiniaturize(_:)), "m")])
        NSApp.mainMenu = main
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
