import Foundation
import WebKit
import Darwin

/// WebKit owns media only. All provider credentials and HTTP/WS ownership stay in zen.
@MainActor final class SubscriptionClient: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var web: WKWebView?
    private var bridge: VoiceBridgeClient?
    private var startup: Task<Void, Never>?
    private var startupDeadline: Task<Void, Never>?
    private var mediaReady = false
    private var epoch = UUID()
    private var authorized = false, loaded = false
    private var gate = SubscriptionDelegationGate()
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onTool: ((String, JSON) async -> String)?
    func connect(executable: String, projects: [String]) {
        guard web == nil, bridge == nil else { return }
        epoch = UUID(); let token = epoch; authorized = true; gate = .init(); mediaReady = false
        startupDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(40)) } catch { return }
            guard let self, self.epoch == token, self.authorized, !self.mediaReady else { return }
            self.onFailure?("Tempo massimo di avvio WebRTC superato; riattiva manualmente.")
        }
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                let bridge = VoiceBridgeClient(); self.bridge = bridge
                bridge.onFailure = { [weak self] message in guard let self, self.epoch == token, self.authorized else { return }; self.onFailure?(message) }
                bridge.onDelegation = { [weak self, weak bridge] id, text in
                    guard let self, let bridge, self.epoch == token, self.authorized else { return }
                    if self.gate.hasSeen(id) { return }
                    guard let arguments = self.gate.accept(id: id, text: text, projects: projects) else { bridge.result(id: id, text: "Richiesta rifiutata: schema/progetto non consentito o duplicato."); return }
                    Task { [weak self] in
                        guard let self, self.epoch == token, self.authorized else { return }
                        let result = await self.onTool?(id, arguments) ?? "Richiesta rifiutata"
                        guard self.epoch == token, self.authorized else { return }
                        bridge.result(id: id, text: result)
                    }
                }
                try await bridge.start(executable: executable)
                try self.check(token)
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .nonPersistent(); config.mediaTypesRequiringUserActionForPlayback = []
                let view = WKWebView(frame: .zero, configuration: config)
                view.navigationDelegate = self; view.uiDelegate = self; self.web = view; loaded = false
                view.loadHTMLString(Self.page, baseURL: URL(string: "https://zenvoice.invalid/"))
                for _ in 0..<500 { try self.check(token); if self.loaded { break }; try await Task.sleep(for: .milliseconds(10)) }
                guard self.loaded else { throw VoiceError.timeout }
                let offer = try await self.script(Self.makeOffer)
                try self.check(token)
                guard offer.utf8.count <= 65_536 else { throw VoiceError.overflow }
                let answer = try await bridge.open(sdp: offer, projects: projects)
                try self.check(token)
                guard SubscriptionSDPPolicy.accepts(answer) else { throw VoiceError.invalid("Candidati WebRTC non pubblici o SDP non valido: sessione chiusa.") }
                let connected = try await self.script(Self.applyAnswer, arguments: ["answer": answer])
                try self.check(token)
                guard connected == "ready" else { throw VoiceError.invalid("Audio WebRTC non pronto. Verifica permessi microfono, rete e uscita audio.") }
                self.mediaReady = true; self.startupDeadline?.cancel(); self.startupDeadline = nil
                self.onReady?()
                // Page liveness/ICE fences; no PCM, transcript or candidate payload crosses this poll.
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1)); try self.check(token)
                    guard try await self.script("return window.voiceHealthy() ? 'ready' : 'closed';") == "ready" else { throw VoiceError.disconnected }
                }
            } catch {
                if self.epoch == token, self.authorized { self.onFailure?("Connessione audio subscription interrotta. Verifica microfono/rete e riattiva; nessun fallback API.") }
            }
        }
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard authorized, epoch == token else { throw VoiceError.disconnected }
    }
    private func script(_ source: String, arguments: [String: Any] = [:]) async throws -> String {
        guard let web else { throw VoiceError.disconnected }
        let value = try await web.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: .page)
        guard let text = value as? String else { throw VoiceError.disconnected }
        return text
    }
    func announce(_ text: String) { if authorized { bridge?.speak(text) } }
    /// Mute capture/playback immediately at the native boundary before async teardown.
    func stopMedia() {
        authorized = false; epoch = UUID(); startup?.cancel(); startup = nil
        startupDeadline?.cancel(); startupDeadline = nil; mediaReady = false
        web?.setMicrophoneCaptureState(.muted, completionHandler: nil)
        web?.pauseAllMediaPlayback(completionHandler: nil)
        web?.evaluateJavaScript("window.voiceStop && window.voiceStop();", completionHandler: nil)
    }
    func stop() async {
        stopMedia()
        if let web {
            _ = try? await web.callAsyncJavaScript("window.voiceStop && window.voiceStop(); return 'closed';", arguments: [:], in: nil, contentWorld: .page)
            web.stopLoading(); web.navigationDelegate = nil; web.uiDelegate = nil
        }
        self.web = nil
        let bridge = self.bridge; self.bridge = nil
        await bridge?.stop()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if webView === web { loaded = true } }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url?.absoluteString
        let initial = !loaded && action.targetFrame?.isMainFrame == true && (url == "about:blank" || url == "https://zenvoice.invalid/")
        decisionHandler(initial ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(authorized && webView === web && frame.isMainFrame && origin.protocol == "https" && origin.host == "zenvoice.invalid" && type == .microphone ? .grant : .deny)
    }
    private static let page = """
    <!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; media-src blob:; connect-src 'none'; style-src 'none'">
    <audio id="voice-output" autoplay></audio><script>
    window.voiceClosing=false;window.voicePC=null;window.voiceStream=null;window.voiceChannel=null;window.voicePlayback=false;
    window.voiceStop=()=>{window.voiceClosing=true;const a=document.getElementById('voice-output');a.muted=true;a.pause();a.srcObject=null;
      if(window.voiceStream)window.voiceStream.getTracks().forEach(t=>t.stop());if(window.voicePC)window.voicePC.close();};
    window.voiceHealthy=()=>!window.voiceClosing && window.voicePC && window.voicePC.connectionState==='connected' && window.voiceChannel.readyState==='open' && window.voiceStream.getAudioTracks().every(t=>t.readyState==='live') && !document.getElementById('voice-output').paused && !document.getElementById('voice-output').muted;
    </script>
    """
    private static let makeOffer = """
    if(window.voiceClosing || window.voicePC) throw new Error('closed');
    const stream=await navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true,noiseSuppression:true,autoGainControl:true},video:false});
    if(window.voiceClosing){stream.getTracks().forEach(t=>t.stop());throw new Error('closed');}
    window.voiceStream=stream;const pc=new RTCPeerConnection({iceServers:[]});window.voicePC=pc;
    stream.getTracks().forEach(track=>pc.addTrack(track,stream));
    window.voiceChannel=pc.createDataChannel('oai-events',{ordered:true});pc.ondatachannel=e=>e.channel.close();
    pc.ontrack=e=>{if(window.voiceClosing){e.track.stop();return;}if(e.track.kind!=='audio'){e.track.stop();return;}
      const audio=document.getElementById('voice-output');audio.muted=true;audio.srcObject=e.streams[0]||new MediaStream([e.track]);};
    await pc.setLocalDescription(await pc.createOffer());
    if(pc.iceGatheringState!=='complete')await new Promise(resolve=>{const t=setTimeout(resolve,2000);pc.addEventListener('icegatheringstatechange',()=>{if(pc.iceGatheringState==='complete'){clearTimeout(t);resolve();}});});
    if(window.voiceClosing)throw new Error('closed');return pc.localDescription.sdp;
    """
    private static let applyAnswer = """
    if(window.voiceClosing)throw new Error('closed');const pc=window.voicePC;
    await pc.setRemoteDescription({type:'answer',sdp:answer});
    const ready=()=>!window.voiceClosing&&pc.connectionState==='connected'&&window.voiceChannel.readyState==='open';
    if(!ready())await new Promise(resolve=>{const finish=()=>{clearTimeout(t);clearInterval(i);resolve();};const t=setTimeout(finish,12000);const i=setInterval(()=>{if(ready()||window.voiceClosing||['failed','closed'].includes(pc.connectionState))finish();},50);});
    if(!ready())return 'closed';const audio=document.getElementById('voice-output');if(!audio.srcObject)return 'closed';
    audio.muted=false;const played=await Promise.race([audio.play().then(()=>true).catch(()=>false),new Promise(resolve=>setTimeout(()=>resolve(false),4000))]);
    if(!played||window.voiceClosing){audio.muted=true;audio.pause();return 'closed';}return 'ready';
    """
}

/// Prevent a provider answer from directing ICE to local services. SDP is never interpolated into JS.
enum SubscriptionSDPPolicy {
    static func publicAddress(_ address: String) -> Bool {
        let p = address.split(separator: ".")
        if p.count == 4, p.allSatisfy({ UInt8($0) != nil }) {
            let a = p.map { Int($0)! }
            if a[0] == 0 || a[0] == 10 || a[0] == 127 || a[0] >= 224 { return false }
            if a[0] == 100 && (64...127).contains(a[1]) || a[0] == 169 && a[1] == 254 || a[0] == 172 && (16...31).contains(a[1]) { return false }
            if a[0] == 192 && (a[1] == 168 || a[1] == 0) || a[0] == 198 && (a[1] == 18 || a[1] == 19 || a[1] == 51 && a[2] == 100) || a[0] == 203 && a[1] == 0 && a[2] == 113 { return false }
            return true
        }
        var value = in6_addr(); guard inet_pton(AF_INET6, address, &value) == 1 else { return false }
        let bytes = withUnsafeBytes(of: value) { Array($0) }
        return bytes[0] & 0xE0 == 0x20 && !(bytes[0] == 0x20 && bytes[1] == 1 && bytes[2] == 0x0D && bytes[3] == 0xB8)
    }
    static func accepts(_ sdp: String) -> Bool {
        guard sdp.utf8.count <= 65_536, sdp.hasPrefix("v=0"), sdp.contains("m=audio"), sdp.contains("a=fingerprint:") else { return false }
        var count = 0
        for line in sdp.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("a=candidate:") {
                let f = line.split(whereSeparator: \.isWhitespace)
                guard f.count >= 8, ["udp", "tcp"].contains(f[2].lowercased()), publicAddress(String(f[4])), let port = Int(f[5]), (1...65535).contains(port), f[6] == "typ" else { return false }
                count += 1; if count > 32 { return false }
            } else if line.hasPrefix("c=IN ") {
                let f = line.split(separator: " "); guard f.count == 3 else { return false }
                guard f[2] == "0.0.0.0" || f[2] == "::" || publicAddress(String(f[2])) else { return false }
            }
        }
        return count > 0
    }
}
