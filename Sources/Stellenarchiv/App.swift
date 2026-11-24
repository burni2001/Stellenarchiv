import AppKit
import SwiftUI

@main
struct StellenarchivApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Stellenarchiv", id: "main") {
            ContentView()
                .frame(minWidth: 560, idealWidth: 620, minHeight: 560, idealHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Über Stellenarchiv") { AppDelegate.showAbout() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Screenshot fürs README: STELLENARCHIV_SNAPSHOT=<datei.png> (zusammen mit STELLENARCHIV_DEMO)
        if let shot = ProcessInfo.processInfo.environment["STELLENARCHIV_SNAPSHOT"] {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                      let view = win.contentView else { exit(1) }
                win.setContentSize(NSSize(width: 640, height: 660))
                try? await Task.sleep(for: .seconds(1))
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shot))
                exit(0)
            }
        }

        // Testmodus: Stellenarchiv --export <url> <ordner>
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export"), args.count > i + 2,
           let url = URL(string: args[i + 1]) {
            let folder = URL(fileURLWithPath: args[i + 2], isDirectory: true)
            Task { @MainActor in
                do {
                    let r = try await Exporter().export(url: url, to: folder)
                    print("OK\t\(r.pdf.path)\t\(r.markdown.path)")
                    exit(0)
                } catch {
                    print("FEHLER\t\(error.localizedDescription)")
                    exit(1)
                }
            }
        }
    }

    static func showAbout() {
        let credits = NSMutableAttributedString()
        let center = NSMutableParagraphStyle(); center.alignment = .center
        func add(_ s: String, _ font: NSFont, _ color: NSColor = .labelColor, link: URL? = nil) {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: center]
            if let link { attrs[.link] = link }
            credits.append(NSAttributedString(string: s, attributes: attrs))
        }
        add("Stellenanzeigen als PDF + Markdown sichern.\n\n", .systemFont(ofSize: 11), .secondaryLabelColor)
        add("Erstellt von ", .systemFont(ofSize: 11))
        add("Börni (burni2001)", .boldSystemFont(ofSize: 11), link: URL(string: "https://github.com/burni2001"))
        add("\n", .systemFont(ofSize: 11))
        add("github.com/burni2001/Stellenarchiv", .systemFont(ofSize: 11), link: URL(string: "https://github.com/burni2001/Stellenarchiv"))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Stellenarchiv",
            .credits: credits,
            .init(rawValue: "Copyright"): "© 2026 Börni (burni2001)",
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct HistoryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var pdfPath: String
    var url: String?          // Original-Link (ältere Einträge haben keinen)
    var date: Date

    var pdfURL: URL { URL(fileURLWithPath: pdfPath) }
    var markdownURL: URL { pdfURL.deletingPathExtension().appendingPathExtension("md") }
    var sourceURL: URL? { url.flatMap(URL.init(string:)) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var input = ""
    @Published var isWorking = false
    @Published var status = ""
    @Published var statusIsError = false
    @Published var folder: URL? {
        didSet { Self.store.set(folder?.path, forKey: "exportFolder") }
    }
    @Published var history: [HistoryItem] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(history) {
                Self.store.set(data, forKey: "history")
            }
        }
    }

    private let exporter = Exporter()

    /// Demo-Modus (STELLENARCHIV_DEMO=1): eigener Speicher mit Beispieldaten, z. B. für Screenshots.
    static let isDemo = ProcessInfo.processInfo.environment["STELLENARCHIV_DEMO"] != nil
    static let store: UserDefaults = isDemo
        ? UserDefaults(suiteName: "io.github.burni2001.stellenarchiv.demo")! : .standard

    init() {
        if Self.isDemo { Self.seedDemo() }
        if let path = Self.store.string(forKey: "exportFolder") {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        }
        if let data = Self.store.data(forKey: "history"),
           let items = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = Self.backfillURLs(items)
            // didSet greift im init nicht – nachgetragene Links direkt speichern
            if history != items, let data = try? JSONEncoder().encode(history) {
                Self.store.set(data, forKey: "history")
            }
        }
    }

    /// Alle http(s)-Links aus dem Eingabefeld (mehrere möglich).
    var urls: [URL] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(input.startIndex..., in: input)
        let found = detector?.matches(in: input, range: range).compactMap(\.url) ?? []
        return found.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Auswählen"
        panel.message = "Ordner für exportierte Stellenanzeigen wählen"
        if let folder { panel.directoryURL = folder }
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
        }
    }

    func pasteFromClipboard() {
        if let s = NSPasteboard.general.string(forType: .string) {
            input = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func export() {
        let targets = urls
        guard !targets.isEmpty, !isWorking else { return }
        if folder == nil { chooseFolder() }
        guard let folder else { return }

        isWorking = true
        statusIsError = false
        Task {
            var ok = 0
            var errors: [String] = []
            for (i, url) in targets.enumerated() {
                status = targets.count > 1
                    ? "Exportiere \(i + 1) von \(targets.count) … \(url.host() ?? "")"
                    : "Lade \(url.host() ?? url.absoluteString) …"
                do {
                    let result = try await exporter.export(url: url, to: folder)
                    history.insert(HistoryItem(title: result.title, pdfPath: result.pdf.path,
                                               url: url.absoluteString, date: Date()), at: 0)
                    if history.count > 100 { history.removeLast(history.count - 100) }
                    ok += 1
                } catch {
                    errors.append("\(url.host() ?? ""): \(error.localizedDescription)")
                }
            }
            isWorking = false
            if errors.isEmpty {
                status = ok == 1 ? "Gespeichert: PDF und Markdown." : "\(ok) Anzeigen gespeichert."
                statusIsError = false
                input = ""
            } else {
                status = errors.joined(separator: "\n")
                statusIsError = true
            }
        }
    }

    func reveal(_ item: HistoryItem) {
        let url = URL(fileURLWithPath: item.pdfPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            status = "Datei nicht mehr vorhanden."
            statusIsError = true
        }
    }

    func open(_ item: HistoryItem) {
        NSWorkspace.shared.open(item.pdfURL)
    }

    /// Entfernt Einträge aus dem Verlauf; auf Wunsch landen PDF und Markdown im Papierkorb.
    func delete(_ ids: Set<HistoryItem.ID>, trashFiles: Bool) {
        var failed = 0
        if trashFiles {
            for item in history where ids.contains(item.id) {
                for file in [item.pdfURL, item.markdownURL] where FileManager.default.fileExists(atPath: file.path) {
                    do { try FileManager.default.trashItem(at: file, resultingItemURL: nil) } catch { failed += 1 }
                }
            }
        }
        let n = ids.count
        history.removeAll { ids.contains($0.id) }
        statusIsError = failed > 0
        if failed > 0 {
            status = "\(failed) Datei(en) konnten nicht in den Papierkorb gelegt werden."
        } else {
            let what = n == 1 ? "1 Eintrag" : "\(n) Einträge"
            status = trashFiles ? "\(what) entfernt, Dateien im Papierkorb." : "\(what) aus dem Verlauf entfernt."
        }
    }

    /// Ältere Einträge haben keinen Original-Link gespeichert – er steht aber als
    /// `quelle:` in den Kopfdaten der Markdown-Datei daneben.
    private static func backfillURLs(_ items: [HistoryItem]) -> [HistoryItem] {
        items.map { item in
            guard item.url == nil else { return item }
            let text: String
            do { text = try String(contentsOf: item.markdownURL, encoding: .utf8) }
            catch { NSLog("Stellenarchiv: Link-Nachtrag fehlgeschlagen: %@", error.localizedDescription); return item }
            for line in text.split(separator: "\n").prefix(20) where line.hasPrefix("quelle:") {
                var value = line.dropFirst("quelle:".count).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                        .replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\\\", with: "\\")
                }
                guard let url = URL(string: value), url.scheme?.hasPrefix("http") == true else { break }
                var fixed = item
                fixed.url = url.absoluteString
                return fixed
            }
            return item
        }
    }

    private static func seedDemo() {
        guard store.data(forKey: "history") == nil else { return }
        let folder = NSHomeDirectory() + "/Documents/Stellenanzeigen"
        store.set(folder, forKey: "exportFolder")
        let now = Date()
        let demo: [(String, String, String, Double)] = [
            ("Product Owner E-Commerce (m/w/d)", "Musterhandel GmbH", "https://www.stepstone.de/stellenangebote--Product-Owner-Beispiel.html", 0.4),
            ("Leitung Marketing & Kommunikation", "Beispiel AG", "https://www.jobs.ch/de/stellenangebote/detail/beispiel/", 26),
            ("UX Designer:in", "Studio Nord", "https://de.linkedin.com/jobs/view/ux-designer-beispiel", 50),
            ("Projektmanager Digitalisierung (m/w/d)", "Stadtwerke Musterstadt", "https://www.arbeitsagentur.de/jobsuche/jobdetail/beispiel", 74),
        ]
        let items = demo.map { title, company, url, hours in
            HistoryItem(title: title, pdfPath: "\(folder)/2026-11-24 – \(company) – \(title).pdf",
                        url: url, date: now.addingTimeInterval(-hours * 3600))
        }
        if let data = try? JSONEncoder().encode(items) { store.set(data, forKey: "history") }
    }
}
