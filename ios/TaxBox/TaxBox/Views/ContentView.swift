import SwiftUI
import QuickLookThumbnailing

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSheet = false
    @State private var showCameraSheet = false
    @State private var dropped: [URL] = []
    @State private var draft = DraftMeta.from(urls: [])
    @State private var isManualAdd = false

    var body: some View {
        NavigationSplitView {
            Sidebar()
        } detail: {
            VStack(spacing: 0) {
                Toolbar(onAddPlaceholder: startManualAdd, onScanDocument: startCameraScan)
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
            .sheet(isPresented: $model.showingCSVImport) {
                ImportCSVSheet(isPresented: $model.showingCSVImport)
            }
            .sheet(isPresented: $showCameraSheet) {
                SimpleCameraView { capturedURLs in
                    // Handle captured documents
                    if !capturedURLs.isEmpty {
                        // Smoothly transition from camera to import sheet
                        dropped = capturedURLs
                        draft = DraftMeta.from(urls: capturedURLs)
                        
                        // Intelligent naming based on count
                        let timestamp = DateFormatter.shortDateTime.string(from: Date())
                        draft.name = capturedURLs.count == 1 
                            ? "Scanned Document \(timestamp)"
                            : "\(capturedURLs.count) Scanned Documents \(timestamp)"
                        
                        // Default status for camera documents
                        draft.status = "Done" // Camera scanned documents are complete files
                        isManualAdd = false
                        
                        // Close camera sheet and open import sheet smoothly
                        showCameraSheet = false
                        
                        // Small delay to allow camera sheet to close before opening import sheet
                        Task {
                            try? await Task.sleep(for: .milliseconds(200))
                            await MainActor.run {
                                showSheet = true
                            }
                        }
                    }
                }
                .interactiveDismissDisabled() // Prevent accidental dismissal during capture
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
    
    func startCameraScan() {
        // Ensure we're in a clean state before starting camera
        dropped = []
        draft = DraftMeta.from(urls: [])
        showCameraSheet = true
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
    let onScanDocument: () -> Void
    
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
            
            Button(action: onScanDocument) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 16))
            }
            .help("Scan document with camera")
            
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
                FileAttachmentCell(item: item)
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
                
                if model.filteredItems().filter({ selection.contains($0.id) }).contains(where: { $0.isDownloading }) {
                    Divider()
                    Button("Download from iCloud") {
                        let itemsToDownload = model.filteredItems().filter { selection.contains($0.id) && $0.isDownloading }
                        for item in itemsToDownload {
                            model.triggerDownload(for: item.url)
                        }
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
    var isOffloaded: Bool = false
    @State private var image: NSImage? = nil
    @State private var hasLoaded = false
    @EnvironmentObject var model: AppModel
    
    var isPlaceholder: Bool {
        url.lastPathComponent.hasSuffix(".placeholder")
    }
    
    var body: some View {
        Group { 
            if let image { 
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) 
            } else if isOffloaded {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if isPlaceholder {
                Image(systemName: "doc.badge.plus")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else { 
                Rectangle().opacity(0.08) 
            } 
        }
        .frame(width: 28, height: 36)
        .onAppear { 
            if !hasLoaded && !isOffloaded && !isPlaceholder {
                genThumb()
                hasLoaded = true
            }
        }
    }
    
    func genThumb() {
        Task {
            // Check if file is available locally before generating thumbnail
            do {
                let resourceValues = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                if let status = resourceValues.ubiquitousItemDownloadingStatus {
                    if status == .notDownloaded {
                        // Don't generate thumbnail for offloaded files
                        return
                    }
                    // .downloaded, .downloading, and .current are all fine for thumbnail generation
                }
            } catch {
                // Proceed with thumbnail generation if we can't check status
            }
            
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 72, height: 72), scale: 2, representationTypes: .thumbnail)
            
            do {
                let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: req)
                await MainActor.run {
                    self.image = NSImage(cgImage: representation.cgImage, size: .zero)
                }
            } catch {
                // Thumbnail generation failed, leave as placeholder
            }
        }
    }
}

// MARK: - Multi-File Attachments Popover

struct AttachmentsPopoverView: View {
    let document: DocumentItem
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "paperclip")
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("File Attachments")
                        .font(.headline)
                    Text(document.meta.name)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            
            Divider()
            
            // Attachments list
            ScrollView {
                LazyVStack(spacing: 8) {
                    if let attachments = document.meta.attachments {
                        ForEach(attachments) { attachment in
                            AttachmentRowView(
                                attachment: attachment,
                                document: document,
                                onRemove: { attachment in
                                    model.removeAttachment(attachment, from: document)
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            
            Divider()
            
            // Footer with drag & drop area
            VStack(spacing: 8) {
                Text("Drop files here to add more attachments")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack {
                    Text("\(document.attachmentCount) file(s)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if let totalSize = document.meta.attachments?.reduce(0, { $0 + $1.fileSize }) {
                        Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            // Add files to existing document
            let draft = DraftMeta(
                name: document.meta.name,
                amount: document.meta.amount,
                notes: document.meta.notes,
                status: document.meta.status,
                year: document.meta.year
            )
            model.importURLs(urls, with: draft, addToExistingDocument: document)
            return true
        }
    }
}

struct AttachmentRowView: View {
    let attachment: DocumentAttachment
    let document: DocumentItem
    let onRemove: (DocumentAttachment) -> Void
    @EnvironmentObject var model: AppModel
    
    var attachmentURL: URL {
        document.documentFolderURL.appendingPathComponent(attachment.filename)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            ThumbnailView(url: attachmentURL, isOffloaded: false)
                .frame(width: 32, height: 40)
            
            // File info
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.originalFilename)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    Text(ByteCountFormatter.string(fromByteCount: attachment.fileSize, countStyle: .file))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if attachment.isOriginalFile {
                        Text("Primary")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2))
                            .foregroundColor(.accentColor)
                            .cornerRadius(4)
                    }
                }
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 8) {
                // Open file button
                Button(action: {
                    NSWorkspace.shared.open(attachmentURL)
                }) {
                    Image(systemName: "eye")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Open file")
                
                // Remove button (only if more than one attachment)
                if document.attachmentCount > 1 {
                    Button(action: {
                        onRemove(attachment)
                    }) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Remove attachment")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - File Attachment Cell with Proper Popover Anchoring

struct FileAttachmentCell: View {
    let item: DocumentItem
    @EnvironmentObject var model: AppModel
    @State private var showingAttachmentsPopover = false
    
    var body: some View {
        HStack {
            if item.isDownloading {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 28, height: 36)
            } else {
                ThumbnailView(url: item.primaryAttachmentURL, isOffloaded: item.isDownloading)
            }
            
            if item.filename.hasSuffix(".placeholder") {
                // Show placeholder state instead of clickable link
                Text("No file attached")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    // Main file button/link
                    Button(action: {
                        guard !item.isDownloading else { return }
                        
                        if item.isMultiFile {
                            // Show attachments popover for multi-file documents
                            showingAttachmentsPopover = true
                        } else {
                            // Open single file directly
                            Task {
                                let isAvailable = await model.ensureFileDownloaded(item)
                                if isAvailable {
                                    NSWorkspace.shared.open(item.primaryAttachmentURL)
                                }
                            }
                        }
                    }) {
                        HStack(spacing: 4) {
                            if item.isMultiFile {
                                Image(systemName: "folder")
                                    .font(.caption)
                                Text(item.attachmentCountDisplay)
                            } else {
                                Text(item.filename)
                            }
                            
                            if item.isDownloading {
                                Image(systemName: "icloud.and.arrow.down")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.link)
                    .disabled(item.isDownloading)
                    .popover(isPresented: $showingAttachmentsPopover, arrowEdge: .trailing) {
                        AttachmentsPopoverView(document: item)
                            .frame(width: 400, height: 300)
                    }
                    
                    // Show file count for multi-file documents
                    if item.isMultiFile {
                        Text("\(item.attachmentCount) attachments")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}