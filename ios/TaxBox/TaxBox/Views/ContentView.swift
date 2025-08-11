import SwiftUI
import QuickLookThumbnailing

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSheet = false
    @State private var dropped: [URL] = []
    @State private var draft = DraftMeta.from(urls: [])
    @State private var isManualAdd = false

    var body: some View {
        NavigationSplitView {
            Sidebar()
        } detail: {
            VStack(spacing: 0) {
                Toolbar(onAddPlaceholder: startManualAdd)
                TableView()
                Footer()
            }
            .dropDestination(for: URL.self) { items, _ in
                dropped = items
                draft = DraftMeta.from(urls: items)
                draft.status = "Done" // Files you already have are typically done
                isManualAdd = false
                showSheet = true
                return true
            }
            .sheet(isPresented: $showSheet) {
                ImportSheet(urls: dropped, draft: $draft, isManualAdd: isManualAdd) { confirmed in
                    if confirmed { 
                        if isManualAdd {
                            model.createPlaceholder(with: draft)
                        } else {
                            model.importURLs(dropped, with: draft) 
                        }
                    }
                    showSheet = false
                }
                .frame(width: isManualAdd ? 400 : 600, height: 400)
            }
        }
    }
    
    func startManualAdd() {
        dropped = []
        draft = DraftMeta.from(urls: [])
        draft.status = "Todo" // Placeholders default to todo
        isManualAdd = true
        showSheet = true
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            Section("Years") {
                FilterRow(title: "All Years", isSelected: model.selectedYear == nil) {
                    model.selectedYear = nil
                }
                ForEach(model.years, id: \.self) { year in
                    FilterRow(title: String(year), isSelected: model.selectedYear == year) {
                        model.selectedYear = year
                    }
                }
            }
            Section("Status") {
                FilterRow(title: "All Statuses", isSelected: model.statusFilter == nil) {
                    model.statusFilter = nil
                }
                ForEach(model.availableStatuses, id: \.self) { status in 
                    FilterRow(title: status, isSelected: model.statusFilter == status) {
                        model.statusFilter = status
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct FilterRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(isSelected ? .white : .primary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.white)
                    .font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture {
            action()
        }
    }
}

struct Toolbar: View {
    @EnvironmentObject var model: AppModel
    let onAddPlaceholder: () -> Void
    
    var body: some View {
        HStack {
            TextField("Search", text: $model.query)
            
            if model.selectedYear != nil {
                HStack(spacing: 4) {
                    Image(systemName: "calendar.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text(String(model.selectedYear!))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(action: { model.selectedYear = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)
            }
            
            if model.statusFilter != nil {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text(model.statusFilter!)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(action: { model.statusFilter = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)
            }
            
            Spacer()
            
            Button(action: onAddPlaceholder) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
            }
            .help("Add document placeholder")
            
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
                    ForEach(model.availableStatuses, id: \.self) { status in
                        Text(status).tag(status)
                    }
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

struct AmountField: View { 
    @Binding var value: Double
    var body: some View { 
        TextField("$0.00", value: $value, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
            .multilineTextAlignment(.trailing) 
    } 
}

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