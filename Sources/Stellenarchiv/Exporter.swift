import AppKit
import PDFKit
import WebKit

struct ExportResult {
    let title: String
    let pdf: URL
    let markdown: URL
}

enum ExportError: LocalizedError {
    case loadFailed(String)
    case timeout
    case pdfFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed(let m): return "Seite konnte nicht geladen werden: \(m)"
        case .timeout: return "Zeitüberschreitung beim Laden der Seite."
        case .pdfFailed: return "PDF konnte nicht erstellt werden."
        }
    }
}

/// Lädt eine Stellenanzeige in einem unsichtbaren WebView, druckt sie als A4-PDF
/// und erzeugt daraus eine Markdown-Datei für Claude.
@MainActor
final class Exporter: NSObject, WKNavigationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var printContinuation: CheckedContinuation<Bool, Never>?
    private var navigationLocked = false
    private var startURL: URL?

    func export(url: URL, to folder: URL) async throws -> ExportResult {
        let webView = makeWebView()
        defer { tearDown() }

        try await load(url, in: webView)
        startURL = webView.url ?? url

        // Zeit für per JavaScript nachgeladene Inhalte; Cookie-Banner werden parallel
        // vom User-Script (alle Frames) weggeklickt
        try? await Task.sleep(for: .seconds(2))
        var bannerOpen = true
        for _ in 0..<16 {
            bannerOpen = (try? await webView.evaluateJavaScript(PageScripts.consentVisible)) as? Bool ?? false
            if !bannerOpen { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        debug("Consent-Banner noch sichtbar: \(bannerOpen)")
        try? await Task.sleep(for: .milliseconds(600))

        // Ab hier keine Seitenwechsel mehr zulassen (z. B. durch versehentliche Link-Klicks)
        navigationLocked = true

        // „Mehr anzeigen“ aufklappen, Lazy-Loading auslösen
        let expanded1 = try? await webView.callAsyncJavaScript(PageScripts.expand, arguments: [:], in: nil, contentWorld: .page)
        _ = try? await webView.callAsyncJavaScript(Self.scrollScript, arguments: [:], in: nil, contentWorld: .page)
        try? await Task.sleep(for: .seconds(1))
        let expanded2 = try? await webView.callAsyncJavaScript(PageScripts.expand, arguments: [:], in: nil, contentWorld: .page)
        debug("Aufgeklappt: \(expanded1 ?? 0) + \(expanded2 ?? 0)")
        let hidden = try? await webView.evaluateJavaScript("window.__saHideConsent ? window.__saHideConsent() : 0",
                                                          in: nil, contentWorld: .world(name: "stellenarchiv"))
        debug("Banner zusätzlich ausgeblendet: \(hidden ?? "–")")
        _ = try? await webView.evaluateJavaScript(Self.cleanupScript)
        try? await Task.sleep(for: .milliseconds(300))

        // Inhalte extrahieren
        let info = try await extract(from: webView, sourceURL: url)

        // Dateinamen festlegen
        let baseName = Self.fileBaseName(info: info, url: url)
        let pdfURL = Self.uniqueURL(in: folder, base: baseName, ext: "pdf")
        let mdURL = pdfURL.deletingPathExtension().appendingPathExtension("md")

        // PDF
        try await makePDF(webView: webView, to: pdfURL)

        // Markdown
        let md = Self.markdown(info: info, url: url, pdfName: pdfURL.lastPathComponent, pdfURL: pdfURL)
        try md.write(to: mdURL, atomically: true, encoding: .utf8)

        return ExportResult(title: info.title.isEmpty ? baseName : info.title, pdf: pdfURL, markdown: mdURL)
    }

    private func debug(_ msg: String) {
        if ProcessInfo.processInfo.environment["STELLENARCHIV_DEBUG"] != nil { print("DEBUG\t\(msg)") }
    }

    // MARK: - WebView

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // Testmodus: frischer Speicher, damit Cookie-Banner immer erscheinen
        config.websiteDataStore = ProcessInfo.processInfo.environment["STELLENARCHIV_FRESH"] == nil
            ? .default() : .nonPersistent()
        let consent = WKUserScript(source: PageScripts.autoConsent, injectionTime: .atDocumentEnd,
                                   forMainFrameOnly: false, in: .world(name: "stellenarchiv"))
        config.userContentController.addUserScript(consent)
        config.userContentController.add(ConsentLogger(), contentWorld: .world(name: "stellenarchiv"), name: "sa")
        let rect = NSRect(x: 0, y: 0, width: 1100, height: 1400)
        let wv = WKWebView(frame: rect, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        wv.navigationDelegate = self
        // Das Fenster liegt ausserhalb des Bildschirms. Ohne das würde WebKit die Seite als verdeckt
        // behandeln und Animationen/Timer anhalten (Banner, die beim Schliessen animieren, blieben stehen).
        let occlusionSel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if wv.responds(to: occlusionSel) { wv.perform(occlusionSel, with: false) }

        // Ausserhalb des sichtbaren Bereichs, aber "on screen", damit WebKit rendert und druckt
        let win = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = wv
        win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        win.orderFrontRegardless()

        self.window = win
        self.webView = wv
        return wv
    }

    private func tearDown() {
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        navigationLocked = false
        startURL = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        webView = nil
    }

    private func load(_ url: URL, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadContinuation = cont
            var request = URLRequest(url: url)
            request.setValue("de-DE,de;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            webView.load(request)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(40))
                self?.finishLoad(.failure(ExportError.timeout))
            }
        }
    }

    private func finishLoad(_ result: Result<Void, Error>) {
        guard let cont = loadContinuation else { return }
        loadContinuation = nil
        cont.resume(with: result)
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let isMain = navigationAction.targetFrame?.isMainFrame ?? false
        let target = navigationAction.request.url
        MainActor.assumeIsolated {
            guard navigationLocked, isMain, let target, let start = startURL else {
                decisionHandler(.allow); return
            }
            // Nur Sprünge innerhalb derselben Seite (#anker) erlauben
            var a = URLComponents(url: target, resolvingAgainstBaseURL: false); a?.fragment = nil
            var b = URLComponents(url: start, resolvingAgainstBaseURL: false); b?.fragment = nil
            decisionHandler(a?.url == b?.url ? .allow : .cancel)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finishLoad(.success(())) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishLoad(.failure(ExportError.loadFailed(error.localizedDescription))) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishLoad(.failure(ExportError.loadFailed(error.localizedDescription))) }
    }

    // MARK: - PDF

    private func makePDF(webView: WKWebView, to url: URL) async throws {
        // 1. Versuch: echter Druck auf A4 mit Seitenumbrüchen
        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: 595.28, height: 841.89)
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isVerticallyCentered = false
        printInfo.isHorizontallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let op = webView.printOperation(with: printInfo)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = webView.bounds

        if let window {
            _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                printContinuation = cont
                op.runModal(for: window, delegate: self,
                            didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                            contextInfo: nil)
            }
        }

        if Self.pdfLooksValid(at: url) { return }

        // 2. Fallback: eine lange Seite per createPDF
        try? FileManager.default.removeItem(at: url)
        let data = try await webView.pdf(configuration: WKPDFConfiguration())
        try data.write(to: url)
        guard Self.pdfLooksValid(at: url) else { throw ExportError.pdfFailed }
    }

    @objc nonisolated func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in
            self.printContinuation?.resume(returning: success)
            self.printContinuation = nil
        }
    }

    private static func pdfLooksValid(at url: URL) -> Bool {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return false }
        let text = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 50
    }

    // MARK: - Extraktion

    struct PageInfo: Decodable {
        var title: String
        var company: String
        var location: String
        var datePosted: String
        var employmentType: String
        var pageTitle: String
        var markdown: String
    }

    private func extract(from webView: WKWebView, sourceURL: URL) async throws -> PageInfo {
        let raw = try await webView.evaluateJavaScript(Self.extractScript)
        guard let json = raw as? String, let data = json.data(using: .utf8),
              let info = try? JSONDecoder().decode(PageInfo.self, from: data)
        else {
            return PageInfo(title: webView.title ?? "", company: "", location: "", datePosted: "",
                            employmentType: "", pageTitle: webView.title ?? "", markdown: "")
        }
        return info
    }

    // MARK: - Markdown

    private static func markdown(info: PageInfo, url: URL, pdfName: String, pdfURL: URL) -> String {
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let title = info.title.isEmpty ? info.pageTitle : info.title

        var body = info.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.count < 200, let pdfText = PDFDocument(url: pdfURL)?.string {
            // Fallback: Text direkt aus dem PDF
            body = pdfText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func yaml(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }

        var out = "---\n"
        out += "titel: \(yaml(title))\n"
        if !info.company.isEmpty { out += "unternehmen: \(yaml(info.company))\n" }
        if !info.location.isEmpty { out += "ort: \(yaml(info.location))\n" }
        if !info.employmentType.isEmpty { out += "anstellung: \(yaml(info.employmentType))\n" }
        if !info.datePosted.isEmpty { out += "veroeffentlicht: \(yaml(info.datePosted))\n" }
        out += "quelle: \(yaml(url.absoluteString))\n"
        out += "abgerufen: \(today)\n"
        out += "pdf: \(yaml(pdfName))\n"
        out += "---\n\n"
        out += "# \(title)\n\n"

        var facts: [String] = []
        if !info.company.isEmpty { facts.append("- **Unternehmen:** \(info.company)") }
        if !info.location.isEmpty { facts.append("- **Ort:** \(info.location)") }
        if !info.employmentType.isEmpty { facts.append("- **Anstellung:** \(info.employmentType)") }
        if !info.datePosted.isEmpty { facts.append("- **Veröffentlicht:** \(info.datePosted)") }
        facts.append("- **Quelle:** <\(url.absoluteString)>")
        out += facts.joined(separator: "\n") + "\n\n"
        out += "## Stellenanzeige\n\n"
        out += body + "\n"
        return out
    }

    // MARK: - Dateinamen

    private static func fileBaseName(info: PageInfo, url: URL) -> String {
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        var parts: [String] = [date]
        if !info.company.isEmpty { parts.append(info.company) }
        let title = info.title.isEmpty ? info.pageTitle : info.title
        if !title.isEmpty { parts.append(title) } else { parts.append(url.host() ?? "Stellenanzeige") }
        let joined = parts.map(sanitize).filter { !$0.isEmpty }.joined(separator: " – ")
        return String(joined.prefix(150)).trimmingCharacters(in: .whitespaces)
    }

    private static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        return s.components(separatedBy: bad).joined(separator: " ")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }

    private static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    // MARK: - JavaScript

    private static let scrollScript = """
    const h = document.body ? document.body.scrollHeight : 0;
    for (let y = 0; y < Math.min(h, 30000); y += 800) { window.scrollTo(0, y); await new Promise(r => setTimeout(r, 60)); }
    window.scrollTo(0, 0);
    return true;
    """

    /// Blendet gängige Cookie-/Consent-Banner und fixierte Overlays aus.
    private static let cleanupScript = """
    (() => {
      const css = `
        bahf-cd-modal, #bahf-cookie-disclaimer-modal, #onetrust-consent-sdk, #onetrust-banner-sdk, #usercentrics-root, #usercentrics-cmp-ui,
        #CybotCookiebotDialog, #CybotCookiebotDialogBodyUnderlay, #didomi-host, .fc-consent-root,
        #sp_message_container, [id^="sp_message_container"], #cmpbox, #cmpbox2, .cmpboxBG,
        .cc-window, .cc-banner, #truste-consent-track, #gdpr-cookie-message, #cookie-law-info-bar,
        #cookie-notice, .cookie-notice, #cookiebanner, .cookie-banner, #cookie-banner,
        #borlabs-cookie, .borlabs-cookie, #BorlabsCookieBox, .klaro, #klaro, #consent-banner,
        .consent-banner, #CookieConsent, .cookieconsent, #ccm-widget, .ot-sdk-container,
        [aria-label*="cookie" i][role="dialog"], [aria-label*="consent" i][role="dialog"]
        { display: none !important; }
        html, body { overflow: visible !important; height: auto !important; position: static !important; }
      `;
      const st = document.createElement('style'); st.textContent = css; document.head.appendChild(st);
      // Fixierte Elemente (Sticky-Header, Chat-Widgets) würden auf jeder PDF-Seite erscheinen
      for (const el of document.querySelectorAll('body *')) {
        const cs = getComputedStyle(el);
        if (cs.position === 'fixed' || cs.position === 'sticky') {
          if (cs.position === 'sticky') el.style.setProperty('position', 'static', 'important');
          else el.style.setProperty('display', 'none', 'important');
        }
      }
      return true;
    })();
    """

    /// Liest JSON-LD (schema.org/JobPosting) und wandelt die Anzeige in Markdown um.
    private static let extractScript = #"""
    (() => {
      const txt = s => (s || '').replace(/\s+/g, ' ').trim();

      // --- JSON-LD JobPosting ---
      let jp = null;
      const isJob = x => x && (x['@type'] === 'JobPosting' || (Array.isArray(x['@type']) && x['@type'].includes('JobPosting')));
      for (const s of document.querySelectorAll('script[type="application/ld+json"]')) {
        try {
          const d = JSON.parse(s.textContent);
          const stack = [d];
          while (stack.length && !jp) {
            const x = stack.pop();
            if (Array.isArray(x)) { stack.push(...x); continue; }
            if (!x || typeof x !== 'object') continue;
            if (isJob(x)) { jp = x; break; }
            if (x['@graph']) stack.push(x['@graph']);
          }
        } catch (e) {}
        if (jp) break;
      }

      // --- HTML -> Markdown ---
      const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','SVG','NAV','FOOTER','ASIDE','BUTTON','FORM','IFRAME','SELECT','INPUT','TEXTAREA','DIALOG','TEMPLATE','CANVAS','VIDEO','AUDIO','PICTURE','IMG']);
      const BLOCK = new Set(['P','DIV','SECTION','ARTICLE','MAIN','HEADER','UL','OL','LI','H1','H2','H3','H4','H5','H6','TABLE','TR','BLOCKQUOTE','DL','DT','DD','FIGURE','PRE','HR','BR']);
      const hidden = el => {
        if (!el.isConnected || !el.ownerDocument.defaultView) return false;
        const cs = el.ownerDocument.defaultView.getComputedStyle(el);
        return cs.display === 'none' || cs.visibility === 'hidden';
      };
      const inline = (node) => {
        let out = '';
        for (const c of node.childNodes) {
          if (c.nodeType === 3) { out += c.textContent.replace(/\s+/g, ' '); continue; }
          if (c.nodeType !== 1 || SKIP.has(c.tagName) || hidden(c)) continue;
          const t = c.tagName;
          if (t === 'BR') { out += '\n'; continue; }
          const inner = inline(c);
          if (!inner.trim()) continue;
          if (t === 'STRONG' || t === 'B') out += ' **' + inner.trim() + '** ';
          else if (t === 'EM' || t === 'I') out += ' *' + inner.trim() + '* ';
          else if (t === 'A' && c.getAttribute('href') && /^https?:|^mailto:/.test(c.href)) out += '[' + inner.trim() + '](' + c.href + ')';
          else out += inner;
        }
        return out;
      };
      const hasBlockChild = el => [...el.children].some(c => BLOCK.has(c.tagName));
      const blocks = [];
      const walk = (el, depth) => {
        for (const c of el.childNodes) {
          if (c.nodeType === 3) {
            const t = txt(c.textContent);
            if (t) blocks.push(t);
            continue;
          }
          if (c.nodeType !== 1 || SKIP.has(c.tagName) || hidden(c)) continue;
          const t = c.tagName;
          if (/^H[1-6]$/.test(t)) {
            const level = Math.min(6, Math.max(3, +t[1] + 1));
            const s = txt(c.textContent);
            if (s) blocks.push('#'.repeat(level) + ' ' + s);
          } else if (t === 'UL' || t === 'OL') {
            let i = 1;
            const items = [];
            for (const li of c.children) {
              if (li.tagName !== 'LI' || hidden(li)) continue;
              const nested = [...li.children].filter(x => x.tagName === 'UL' || x.tagName === 'OL');
              const clone = li.cloneNode(true);
              clone.querySelectorAll('ul,ol').forEach(n => n.remove());
              const s = txt(inline(clone));
              if (s) items.push('  '.repeat(depth) + (t === 'OL' ? (i++) + '. ' : '- ') + s);
              for (const n of nested) { const save = blocks.length; walk({childNodes: [n]}, depth + 1); items.push(...blocks.splice(save)); }
            }
            if (items.length) blocks.push(items.join('\n'));
          } else if (t === 'TABLE') {
            const rows = [...c.querySelectorAll('tr')].map(r => [...r.children].map(td => txt(td.textContent).replace(/\|/g, '/')));
            if (rows.length) {
              const w = Math.max(...rows.map(r => r.length));
              const line = r => '| ' + Array.from({length: w}, (_, i) => r[i] || '').join(' | ') + ' |';
              blocks.push([line(rows[0]), '|' + ' --- |'.repeat(w), ...rows.slice(1).map(line)].join('\n'));
            }
          } else if (t === 'HR') {
            blocks.push('---');
          } else if (t === 'DT') {
            const s = txt(c.textContent); if (s) blocks.push('**' + s + '**');
          } else if (t === 'P' || t === 'DD' || t === 'BLOCKQUOTE' || t === 'LI' || ((t === 'DIV' || t === 'SPAN' || t === 'SECTION') && !hasBlockChild(c))) {
            const s = inline(c).split('\n').map(txt).filter(Boolean).join('  \n')
              .replace(/\*\*\s*\*\*/g, '').replace(/ +([.,;:!?])/g, '$1');
            if (s) blocks.push(t === 'BLOCKQUOTE' ? '> ' + s : s);
          } else {
            walk(c, depth);
          }
        }
      };
      const toMd = root => {
        blocks.length = 0;
        walk(root, 0);
        const seen = new Set();
        return blocks.filter(b => { if (b.length > 40 && seen.has(b)) return false; seen.add(b); return true; })
          .join('\n\n').replace(/\n{3,}/g, '\n\n').replace(/\*\* +([.,;:!?)])/g, '**$1').replace(/ {2,}(?!\n)/g, ' ').trim();
      };

      let markdown = '';
      if (jp && jp.description) {
        let html = String(jp.description);
        // Manche Seiten liefern das HTML entity-kodiert (&lt;li&gt;) – erst dekodieren
        if (/&lt;\/?[a-z]/i.test(html) && !/<\/?(p|li|ul|br|div|strong)\b/i.test(html)) {
          const ta = document.createElement('textarea'); ta.innerHTML = html; html = ta.value;
        }
        const doc = new DOMParser().parseFromString('<div>' + html + '</div>', 'text/html');
        markdown = toMd(doc.body);
      }
      if (markdown.length < 300) {
        // Hauptinhalt finden: Kandidat mit dem meisten Text
        const cands = [...document.querySelectorAll('article, main, [role="main"], [class*="job" i][class*="description" i], [class*="jobad" i], [id*="job" i][id*="description" i], [class*="stellen" i]')]
          .filter(e => !hidden(e) && e.innerText && e.innerText.length > 400);
        cands.sort((a, b) => b.innerText.length - a.innerText.length);
        const root = cands[0] || document.body;
        markdown = toMd(root);
      }

      const org = jp && jp.hiringOrganization;
      const loc = jp && jp.jobLocation;
      const locOf = l => {
        if (!l) return '';
        const a = l.address || l;
        if (typeof a === 'string') return a;
        return [a.postalCode, a.addressLocality, a.addressRegion && a.addressRegion !== a.addressLocality ? a.addressRegion : '', a.addressCountry && typeof a.addressCountry === 'string' && a.addressCountry.length > 2 ? a.addressCountry : '']
          .filter(Boolean).join(' ').trim();
      };
      const locations = (Array.isArray(loc) ? loc : [loc]).map(locOf).filter(Boolean);
      const etype = jp && jp.employmentType ? [].concat(jp.employmentType).join(', ') : '';
      const h1 = document.querySelector('h1');

      return JSON.stringify({
        title: txt(jp && jp.title) || txt(h1 && h1.innerText) || '',
        company: txt(org && (typeof org === 'string' ? org : org.name)) || '',
        location: [...new Set(locations)].join('; '),
        datePosted: txt(jp && jp.datePosted ? String(jp.datePosted).slice(0, 10) : ''),
        employmentType: etype,
        pageTitle: txt(document.title),
        markdown
      });
    })();
    """#
}

/// Protokolliert Consent-Klicks (nur mit STELLENARCHIV_DEBUG sichtbar).
final class ConsentLogger: NSObject, WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if ProcessInfo.processInfo.environment["STELLENARCHIV_DEBUG"] != nil {
            print("DEBUG\tCookie-Banner geklickt: \(message.body)")
        }
    }
}
