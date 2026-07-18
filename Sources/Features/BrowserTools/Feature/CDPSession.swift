//
//  CDPSession.swift
//  BrowserTools
//
//  Chrome DevTools Protocol WebSocket client.
//  Ports the CDP communication and page-extraction logic from ds4_web.c.
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Errors

enum CDPError: LocalizedError {
    case notConnected
    case commandFailed(String)
    case javaScriptError(String)
    case invalidResponse(String)
    case disconnected
    case navigateFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "CDP session is not connected"
        case let .commandFailed(message):
            "CDP command failed: \(message)"
        case let .javaScriptError(message):
            "JavaScript evaluation failed: \(message)"
        case let .invalidResponse(message):
            "Invalid CDP response: \(message)"
        case .disconnected:
            "CDP session disconnected"
        case let .navigateFailed(message):
            "Navigation failed: \(message)"
        }
    }
}

/// A protocol notification emitted by Chrome. Responses carry an `id`; events
/// do not, so they must be routed separately from pending command continuations.
struct CDPEvent: @unchecked Sendable {
    let method: String
    let params: [String: Any]
    let sessionID: String?
}

/// Limits for a single CDP page session. They are host configuration, never
/// model-controlled tool arguments, so a page cannot stretch the Browser
/// process lifetime or memory budget through a prompt-injected call.
struct CDPSessionConfiguration: Sendable {
    let commandTimeoutNanoseconds: UInt64
    let maximumMessageSize: Int

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let timeoutSeconds = Self.positiveInt(
            environment["ZENCODE_BROWSER_CDP_COMMAND_TIMEOUT_SECONDS"],
            fallback: 30,
            range: 1...120
        )
        self.commandTimeoutNanoseconds = UInt64(timeoutSeconds) * 1_000_000_000
        self.maximumMessageSize = Self.positiveInt(
            environment["ZENCODE_BROWSER_CDP_MAX_MESSAGE_BYTES"],
            fallback: 8 * 1024 * 1024,
            range: 64 * 1024...32 * 1024 * 1024
        )
    }

    private static func positiveInt(
        _ rawValue: String?,
        fallback: Int,
        range: ClosedRange<Int>
    ) -> Int {
        guard let rawValue,
              let value = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              range.contains(value)
        else {
            return fallback
        }
        return value
    }
}

// MARK: - CDP WebSocket session

/// Manages a single WebSocket connection to a Chrome DevTools Protocol target
/// (a page tab) and provides high-level helpers for page navigation, readiness
/// polling, dynamic scrolling, and JavaScript-based content extraction.
final class CDPSession: @unchecked Sendable {
    private let webSocket: URLSessionWebSocketTask
    private let session: URLSession
    private let configuration: CDPSessionConfiguration
    private let lock = NSLock()
    private var nextIDCounter = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var cancelledPendingIDs = Set<Int>()
    private var eventHandlers: [UUID: @Sendable (CDPEvent) -> Void] = [:]
    private var receiveTask: Task<Void, Never>?

    /// Connects to the given page-target WebSocket URL.
    init(
        webSocketURL: URL,
        configuration: CDPSessionConfiguration = .init()
    ) {
        let urlConfiguration = URLSessionConfiguration.ephemeral
        urlConfiguration.timeoutIntervalForRequest = 30
        urlConfiguration.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: urlConfiguration)
        self.webSocket = session.webSocketTask(with: webSocketURL)
        self.configuration = configuration
        self.webSocket.maximumMessageSize = configuration.maximumMessageSize
    }

    deinit {
        webSocket.cancel()
        failAll(CDPError.disconnected)
    }

    /// Starts the WebSocket and the background receive loop.
    func connect() {
        webSocket.resume()
        // Capture self weakly and copy the receive method into a local to
        // avoid retaining self for the full duration of the indefinite receive
        // loop. The Task body only holds a strong reference for the duration
        // of each individual receive() call.
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard await self.receiveOnce() else { return }
            }
        }
        setReceiveTask(task)
    }

    /// Cancels the WebSocket and resumes all pending callers with an error.
    /// Order matters: drain continuations *before* cancelling the socket so
    /// late send/receive callbacks cannot resume them with raw URLErrors.
    func disconnect() {
        let taskToCancel = currentReceiveTask()
        failAll(CDPError.disconnected)
        webSocket.cancel(with: .goingAway, reason: nil)
        taskToCancel?.cancel()
    }

    /// Registers a handler for asynchronous CDP notifications such as network,
    /// page lifecycle, console, and dialog events. The token is valid only for
    /// this WebSocket session and must be removed by its owner.
    @discardableResult
    func addEventHandler(
        _ handler: @escaping @Sendable (CDPEvent) -> Void
    ) -> UUID {
        let token = UUID()
        lock.lock()
        eventHandlers[token] = handler
        lock.unlock()
        return token
    }

    func removeEventHandler(_ token: UUID) {
        lock.lock()
        eventHandlers.removeValue(forKey: token)
        lock.unlock()
    }

    // MARK: - Command dispatch

    /// Sends a CDP command and awaits the matching response.
    /// Honours task cancellation and imposes a 30-second deadline.
    func send(method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        let id = allocateID()
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: message)
        // CDP expects text frames (JSON), not binary.
        let text = String(data: data, encoding: .utf8) ?? "{}"

        // Register a timeout that will fail the command if no response arrives.
        let timeoutNanoseconds = configuration.commandTimeoutNanoseconds
        let timeoutSeconds = timeoutNanoseconds / 1_000_000_000
        let timeoutTask = Task { [weak self, timeoutNanoseconds, timeoutSeconds] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            if let leftover = self?.removePending(id: id) {
                leftover.resume(throwing: CDPError.commandFailed("Command timed out after \(timeoutSeconds)s"))
            }
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
                registerPending(id: id, continuation: cont)

                webSocket.send(.string(text)) { [weak self] sendError in
                    guard let self, let sendError else { return }
                    if let removed = self.removePending(id: id) {
                        removed.resume(throwing: sendError)
                    }
                }
            }
        } onCancel: {
            if let removed = cancelPending(id: id) {
                removed.resume(throwing: CancellationError())
            }
        }
    }

    /// Evaluates a JavaScript expression that returns a string.
    func evalString(_ expression: String) async throws -> String {
        let response = try await send(
            method: "Runtime.evaluate",
            params: [
                "expression": expression,
                "returnByValue": true,
                "awaitPromise": true,
                "includeCommandLineAPI": true,
            ]
        )

        let result = response["result"] as? [String: Any] ?? [:]
        if let exceptionDetails = result["exceptionDetails"] {
            let description = (exceptionDetails as? [String: Any])?["text"] as? String
                ?? (exceptionDetails as? [String: Any]).map { String(describing: $0) }
                ?? "unknown"
            throw CDPError.javaScriptError(description)
        }

        guard let remoteObject = result["result"] as? [String: Any],
              let value = remoteObject["value"] as? String
        else {
            throw CDPError.invalidResponse("Runtime.evaluate did not return a string value")
        }
        return value
    }

    // MARK: - Page lifecycle helpers

    /// Enables Page and Runtime domains and configures viewport emulation.
    func preparePage() async throws {
        _ = try await send(method: "Page.enable")
        _ = try await send(method: "Runtime.enable")
        try await BrowserDownloadPolicy.apply(to: self)
        // Best-effort: ignore failures from emulation commands.
        _ = try? await send(method: "Emulation.setFocusEmulationEnabled", params: ["enabled": true])
        _ = try? await send(method: "Emulation.setDeviceMetricsOverride", params: [
            "width": 1365,
            "height": 900,
            "deviceScaleFactor": 1,
            "mobile": false,
        ])
        try await waitReady()
    }

    /// Navigates the tab to `url` and waits for the page to become ready.
    /// Inspects `Page.navigate`'s `result.errorText` for navigation failures.
    func navigate(to url: String) async throws {
        let response = try await send(method: "Page.navigate", params: ["url": url])
        let result = response["result"] as? [String: Any] ?? [:]
        if let errorText = result["errorText"] as? String, !errorText.isEmpty {
            throw CDPError.navigateFailed(errorText)
        }
        try await waitNavigatedReady()
    }

    /// Polls `document.readyState` until the page reports *complete* or
    /// *interactive*. Bounded to the same iteration count as ds4_web.
    /// Throws if the page does not become ready within the polling budget.
    func waitReady() async throws {
        for _ in 0..<80 {
            try Task.checkCancellation()
            do {
                let state = try await evalString("document.readyState")
                if state == "complete" || state == "interactive" {
                    try await sleep(milliseconds: 800)
                    return
                }
            } catch {
                // Runtime may briefly fail during initial load — keep polling.
            }
            try await sleep(milliseconds: 250)
        }
        throw CDPError.navigateFailed("Page did not become ready within polling budget")
    }

    /// Waits for navigation to settle: polls the real URL, readyState, and body
    /// text length until they stabilise. Mirrors `web_wait_navigated_ready`.
    func waitNavigatedReady() async throws {
        var lastTextLength = -1
        var stableChecks = 0
        var sawRealURL = false

        for iteration in 0..<100 {
            try Task.checkCancellation()

            let probe = """
            location.href+'\\n'+document.readyState+'\\n'+ \
            ((document.body&&document.body.innerText)||'').length
            """

            do {
                let result = try await evalString(probe)
                let parts = result.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count >= 3 else {
                    try await sleep(milliseconds: 250)
                    continue
                }
                let href = String(parts[0])
                let ready = String(parts[1])
                let textLength = Int(parts[2]) ?? 0

                let isRealURL = !href.isEmpty
                    && href != "about:blank"
                    && !href.hasPrefix("chrome://")
                let isReady = ready == "complete" || ready == "interactive"
                if isRealURL { sawRealURL = true }
                if textLength > 0, textLength == lastTextLength {
                    stableChecks += 1
                } else {
                    stableChecks = 0
                }
                lastTextLength = textLength

                if sawRealURL, isReady, textLength > 0, stableChecks >= 2 {
                    try await sleep(milliseconds: 500)
                    return
                }
                if sawRealURL, isReady, iteration >= 24 {
                    return
                }
            } catch {
                // Probe may fail transiently — keep polling.
            }

            try await sleep(milliseconds: 250)
        }

        throw CDPError.navigateFailed("Page navigation did not settle within polling budget")
    }

    /// Clicks the Google consent dialog if present, then waits for the page to
    /// settle again. Mirrors the ds4_web consent-click flow.
    func clickGoogleConsentIfNeeded() async throws {
        let host = try await evalString("location.hostname || ''")
        guard BrowserGoogleConsentOriginPolicy.allows(host: host) else {
            return
        }
        let clicked = try await evalString(Self.googleConsentClickJS)
        guard !clicked.isEmpty else { return }
        try await sleep(milliseconds: 1500)
        // Best-effort re-wait; a transient error should not abort the run.
        try? await waitNavigatedReady()
    }

    /// Scrolls the page incrementally to trigger lazy-loaded content (comments,
    /// infinite scroll). Mirrors `web_scroll_dynamic_page`.
    func scrollDynamicPage() async throws {
        try Task.checkCancellation()
        // awaitPromise: true in evalString resolves the scroll Promise.
        _ = try await evalString(Self.dynamicScrollJS)
    }

    /// Runs the search-result extraction script and returns markdown.
    func extractSearchResults() async throws -> String {
        try await evalString(Self.extractSearchJS)
    }

    /// Runs the page-content extraction script and returns markdown.
    func extractPageContent() async throws -> String {
        try await evalString(Self.extractPageJS)
    }

    // MARK: - Private

    private func allocateID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextIDCounter
        nextIDCounter += 1
        return id
    }

    private func registerPending(id: Int, continuation: CheckedContinuation<[String: Any], Error>) {
        lock.lock()
        if cancelledPendingIDs.remove(id) != nil {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        pending[id] = continuation
        lock.unlock()
    }

    private func removePending(id: Int) -> CheckedContinuation<[String: Any], Error>? {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }

    private func cancelPending(id: Int) -> CheckedContinuation<[String: Any], Error>? {
        lock.lock()
        defer { lock.unlock() }
        if let continuation = pending.removeValue(forKey: id) {
            return continuation
        }
        cancelledPendingIDs.insert(id)
        return nil
    }

    private func setReceiveTask(_ task: Task<Void, Never>) {
        lock.lock()
        receiveTask = task
        lock.unlock()
    }

    private func currentReceiveTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return receiveTask
    }

    /// Processes a single WebSocket message. On transport error, fails all
    /// pending commands and asks the receive loop to terminate.
    private func receiveOnce() async -> Bool {
        do {
            let message = try await webSocket.receive()
            switch message {
            case let .data(data):
                handleMessage(data)
            case let .string(text):
                handleMessage(Data(text.utf8))
            @unknown default:
                return true
            }
            return true
        } catch {
            failAll(error)
            return false
        }
    }

    /// Internal for focused protocol tests. Production callers receive events
    /// through `addEventHandler(_:)`, never through raw CDP objects.
    func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let id = json["id"] as? Int {
            let continuation = removePending(id: id)
            guard let continuation else { return }

            if let error = json["error"] {
                let message = (error as? [String: Any])?["message"] as? String
                    ?? String(describing: error)
                continuation.resume(throwing: CDPError.commandFailed(message))
            } else {
                continuation.resume(returning: json)
            }
            return
        }

        guard let method = json["method"] as? String else { return }
        let event = CDPEvent(
            method: method,
            params: json["params"] as? [String: Any] ?? [:],
            sessionID: json["sessionId"] as? String
        )
        let handlers = currentEventHandlers()
        handlers.forEach { $0(event) }
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let allPending = pending
        pending.removeAll()
        cancelledPendingIDs.removeAll()
        lock.unlock()
        for (_, continuation) in allPending {
            continuation.resume(throwing: error)
        }
    }

    private func currentEventHandlers() -> [@Sendable (CDPEvent) -> Void] {
        lock.lock()
        defer { lock.unlock() }
        return Array(eventHandlers.values)
    }

    private func sleep(milliseconds ms: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }
}

// MARK: - JavaScript extraction scripts
// Ported verbatim from ds4_web.c to preserve extraction fidelity.

extension CDPSession {
    /// Clicks "Accept all" / "I agree" consent buttons (multi-language).
    static let googleConsentClickJS = #"""
(() => {
const clean=s=>(s||'').replace(/\s+/g,' ').trim();
const pats=[/accept all/i,/i agree/i,/agree/i,/accetta tutto/i,/tout accepter/i,/aceptar todo/i,/alle akzeptieren/i];
const els=[...document.querySelectorAll('button,[role=button],input[type=submit],a')];
for (const el of els){const t=clean(el.innerText||el.value||el.textContent);
if(!t)continue; if(pats.some(p=>p.test(t))){el.click(); return 'clicked '+t;}}
return '';
})()
"""#

    /// Extracts Google search results as markdown: visible links + text snapshot.
    static let extractSearchJS = #"""
(() => {
const clean=s=>(s||'').replace(/\s+/g,' ').trim();
const esc=s=>clean(s).replace(/\\/g,'\\\\').replace(/\[/g,'\\[').replace(/\]/g,'\\]').replace(/\n/g,' ');
const visible=el=>{const r=el.getBoundingClientRect();const st=getComputedStyle(el);return r.width>0&&r.height>0&&st.display!=='none'&&st.visibility!=='hidden'&&st.opacity!=='0';};
const bad=h=>(/(^|\.)google\./.test(h)||/(^|\.)gstatic\./.test(h)||/(^|\.)googleusercontent\./.test(h));
const lines=['# Google search results','',`URL: ${location.href}`,'','## Visible links'];
const seen=new Set();
for(const a of document.querySelectorAll('a[href]')){if(!visible(a))continue;let href=a.href||'';
try{const u=new URL(href);if(u.pathname==='/url'&&u.searchParams.get('q'))href=u.searchParams.get('q');}catch{}
let u;try{u=new URL(href);}catch{continue;}if(!/^https?:$/.test(u.protocol))continue;if(bad(u.hostname))continue;
const text=esc(a.innerText||a.textContent);if(text.length<3)continue;if(seen.has(u.href))continue;seen.add(u.href);
lines.push(`- [${text.slice(0,180)}](${u.href})`);if(seen.size>=20)break;}
lines.push('','## Text snapshot',clean(document.body.innerText).slice(0,1200));
return lines.join('\n');
})()
"""#

    /// Extracts page content as markdown: headings, paragraphs, lists, code,
    /// blockquotes, comments, and visible links.
    static let extractPageJS = #"""
(() => {
const clean=s=>(s||'').replace(/\s+/g,' ').trim();
const esc=s=>clean(s).replace(/\\/g,'\\\\').replace(/\[/g,'\\[').replace(/\]/g,'\\]').replace(/\n/g,' ');
const visible=el=>{const r=el.getBoundingClientRect();const st=getComputedStyle(el);return r.width>0&&r.height>0&&st.display!=='none'&&st.visibility!=='hidden'&&st.opacity!=='0';};
const inline=n=>{if(!n)return'';if(n.nodeType===3)return n.nodeValue;if(n.nodeType!==1)return'';const el=n;
if(el.tagName==='SCRIPT'||el.tagName==='STYLE'||el.tagName==='NOSCRIPT')return'';
if(el.tagName==='A'){const t=esc(el.innerText||el.textContent);const h=el.href||'';return t&&h?`[${t}](${h})`:t;}
if(el.tagName==='CODE')return '`'+clean(el.innerText||el.textContent).replace(/`/g,'\\`')+'`';
return [...el.childNodes].map(inline).join('');};
const lines=[`# ${clean(document.title)||location.href}`,'',`URL: ${location.href}`,'','## Content'];
const blocks=[...document.body.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,pre,blockquote,td,th,[id="content-text"],[class*="comment-body"],[class*="comment-content"],[data-testid*="comment-text"]')];
const seen=new Set();
for(const el of blocks){if(!visible(el))continue;let s='';const tag=el.tagName;
if(/^H[1-6]$/.test(tag)){s='#'.repeat(Number(tag[1]))+' '+inline(el);}
else if(tag==='LI'){s='- '+inline(el);}
else if(tag==='PRE'){s='```\n'+(el.innerText||el.textContent||'').trimEnd()+'\n```';}
else if(tag==='BLOCKQUOTE'){s='> '+clean(el.innerText||el.textContent);}
else{s=inline(el);}s=s.trim();if(!s||seen.has(s))continue;seen.add(s);lines.push('',s);
if(lines.join('\n').length>900000){lines.push('','[Content truncated by browser extractor.]');break;}}
lines.push('','## Visible links');let n=0;const linkSeen=new Set();
for(const a of document.querySelectorAll('a[href]')){if(!visible(a))continue;const t=esc(a.innerText||a.textContent);if(t.length<3)continue;
let u;try{u=new URL(a.href);}catch{continue;}if(!/^https?:$/.test(u.protocol)||linkSeen.has(u.href))continue;linkSeen.add(u.href);
lines.push(`- [${t.slice(0,160)}](${u.href})`);if(++n>=80)break;}
return lines.join('\n');
})()
"""#

    /// Scrolls the page incrementally to load lazy/infinite content. Returns a
    /// Promise that resolves when scrolling is exhausted.
    static let dynamicScrollJS = #"""
(() => new Promise(resolve => {
const root=()=>document.scrollingElement||document.documentElement||document.body;
const blockSel='h1,h2,h3,h4,h5,h6,p,li,pre,blockquote,td,th,[id="content-text"],[class*="comment-body"],[class*="comment-content"],[data-testid*="comment-text"]';
const lazySel='[onscroll],[loading="lazy"],[data-src],[data-lazy],[class*="lazy"],[class*="infinite"],[class*="virtual"],[role="feed"],[id*="comment"],[class*="comment"],[data-testid*="comment"]';
const hookCount=()=>{let n=0;try{if(window.onscroll)n++;if(document.onscroll)n++;if(document.body&&document.body.onscroll)n++;}catch(e){}
try{if(typeof getEventListeners==='function'){for(const o of [window,document,document.body]){if(!o)continue;const ev=getEventListeners(o);if(ev&&ev.scroll)n+=ev.scroll.length;}}}catch(e){}
try{n+=document.querySelectorAll(lazySel).length;}catch(e){}return n;};
const metrics=()=>{const r=root();return {
height:r?r.scrollHeight:0,
view:innerHeight||900,
y:scrollY||(r&&r.scrollTop)||0,
text:((document.body&&document.body.innerText)||'').length,
links:document.links?document.links.length:0,
blocks:document.body?document.body.querySelectorAll(blockSel).length:0,
hooks:hookCount()};};
const sig=m=>[m.height,m.text,m.links,m.blocks].join('|');
const grew=(a,b)=>b.height>a.height+20||b.text>a.text+200||b.links>a.links+2||b.blocks>a.blocks+2;
const scrollOnce=()=>{const r=root();if(!r)return;
const h=Math.max(700,Math.floor((innerHeight||900)*0.85));
window.scrollTo(0,Math.min(r.scrollHeight,(scrollY||r.scrollTop||0)+h));};
let last=metrics(),lastSig=sig(last),same=0,steps=0;
const scrollable=last.height>last.view*1.35;
if(!scrollable||last.hooks===0){resolve('scroll skipped hooks='+last.hooks+' text='+last.text);return;}
const tick=()=>{
if(steps>=28){resolve('scrolled '+steps+' text='+last.text);return;}
const before=last;
scrollOnce();steps++;
setTimeout(()=>{const now=metrics(),nowSig=sig(now);
if(nowSig===lastSig)same++;else same=0;
const loaded=grew(before,now);
last=now;lastSig=nowSig;
if(steps===1&&!loaded){resolve('scroll probe unchanged text='+now.text);return;}
const atBottom=now.y+now.view+20>=now.height;
if(same>=4||(atBottom&&same>=1)){resolve('scrolled '+steps+' text='+now.text);return;}
tick();},900);
};tick();
}))()
"""#
}
