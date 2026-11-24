import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HeaderBand()

            VStack(alignment: .leading, spacing: 22) {
                // LINK
                VStack(alignment: .leading, spacing: 11) {
                    SectionHeading(title: "Link zur Stellenanzeige")
                    HStack(spacing: 8) {
                        TextField("https://…", text: $model.input)
                            .textFieldStyle(.plain)
                            .font(CD.body)
                            .foregroundStyle(CD.gray900)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.white)
                            .overlay(Rectangle().stroke(fieldFocused ? CD.forest600 : CD.gray500.opacity(0.5),
                                                        lineWidth: fieldFocused ? 2 : 1))
                            .focused($fieldFocused)
                            .onSubmit { model.export() }
                            .disabled(model.isWorking)
                        Button("Einfügen") { model.pasteFromClipboard() }
                            .buttonStyle(CDButtonStyle(prominent: false))
                            .disabled(model.isWorking)
                    }
                    HStack(spacing: 12) {
                        Button {
                            model.export()
                        } label: {
                            HStack(spacing: 8) {
                                if model.isWorking {
                                    ProgressView().controlSize(.small).tint(.white)
                                }
                                Text(model.isWorking ? "Exportiere …" : "Als PDF + Markdown sichern")
                            }
                        }
                        .buttonStyle(CDButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.urls.isEmpty || model.isWorking)

                        if !model.status.isEmpty {
                            Text(model.status)
                                .font(CD.meta)
                                .foregroundStyle(model.statusIsError ? Color(hex: 0xB42318) : CD.gray500)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                }

                // ORDNER
                VStack(alignment: .leading, spacing: 11) {
                    SectionHeading(title: "Zielordner")
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.folder?.lastPathComponent ?? "Noch kein Ordner gewählt")
                                .font(CD.roleTitle)
                                .foregroundStyle(CD.gray900)
                            Text(model.folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Wird beim ersten Export abgefragt")
                                .font(CD.inter(12).italic())
                                .foregroundStyle(CD.gray500)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if let folder = model.folder {
                            Button("Öffnen") { NSWorkspace.shared.open(folder) }
                                .buttonStyle(CDButtonStyle(prominent: false))
                        }
                        Button("Ändern …") { model.chooseFolder() }
                            .buttonStyle(CDButtonStyle(prominent: false))
                            .disabled(model.isWorking)
                    }
                }

                // VERLAUF
                HistorySection(model: model)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CD.paper)
        }
        .background(CD.paper)
        .ignoresSafeArea(edges: .top)
        .environment(\.colorScheme, .light)
        .onAppear { fieldFocused = true }
    }
}

// MARK: - Verlauf

struct HistorySection: View {
    @ObservedObject var model: AppModel
    @State private var editing = false
    @State private var selection = Set<HistoryItem.ID>()
    @State private var pendingDelete = Set<HistoryItem.ID>()
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ZStack(alignment: .topTrailing) {
                SectionHeading(title: "Zuletzt gesichert")
                if !model.history.isEmpty {
                    Button(editing ? "Fertig" : "Bearbeiten") {
                        editing.toggle()
                        selection.removeAll()
                    }
                    .buttonStyle(TextLinkButtonStyle())
                }
            }

            if editing {
                HStack(spacing: 10) {
                    Button(selection.count == model.history.count ? "Keine auswählen" : "Alle auswählen") {
                        selection = selection.count == model.history.count ? [] : Set(model.history.map(\.id))
                    }
                    .buttonStyle(CDButtonStyle(prominent: false))
                    Button(selection.isEmpty ? "Löschen …" : "\(selection.count) löschen …") {
                        ask(selection)
                    }
                    .buttonStyle(CDButtonStyle())
                    .disabled(selection.isEmpty)
                    Spacer()
                }
            }

            if model.history.isEmpty {
                Text("Noch keine Stellenanzeigen gesichert.")
                    .font(CD.body)
                    .foregroundStyle(CD.gray500)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.history) { item in
                            HistoryRow(item: item,
                                       editing: editing,
                                       selected: selection.contains(item.id),
                                       toggle: { toggle(item.id) },
                                       open: { model.open(item) },
                                       reveal: { model.reveal(item) },
                                       delete: { ask([item.id]) })
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .confirmationDialog(dialogTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Nur aus dem Verlauf entfernen") { finish(trash: false) }
            Button("Auch PDF + Markdown in den Papierkorb", role: .destructive) { finish(trash: true) }
            Button("Abbrechen", role: .cancel) { pendingDelete.removeAll() }
        } message: {
            Text("Dateien im Papierkorb lassen sich im Finder wiederherstellen.")
        }
        .onChange(of: model.history) { _, new in
            let ids = Set(new.map(\.id))
            selection = selection.intersection(ids)
            if new.isEmpty { editing = false }
        }
    }

    private var dialogTitle: String {
        pendingDelete.count == 1 ? "Eintrag löschen?" : "\(pendingDelete.count) Einträge löschen?"
    }

    private func toggle(_ id: HistoryItem.ID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func ask(_ ids: Set<HistoryItem.ID>) {
        guard !ids.isEmpty else { return }
        pendingDelete = ids
        confirmDelete = true
    }

    private func finish(trash: Bool) {
        model.delete(pendingDelete, trashFiles: trash)
        selection.subtract(pendingDelete)
        pendingDelete.removeAll()
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    let editing: Bool
    let selected: Bool
    let toggle: () -> Void
    let open: () -> Void
    let reveal: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM.yyyy, HH:mm"
        return f
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if editing {
                CheckBox(on: selected)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(CD.inter(13, .bold))
                    .foregroundStyle(CD.gray900)
                    .lineLimit(1)
                    .help(item.pdfURL.lastPathComponent)
                HStack(spacing: 6) {
                    if let src = item.sourceURL {
                        Link(destination: src) {
                            Text(Self.shortHost(src) + " ↗")
                                .font(CD.inter(12))
                                .underline()
                                .foregroundStyle(CD.forest800)
                        }
                        .help(src.absoluteString)
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                        Text("·").font(CD.meta).foregroundStyle(CD.gray500)
                    }
                    Text(Self.dateFormat.string(from: item.date))
                        .font(CD.meta)
                        .foregroundStyle(CD.gray500)
                }
            }
            Spacer(minLength: 12)
            if !editing && hovering {
                Button("Löschen") { delete() }
                    .buttonStyle(TextLinkButtonStyle(color: CD.gray500))
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        .background(selected ? CD.forest500.opacity(0.10) : (hovering ? CD.gray500.opacity(0.06) : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(CD.gray500.opacity(0.15)).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if !editing { open() } }
        .onTapGesture { if editing { toggle() } }
        .contextMenu {
            Button("PDF öffnen") { open() }
            Button("Im Finder zeigen") { reveal() }
            if let src = item.sourceURL {
                Button("Original-Anzeige öffnen") { NSWorkspace.shared.open(src) }
                Button("Link kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(src.absoluteString, forType: .string)
                }
            }
            Divider()
            Button("Löschen …", role: .destructive) { delete() }
        }
    }

    private static func shortHost(_ url: URL) -> String {
        let h = url.host() ?? url.absoluteString
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

/// Eckige Checkbox im CD-Stil.
struct CheckBox: View {
    let on: Bool
    var body: some View {
        ZStack {
            Rectangle().fill(on ? CD.forest800 : .white)
            Rectangle().stroke(on ? CD.forest800 : CD.gray500, lineWidth: 1.5)
            if on {
                Path { p in
                    p.move(to: CGPoint(x: 4, y: 8.5)); p.addLine(to: CGPoint(x: 7, y: 11.5)); p.addLine(to: CGPoint(x: 12, y: 4.5))
                }
                .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .square))
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// Unauffälliger Text-Button (z. B. „Bearbeiten“, „Löschen“).
struct TextLinkButtonStyle: ButtonStyle {
    var color: Color = CD.forest800
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CD.inter(12, .bold))
            .foregroundStyle(color)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}
