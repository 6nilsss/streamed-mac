// Streamed for macOS — multiview player for streamed.pk
// Port of the Fire TV app: auto best stream + failover, learned source scores, ad blocking, anti-sandbox shim.
// On the Mac every tile plays at the same time (muted except the selected one).

import AppKit
import WebKit

// MARK: - Basics

let API = "https://streamed.pk/api"
let UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
let MAX_TILES = 6
let UD = UserDefaults.standard

func rgb(_ h: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
let C_BG = rgb(0x0B0F17), C_CARD = rgb(0x161C28), C_ACCENT = rgb(0xE5484D), C_TEXT = rgb(0xEDEFF3), C_MUTED = rgb(0x8A93A6)

func nowMs() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Streamed.log")
func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
    let line = f.string(from: Date()) + " " + s + "\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else { try? data.write(to: logURL) }
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
final class PassView: FlippedView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }

// MARK: - Models / API

struct Match {
    let id: String, title: String, category: String, date: Int64, popular: Bool
    let sources: [(source: String, id: String)]
    init?(_ d: [String: Any]) {
        id = str(d["id"]); title = str(d["title"]); category = str(d["category"])
        date = (d["date"] as? NSNumber)?.int64Value ?? 0
        popular = (d["popular"] as? NSNumber)?.boolValue ?? false
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

func fetchStreams(_ m: Match) async -> [StreamInfo] {
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
        for await part in g { out += part }
        return out
    }
    func lang(_ s: StreamInfo) -> Int { let l = s.title.lowercased(); return l.contains("english") || l.contains("german") ? 0 : 1 }
    var seen = Set<String>()
    return raw.filter { seen.insert($0.url).inserted }.sorted { a, b in
        if a.hd != b.hd { return a.hd }
        if lang(a) != lang(b) { return lang(a) < lang(b) }
        return a.title < b.title
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

let PAUSE_JS = #"""
(function(){var v=document.querySelector('.jw-media video')||document.querySelector('video');if(!v)return 'none';
if(v.paused){window.__userPaused=false;try{jwplayer().play()}catch(e){v.play()}return 'play'}
window.__userPaused=true;try{jwplayer().pause()}catch(e){v.pause()}return 'pause'})()
"""#

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
    let titleL = makeLabel(13, bold: true)
    let infoL = makeLabel(11, color: rgb(0xB8C0D0))
    let streamBtn = NSButton()
    let closeBtn = NSButton()
    let backBtn = NSButton()
    let fwdBtn = NSButton()
    let toastBox = PassView()
    let toastL = NSTextField(wrappingLabelWithString: "")
    let border = PassView()
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

        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0, alpha: 0.62).cgColor
        for (b, t, a) in [(streamBtn, "Streams ▾", #selector(showMenu(_:))), (closeBtn, "✕", #selector(closeTapped)), (backBtn, "↺ 10", #selector(backTapped)), (fwdBtn, "10 ↻", #selector(fwdTapped))] {
            b.isBordered = false
            b.target = self
            b.action = a
            b.attributedTitle = NSAttributedString(string: t, attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
            bar.addSubview(b)
        }
        for b in [backBtn, fwdBtn] {
            b.wantsLayer = true; b.layer?.cornerRadius = 6
            b.layer?.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
        }
        backBtn.toolTip = "10 Sekunden zurück (←)"
        fwdBtn.toolTip = "10 Sekunden vor (→)"
        streamBtn.wantsLayer = true
        streamBtn.layer?.cornerRadius = 6
        streamBtn.layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
        bar.addSubview(titleL)
        bar.addSubview(infoL)
        addSubview(bar)

        toastBox.wantsLayer = true
        toastBox.layer?.backgroundColor = NSColor(white: 0, alpha: 0.72).cgColor
        toastBox.layer?.cornerRadius = 8
        toastL.font = .systemFont(ofSize: 13, weight: .medium)
        toastL.textColor = .white
        toastL.maximumNumberOfLines = 2
        toastBox.addSubview(toastL)
        toastBox.isHidden = true
        addSubview(toastBox)

        border.wantsLayer = true
        border.layer?.borderColor = C_ACCENT.cgColor
        border.layer?.borderWidth = 0
        addSubview(border)
        showBar()
    }
    required init?(coder: NSCoder) { fatalError() }

    func makeWeb() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
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
        addSubview(w, positioned: .below, relativeTo: nil)
        web = w
    }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        web.frame = bounds
        bar.frame = NSRect(x: 0, y: 0, width: w, height: 40)
        closeBtn.frame = NSRect(x: w - 34, y: 8, width: 26, height: 24)
        streamBtn.frame = NSRect(x: w - 34 - 98, y: 8, width: 92, height: 24)
        fwdBtn.frame = NSRect(x: w - 34 - 98 - 50, y: 8, width: 44, height: 24)
        backBtn.frame = NSRect(x: w - 34 - 98 - 100, y: 8, width: 44, height: 24)
        let narrow = w < 380
        backBtn.isHidden = narrow; fwdBtn.isHidden = narrow
        let tw = max(40, w - (narrow ? 150 : 250))
        titleL.frame = NSRect(x: 12, y: 4, width: tw, height: 18)
        infoL.frame = NSRect(x: 12, y: 21, width: tw, height: 15)
        let maxW = max(80, min(w - 44, 440))
        toastL.preferredMaxLayoutWidth = maxW
        var s = toastL.intrinsicContentSize
        s.width = min(maxW, ceil(s.width)); s.height = ceil(s.height)
        toastBox.frame = NSRect(x: 12, y: h - s.height - 30, width: s.width + 20, height: s.height + 14)
        toastL.frame = NSRect(x: 10, y: 7, width: s.width, height: s.height)
        border.frame = bounds
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
        titleL.stringValue = (isActive && multi && !(area?.muteAll ?? false) ? "🔊 " : "") + match.title
        var parts = [auto ? "AUTO" : "MANUELL"]
        if current >= 0 && current < streams.count {
            parts.append(streams[current].title)
            let h = current < heights.count ? heights[current] : 0
            parts.append(h > 0 ? "\(h)p" : "lädt…")
        } else {
            parts.append(listReady ? "kein Stream" : "suche Streams…")
        }
        infoL.stringValue = parts.joined(separator: "  ·  ")
        border.layer?.borderWidth = isActive && multi ? 3 : 0
    }

    // MARK: stream control

    func open(_ m: Match) {
        match = m
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
        Task { @MainActor [weak self] in
            let rows = await fetchStreams(m)
            guard let self, self.openToken == token else { return }
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
    }

    func play(_ i: Int, _ why: String) {
        guard i >= 0, i < streams.count, let url = URL(string: streams[i].url) else { return }
        current = i
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
        updateChrome()
    }
    func reload() { if current >= 0 { play(current, "Neu geladen") } else { open(match) } }
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
            log("[\(self.match.title)] seek \(Int(d))s -> \(behind)s hinter Live (Puffer \(win)s)")
            if clamped == 1 { self.toast("Weiter zurück geht nicht – Stream puffert nur \(win) s\n\(behind) s hinter Live") }
            else { self.toast(behind <= 3 ? "Live" : "\(behind) s hinter Live  ·  → vor · L = Live") }
        }
    }
    func goLive() { web.evaluateJavaScript(GO_LIVE, completionHandler: nil); userPaused = false; toast("Live") }
    func togglePause() {
        web.evaluateJavaScript(PAUSE_JS) { [weak self] r, _ in
            guard let self else { return }
            self.userPaused = (r as? String) == "pause"
            self.toast(self.userPaused ? "Pause" : "Play")
        }
    }
    func applyAudio() {
        web.evaluateJavaScript("window.__mute=\(muted);var v=document.querySelector('.jw-media video')||document.querySelector('video');if(v)v.muted=window.__mute;try{jwplayer().setMute(window.__mute)}catch(e){}", completionHandler: nil)
        updateChrome()
    }
    func shutdown() {
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
    @objc func menuStream(_ i: NSMenuItem) { auto = false; failed[i.tag] = false; play(i.tag, "Manuell gewählt") }
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
        if homeHost.isEmpty || h == homeHost || h.hasSuffix("." + homeHost) { decisionHandler(.allow); return }
        log("[\(match.title)] blocked navigation to \(h)")
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
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
    let emptyL = NSTextField(wrappingLabelWithString: "Doppelklick auf ein Spiel links, um es zu starten.\nMehrere Spiele gleichzeitig: oben links „Multistream“ einschalten (bis zu 6).")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        emptyL.alignment = .center
        emptyL.textColor = C_MUTED
        emptyL.font = .systemFont(ofSize: 15)
        addSubview(emptyL)
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
        active = t
        for x in tiles { x.isActive = x === t; x.applyAudio() }
        if focusMode { needsLayout = true }
    }

    func applyAudio() { for x in tiles { x.applyAudio() } }

    func changed() {
        emptyL.isHidden = !tiles.isEmpty
        for t in tiles { t.updateChrome() }
        needsLayout = true
        onChange?()
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height, n = tiles.count, gap: CGFloat = 2
        emptyL.frame = NSRect(x: 40, y: H / 2 - 30, width: max(0, W - 80), height: 60)
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
    let t = makeLabel(13, bold: true), s = makeLabel(11, color: C_MUTED), r = makeLabel(11, bold: true)
    init(_ id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        addSubview(t); addSubview(s); addSubview(r)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        r.sizeToFit()
        let rw = r.frame.width
        r.frame = NSRect(x: W - rw - 10, y: (H - 16) / 2, width: rw, height: 16)
        t.frame = NSRect(x: 10, y: H / 2 - 1, width: W - rw - 28, height: 18)
        s.frame = NSRect(x: 10, y: H / 2 - 18, width: W - rw - 28, height: 15)
    }
    func set(_ m: Match, open: Bool) {
        t.stringValue = (open ? "● " : "") + m.title
        t.textColor = open ? C_ACCENT : C_TEXT
        s.stringValue = catName(m.category) + (m.popular ? "  ·  beliebt" : "")
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let time = f.string(from: Date(timeIntervalSince1970: Double(m.date) / 1000))
        r.stringValue = m.is247 ? "24/7" : (m.isLive ? "LIVE · " + time : time)
        r.textColor = m.isLive && !m.is247 ? C_ACCENT : C_MUTED
        needsLayout = true
    }
}

final class Sidebar: FlippedView, NSTableViewDataSource, NSTableViewDelegate {
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
    var onMulti: ((Bool) -> Void)?
    let multiBtn = NSButton(title: "▦ Multistream", target: nil, action: nil)
    func setMulti(_ on: Bool) {
        multiBtn.state = on ? .on : .off
        multiBtn.contentTintColor = on ? C_ACCENT : nil
        hint.stringValue = (on ? "Multistream AN: Doppelklick / ↩ = neue Kachel  ·  ⌥ = aktive ersetzen\nKlick auf Kachel = Ton  ·  G Raster/Fokus  ·  1–6 Kachel\n" : "Doppelklick / ↩ = Spiel öffnen (ersetzt das laufende)\nRechtsklick = als zusätzliche Kachel (Multistream)\n") + "Doppelklick / F = Vollbild · Esc raus · S Liste\n← → 10 s spulen · L Live · [ ] Stream · A Auto · M Ton · ␣ Pause"
    }
    @objc func multiTapped() { onMulti?(multiBtn.state == .on) }
    var isOpen: ((String) -> Bool)?
    var loadToken = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = C_BG.cgColor
        logo.stringValue = "Streamed"
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
        table.rowHeight = 46
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 4)
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
        multiBtn.setButtonType(.pushOnPushOff)
        multiBtn.bezelStyle = .rounded
        multiBtn.target = self
        multiBtn.action = #selector(multiTapped)
        multiBtn.toolTip = "Mehrere Spiele gleichzeitig anzeigen"
        for v in [logo, multiBtn, tabs, search, header, scroll, hint] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height, P: CGFloat = 16
        multiBtn.sizeToFit()
        let mw = multiBtn.frame.width + 8
        multiBtn.frame = NSRect(x: W - P - mw, y: 14, width: mw, height: 24)
        logo.frame = NSRect(x: P, y: 12, width: W - 2 * P - mw - 8, height: 28)
        tabs.frame = NSRect(x: P, y: 46, width: W - 2 * P, height: 24)
        search.frame = NSRect(x: P, y: 78, width: W - 2 * P, height: 24)
        header.frame = NSRect(x: P, y: 108, width: W - 2 * P, height: 15)
        let hintH: CGFloat = 62
        scroll.frame = NSRect(x: 6, y: 128, width: W - 12, height: max(0, H - 128 - hintH - 10))
        hint.frame = NSRect(x: P, y: H - hintH - 6, width: W - 2 * P, height: hintH)
        table.tableColumns.first?.width = max(50, scroll.contentSize.width - 2)
    }

    @objc func tabChanged() { all = []; shown = []; table.reloadData(); load() }
    @objc func filterChanged() { applyFilter() }

    func load() {
        loadToken += 1
        let token = loadToken
        let tab = max(0, tabs.selectedSegment)
        let path = ["/matches/live", "/matches/football", "/matches/all-today"][tab]
        if all.isEmpty { header.stringValue = "Lade Spiele…" }
        Task { @MainActor [weak self] in
            let arr = await getJSON(path) as? [[String: Any]]
            guard let self, token == self.loadToken else { return }
            guard let arr else { self.header.stringValue = "Fehler beim Laden – Internet?"; return }
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
            self.applyFilter()
        }
    }

    func applyFilter() {
        let sel = table.selectedRow >= 0 && table.selectedRow < shown.count ? shown[table.selectedRow].id : nil
        let q = search.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        shown = q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) || catName($0.category).lowercased().contains(q) }
        table.reloadData()
        if let sel, let i = shown.firstIndex(where: { $0.id == sel }) { table.selectRowIndexes([i], byExtendingSelection: false) }
        header.stringValue = shown.isEmpty ? "Gerade keine Spiele." : "\(shown.count) Spiele"
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
    var sidebarVisible = true { didSet { sidebar.isHidden = !sidebarVisible; needsLayout = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(area)
        addSubview(sidebar)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let sw: CGFloat = sidebarVisible ? 330 : 0
        sidebar.frame = NSRect(x: 0, y: 0, width: sw, height: bounds.height)
        area.frame = NSRect(x: sw, y: 0, width: bounds.width - sw, height: bounds.height)
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
        log("launch")
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

    func setup() {
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 860), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.title = "Streamed"
        win.appearance = NSAppearance(named: .darkAqua)
        win.minSize = NSSize(width: 820, height: 480)
        win.collectionBehavior = [.fullScreenPrimary]
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false
        root = RootView(frame: win.contentView!.bounds)
        win.contentView = root
        win.delegate = self
        if !win.setFrameUsingName("StreamedMain") { win.center() }
        win.setFrameAutosaveName("StreamedMain")
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
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        root.sidebar.load()
        win.makeFirstResponder(root.sidebar.table)
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.root.area.tiles.forEach { $0.poll() } }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.root.sidebar.load() }
        })
        installMonitors()
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count, let n = Int(args[i + 1]) { autoOpen(n) }
    }

    func setMulti(_ on: Bool) {
        root.area.multi = on
        root.sidebar.setMulti(on)
        root.area.active?.toast(on ? "Multistream an – neue Spiele kommen als eigene Kachel dazu" : "Multistream aus")
    }
    @objc func toggleMulti() { setMulti(!root.area.multi) }

    func autoOpen(_ n: Int) {
        if n > 1 { setMulti(true) }
        Task {
            guard let arr = await getJSON("/matches/live") as? [[String: Any]] else { return }
            let ms = arr.compactMap { Match($0) }.filter { !$0.is247 }.sorted {
                ($0.category == "football" ? 0 : 1, $0.popular ? 0 : 1) < ($1.category == "football" ? 0 : 1, $1.popular ? 0 : 1)
            }
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
        sub("Streamed", [item("Streamed ausblenden", #selector(NSApplication.hide(_:)), "h"),
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
