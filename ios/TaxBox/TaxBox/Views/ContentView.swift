import SwiftUI
import QuickLookThumbnailing

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSheet = false
    @State private var dropped: [URL] = []
    @State private var draft = DraftMeta.from(urls: [])

    var body: some View {
        NavigationSplitView {
            Sidebar()
        } detail: {
            VStack(spacing: 0) {
                Toolbar()
                TableView()
                Footer()
            }
            .dropDestination(for: URL.self) { items, _ in
                dropped = items
                draft = DraftMeta.from(urls: items)
                showSheet = true
                return true
            }
            .sheet(isPresented: $showSheet) {
                ImportSheet(urls: dropped, draft: $draft) { confirmed in
                    if confirmed { model.importURLs(dropped, with: draft) }
                    showSheet = false
                }
                .frame(width: 460)
            }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List(selection: $model.selectedYear) {
            Section("Years") {
                ForEach(model.years, id: \.self) { y in Text(String(y)) }
            }
            Section("Status") {
                ButtonLabelFilter(title: "All") { model.statusFilter = nil }
                ForEach(DocStatus.allCases) { s in ButtonLabelFilter(title: s.rawValue) { model.statusFilter = s } }
            }
        }
        .listStyle(.sidebar)
    }
}

struct ButtonLabelFilter: View { let title: String; let action: () -> Void; var body: some View { Button(action: action) { Text(title) }.buttonStyle(.plain) } }

struct Toolbar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack {
            TextField("Search", text: $model.query)
            Spacer()
            Button("Open Folder") { model.openRootInFinder() }
        }
        .padding(8)
        .background(.bar)
    }
}

struct TableView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection = Set<DocumentItem.ID>()

    var body: some View {
        Table(model.filteredItems(), selection: $selection) {
            TableColumn("Name") { item in
                TextField("Name", text: Binding(get: { item.meta.name }, set: { v in var m = item; m.meta.name = v; model.update(m) }))
            }.width(min: 160)

            TableColumn("Amount") { item in
                AmountField(value: Binding(get: { item.meta.amount ?? 0 }, set: { v in var m = item; m.meta.amount = v == 0 ? nil : v; model.update(m) }))
            }.width(100)

            TableColumn("Notes") { item in
                TextField("Notes", text: Binding(get: { item.meta.notes }, set: { v in var m = item; m.meta.notes = v; model.update(m) }))
            }

            TableColumn("Status") { item in
                Picker("", selection: Binding(get: { item.meta.status }, set: { v in var m = item; m.meta.status = v; model.update(m) })) {
                    ForEach(DocStatus.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden()
            }.width(120)

            TableColumn("File") { item in
                HStack {
                    ThumbnailView(url: item.url)
                    Button(item.filename) { NSWorkspace.shared.open(item.url) }
                        .buttonStyle(.link)
                }
            }
        }
        .contextMenu {
            if !selection.isEmpty {
                Button("Delete \(selection.count) item(s)") {
                    let itemsToDelete = model.filteredItems().filter { selection.contains($0.id) }
                    model.deleteItems(Set(itemsToDelete))
                    selection.removeAll()
                }
                Divider()
                Button("Open in Finder") {
                    let itemsToOpen = model.filteredItems().filter { selection.contains($0.id) }
                    for item in itemsToOpen {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                }
            }
        }
    }
}

struct Footer: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack {
            Text("Total: \(model.totalAmount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))")
            Spacer()
            Text("\(model.filteredItems().count) items")
        }
        .padding(8)
        .background(.thinMaterial)
    }
}

struct AmountField: View { @Binding var value: Double; var body: some View { TextField("0", value: $value, format: .number).multilineTextAlignment(.trailing) } }

struct ThumbnailView: View {
    let url: URL
    @State private var image: NSImage? = nil
    @State private var hasLoaded = false
    
    var body: some View {
        Group { 
            if let image { 
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) 
            } else { 
                Rectangle().opacity(0.08) 
            } 
        }
        .frame(width: 28, height: 36)
        .onAppear { 
            if !hasLoaded {
                genThumb()
                hasLoaded = true
            }
        }
    }
    
    func genThumb() {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 72, height: 72), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            DispatchQueue.main.async {
                if let cg = rep?.cgImage { 
                    self.image = NSImage(cgImage: cg, size: .zero) 
                }
            }
        }
    }
}