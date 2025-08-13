import Foundation
import UniformTypeIdentifiers
import AppKit
import Cocoa

// Status is now a simple String - no more enum limitations

// MARK: - Multi-File Attachment Support

/// Represents a single file attachment within a document record
struct DocumentAttachment: Codable, Identifiable, Hashable {
    let id = UUID()
    var filename: String
    let originalFilename: String  // Original name before any deduplication
    let fileSize: Int64
    let dateAdded: Date
    let isOriginalFile: Bool  // True for the first/primary file, false for additional attachments
    
    enum CodingKeys: String, CodingKey {
        case filename, originalFilename, fileSize, dateAdded, isOriginalFile
    }
}

struct Sidecar: Codable, Equatable, Hashable {
    var name: String
    var amount: Double?
    var notes: String
    var status: String
    var year: Int
    var createdAt: Date
    var sourcePath: String?
    
    // Multi-file support
    var attachments: [DocumentAttachment]?
    var isMultiFile: Bool { (attachments?.count ?? 0) > 1 }
    
    // Migration support - if attachments is nil, this is a legacy single-file document
    var hasAttachments: Bool { attachments != nil }
}

struct DocumentItem: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    var sidecarURL: URL
    var meta: Sidecar
    var isDownloading: Bool = false
    var downloadProgress: Double = 0.0

    // MARK: - Backward Compatibility Properties
    
    /// Primary filename - for single-file documents, this is the file itself
    /// For multi-file documents, this is the folder name
    var filename: String { url.lastPathComponent }
    
    // MARK: - Multi-File Support
    
    /// Returns true if this document has multiple file attachments
    var isMultiFile: Bool { meta.isMultiFile }
    
    /// Returns the number of file attachments
    var attachmentCount: Int { meta.attachments?.count ?? 1 }
    
    /// For multi-file documents, returns the document folder URL
    /// For single-file documents, returns the parent directory
    var documentFolderURL: URL {
        if isMultiFile {
            return url  // url points to the document folder
        } else {
            return url.deletingLastPathComponent()  // url points to the file
        }
    }
    
    /// Returns URLs for all file attachments
    var attachmentURLs: [URL] {
        if let attachments = meta.attachments {
            return attachments.map { documentFolderURL.appendingPathComponent($0.filename) }
        } else {
            // Legacy single-file document
            return [url]
        }
    }
    
    /// Returns the primary attachment URL (first file)
    var primaryAttachmentURL: URL {
        return attachmentURLs.first ?? url
    }
    
    /// Display name for the attachment count
    var attachmentCountDisplay: String {
        let count = attachmentCount
        return count == 1 ? "1 file" : "\(count) files"
    }
}

final class AppModel: ObservableObject {
    @Published var items: [DocumentItem] = []
    @Published var years: [Int] = []
    @Published var selectedYear: Int? = Calendar.current.component(.year, from: .now)
    @Published var statusFilter: String? = nil
    @Published var availableStatuses: [String] = []
    @Published var query: String = ""
    @Published var copyOnImport: Bool = true
    @Published var showingCSVImport = false
    @Published var lastImportError: String? = nil
    @Published var root: URL {
        didSet {
            // Stop accessing old URL if it was security-scoped
            if oldValue != root && isAccessingSecurityScopedResource {
                oldValue.stopAccessingSecurityScopedResource()
                isAccessingSecurityScopedResource = false
            }
            saveRootBookmark()
            Task { @MainActor in
                reload()
            }
        }
    }
    
    private var isAccessingSecurityScopedResource = false
    
    private func saveRootBookmark() {
        do {
            // Create a security-scoped bookmark
            let bookmarkData = try root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: "TaxBoxRootBookmark")
            // Also save path for backward compatibility
            UserDefaults.standard.set(root.path, forKey: "TaxBoxRootPath")
        } catch {
            print("Failed to create bookmark: \(error)")
            // Fall back to just saving the path
            UserDefaults.standard.set(root.path, forKey: "TaxBoxRootPath")
        }
    }
    
    private var metadataQuery: NSMetadataQuery?
    private var downloadingFiles: Set<URL> = []

    let fm = FileManager.default
    
    init() {
        // Try to restore from security-scoped bookmark first
        var rootURL: URL? = nil
        // var needsAccessStart = false // Not needed anymore
        
        if let bookmarkData = UserDefaults.standard.data(forKey: "TaxBoxRootBookmark") {
            do {
                var isStale = false
                let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
                
                if !isStale {
                    // Try to start accessing the security-scoped resource
                    if url.startAccessingSecurityScopedResource() {
                        rootURL = url
                        isAccessingSecurityScopedResource = true
                    } else {
                        print("Failed to start accessing security-scoped resource, clearing bookmark")
                        UserDefaults.standard.removeObject(forKey: "TaxBoxRootBookmark")
                    }
                } else {
                    // Bookmark is stale, clear it and will need to re-select
                    print("Security-scoped bookmark is stale, clearing and will prompt for re-selection")
                    UserDefaults.standard.removeObject(forKey: "TaxBoxRootBookmark")
                }
            } catch {
                print("Failed to resolve bookmark: \(error), clearing bookmark")
                UserDefaults.standard.removeObject(forKey: "TaxBoxRootBookmark")
            }
        }
        
        // Fall back to saved path or default
        if rootURL == nil {
            if let savedPath = UserDefaults.standard.string(forKey: "TaxBoxRootPath") {
                rootURL = URL(fileURLWithPath: savedPath)
            } else {
                rootURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/TaxBox")
            }
        }
        
        self.root = rootURL!
        
        // Load saved statuses or use defaults
        loadStatuses()
    }

    @MainActor
    func bootstrap() {
        // Check if we need to prompt for folder access
        if !isAccessingSecurityScopedResource && root.path.contains("/Library/Mobile Documents/") {
            // This is an iCloud path but we don't have a security-scoped bookmark
            print("Need to select folder with proper permissions")
            selectNewRootFolder()
            return
        }
        
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            print("Failed to create directory at \(root.path): \(error)")
            // If we can't create the directory, it might be a permissions issue
            // Prompt user to select a folder
            selectNewRootFolder()
            return
        }
        setupiCloudMonitoring()
        reload()
    }
    
    func selectNewRootFolder() {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "TaxBox needs permission to access your documents folder. Please select the folder where you want to store your tax documents."
            panel.prompt = "Grant Access"
            
            // If we have a current path, try to set it as the default
            if self.fm.fileExists(atPath: self.root.path) {
                panel.directoryURL = self.root
            }
            
            if panel.runModal() == .OK, let url = panel.url {
                // Stop accessing old resource if needed
                if self.isAccessingSecurityScopedResource {
                    self.root.stopAccessingSecurityScopedResource()
                    self.isAccessingSecurityScopedResource = false
                }
                
                // Get security-scoped bookmark
                do {
                    // Start accessing immediately
                    self.isAccessingSecurityScopedResource = url.startAccessingSecurityScopedResource()
                    
                    if self.isAccessingSecurityScopedResource {
                        // Create bookmark while we have access
                        let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                        UserDefaults.standard.set(bookmarkData, forKey: "TaxBoxRootBookmark")
                        self.root = url
                        self.bootstrap()
                    } else {
                        print("Failed to start accessing security-scoped resource")
                    }
                } catch {
                    print("Failed to create security-scoped bookmark: \(error)")
                }
            }
        }
    }
    
    private func setupiCloudMonitoring() {
        // Stop any existing query
        metadataQuery?.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: metadataQuery)
        
        metadataQuery = NSMetadataQuery()
        guard let query = metadataQuery else { return }
        
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, root.path)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        
        query.start()
    }
    
    @objc private func queryDidUpdate(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.checkAndUpdateDownloadStatus()
        }
    }
    
    private func checkAndUpdateDownloadStatus() {
        for index in items.indices {
            let item = items[index]
            if downloadingFiles.contains(item.url) {
                if let resourceValues = try? item.url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
                   let status = resourceValues.ubiquitousItemDownloadingStatus {
                    if status == .current {
                        items[index].isDownloading = false
                        items[index].downloadProgress = 1.0
                        downloadingFiles.remove(item.url)
                    } else if status == .downloaded {
                        items[index].isDownloading = false
                        items[index].downloadProgress = 1.0
                        downloadingFiles.remove(item.url)
                    }
                }
            }
        }
    }

    func openRootInFinder() { NSWorkspace.shared.activateFileViewerSelecting([root]) }
    
    func showCSVImport() {
        showingCSVImport = true
    }

    @MainActor
    func reload() {
        Task {
            await performReload()
        }
    }
    
    @MainActor
    private func performReload() async {
        let found = Task.detached { [weak self] () -> ([DocumentItem], Set<Int>) in
            guard let self = self else { return ([], Set<Int>()) }
            
            var foundItems: [DocumentItem] = []
            var foundYears = Set<Int>()
            
            guard let entries = try? self.fm.contentsOfDirectory(at: self.root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                return (foundItems, foundYears)
            }
            
            for yURL in entries where (try? yURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if let y = Int(yURL.lastPathComponent) {
                    var hasDocuments = false
                    if let files = try? self.fm.contentsOfDirectory(at: yURL, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey], options: [.skipsHiddenFiles]) {
                        // First pass: identify document folders vs standalone files
                        var processedItems = Set<String>()
                        
                        for f in files where f.pathExtension.lowercased() != "json" {
                            let fileName = f.lastPathComponent
                            if processedItems.contains(fileName) { continue }
                            
                            let sc = f.appendingPathExtension("meta.json")
                            
                            // Check if this is a document folder or single file
                            var isDirectory: ObjCBool = false
                            let fileExists = self.fm.fileExists(atPath: f.path, isDirectory: &isDirectory)
                            
                            if fileExists && isDirectory.boolValue {
                                // This is a multi-file document folder
                                if let meta = self.loadSidecar(sc, fallbackFor: f, year: y) {
                                    let item = DocumentItem(url: f, sidecarURL: sc, meta: meta)
                                    foundItems.append(item)
                                    hasDocuments = true
                                    processedItems.insert(fileName)
                                }
                            } else if fileExists && !isDirectory.boolValue {
                                // This is a single file - check if it has modern multi-file metadata
                                if let meta = self.loadSidecar(sc, fallbackFor: f, year: y) {
                                    var item = DocumentItem(url: f, sidecarURL: sc, meta: meta)
                                    
                                    // Check if file needs downloading from iCloud
                                    if let resourceValues = try? f.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]) {
                                        if let status = resourceValues.ubiquitousItemDownloadingStatus {
                                            if status == .notDownloaded {
                                                item.isDownloading = true
                                            }
                                        }
                                    }
                                    
                                    foundItems.append(item)
                                    hasDocuments = true
                                    processedItems.insert(fileName)
                                }
                            }
                        }
                    }
                    if hasDocuments {
                        foundYears.insert(y)
                    }
                }
            }
            
            return (foundItems, foundYears)
        }
        
        let foundResult = await found.value
        
        // Update UI on main actor
        self.years = foundResult.1.sorted(by: >)
        if self.selectedYear == nil { self.selectedYear = self.years.first }
        self.items = foundResult.0.sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
        
        // Trigger downloads for any files that need it
        for item in self.items where item.isDownloading {
            triggerDownload(for: item.url)
        }
    }

    func loadSidecar(_ url: URL, fallbackFor file: URL, year: Int) -> Sidecar? {
        if let data = try? Data(contentsOf: url), let sc = try? JSONDecoder.iso.decode(Sidecar.self, from: data) { 
            // Discover and add this status if it's new
            discoverStatus(sc.status)
            
            // Migration: if this is a legacy single-file document, create attachment metadata
            if sc.attachments == nil {
                var migratedSidecar = sc
                migratedSidecar.attachments = [createAttachmentFromFile(file)]
                return migratedSidecar
            }
            
            return sc 
        }
        
        // Create new sidecar for file without metadata
        let base = file.deletingPathExtension().lastPathComponent
        let attachment = createAttachmentFromFile(file)
        
        return Sidecar(
            name: base, 
            amount: nil, 
            notes: "", 
            status: defaultStatus(), 
            year: year, 
            createdAt: .now, 
            sourcePath: nil,
            attachments: [attachment]
        )
    }
    
    /// Creates a DocumentAttachment from a file URL
    private func createAttachmentFromFile(_ fileURL: URL) -> DocumentAttachment {
        let fileSize: Int64
        do {
            let attributes = try fm.attributesOfItem(atPath: fileURL.path)
            fileSize = attributes[.size] as? Int64 ?? 0
        } catch {
            fileSize = 0
        }
        
        return DocumentAttachment(
            filename: fileURL.lastPathComponent,
            originalFilename: fileURL.lastPathComponent,
            fileSize: fileSize,
            dateAdded: Date(),
            isOriginalFile: true
        )
    }

    func saveSidecar(_ meta: Sidecar, to url: URL) {
        if let data = try? JSONEncoder.iso.encode(meta) { try? data.write(to: url, options: [.atomic]) }
        setFinderTags(for: url.deletingPathExtension(), year: meta.year, status: meta.status)
    }

    @MainActor
    func importURLs(_ urls: [URL], with draft: DraftMeta, addToExistingDocument: DocumentItem? = nil) {
        Task {
            // Check if we have access to the root folder
            if await !hasAccessToRoot() {
                print("No access to root folder, requesting permission")
                selectNewRootFolder()
                return
            }
            
            if let existingDocument = addToExistingDocument {
                // Add files to existing document
                await addFilesToExistingDocument(urls, to: existingDocument)
            } else if urls.count == 1 {
                // Single file import - create single-file document
                await importURL(urls[0], with: draft)
            } else {
                // Multiple files - create multi-file document
                await importMultipleFiles(urls, with: draft)
            }
            
            await performReload()
        }
    }
    
    @MainActor
    func createPlaceholder(with draft: DraftMeta) {
        Task {
            // Check if we have access to the root folder
            if await !hasAccessToRoot() {
                print("No access to root folder, requesting permission")
                selectNewRootFolder()
                return
            }
            
            await createPlaceholderInternal(with: draft)
            await performReload()
        }
    }
    
    @MainActor
    func createBulkPlaceholders(_ drafts: [DraftMeta]) {
        Task {
            // Single access check for the entire bulk operation
            if await !hasAccessToRoot() {
                print("No access to root folder, requesting permission")
                selectNewRootFolder()
                return
            }
            
            // Create all placeholders without individual access checks
            await Task.detached { [weak self] in
                guard let self = self else { return }
                
                for draft in drafts {
                    await self.createPlaceholderInternal(with: draft)
                }
            }.value
            
            // Single reload at the end
            await performReload()
        }
    }
    
    private func createPlaceholderInternal(with draft: DraftMeta) async {
        let yearURL = root.appending(path: String(draft.year))
        try? fm.createDirectory(at: yearURL, withIntermediateDirectories: true)
        
        // Create a placeholder filename based on the name
        let sanitizedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let filename = sanitizedName.isEmpty ? "Document" : sanitizedName
        let placeholderFile = uniqueDestination(in: yearURL, original: "\(filename).placeholder")
        
        // Create an empty placeholder file
        try? Data().write(to: placeholderFile)
        
        // Create the metadata
        let sidecarURL = placeholderFile.appendingPathExtension("meta.json")
        let meta = Sidecar(name: draft.name, amount: draft.amount, notes: draft.notes, status: draft.status, year: draft.year, createdAt: .now, sourcePath: nil)
        saveSidecar(meta, to: sidecarURL)
    }

    private func importURL(_ src: URL, with draft: DraftMeta) async {
        await Task.detached { [weak self] in
            guard let self = self else { return }
            
            let yearURL = self.root.appending(path: String(draft.year))
            
            do {
                try self.fm.createDirectory(at: yearURL, withIntermediateDirectories: true)
                let dest = self.uniqueDestination(in: yearURL, original: src.lastPathComponent)
                
                if self.copyOnImport { 
                    try self.fm.copyItem(at: src, to: dest) 
                } else { 
                    try self.fm.moveItem(at: src, to: dest) 
                }
                
                // Create attachment metadata
                let attachment = self.createAttachmentFromFile(dest)
                
                let sidecarURL = dest.appendingPathExtension("meta.json")
                let meta = Sidecar(
                    name: draft.name, 
                    amount: draft.amount, 
                    notes: draft.notes, 
                    status: draft.status, 
                    year: draft.year, 
                    createdAt: .now, 
                    sourcePath: src.path,
                    attachments: [attachment]
                )
                self.saveSidecar(meta, to: sidecarURL)
            } catch {
                print("Import failed: \(error)")
                
                await MainActor.run {
                    self.lastImportError = "Failed to import file: \(error.localizedDescription)"
                }
                
                // Check if it's a permission error
                let nsError = error as NSError
                if nsError.code == 513 || nsError.domain == NSCocoaErrorDomain {
                    print("Permission denied. Requesting folder access...")
                    await MainActor.run {
                        self.selectNewRootFolder()
                    }
                }
            }
        }.value
    }
    
    /// Imports multiple files as a single multi-file document
    private func importMultipleFiles(_ urls: [URL], with draft: DraftMeta) async {
        await Task.detached { [weak self] in
            guard let self = self else { return }
            
            let yearURL = self.root.appending(path: String(draft.year))
            
            do {
                try self.fm.createDirectory(at: yearURL, withIntermediateDirectories: true)
                
                // Create a unique document folder name
                let sanitizedName = self.sanitizeFilename(draft.name)
                let documentFolderName = sanitizedName.isEmpty ? "Document" : sanitizedName
                let documentFolder = self.uniqueDestination(in: yearURL, original: documentFolderName, isDirectory: true)
                
                // Create the document folder
                try self.fm.createDirectory(at: documentFolder, withIntermediateDirectories: true)
                
                var attachments: [DocumentAttachment] = []
                
                // Import each file into the document folder
                for (index, src) in urls.enumerated() {
                    let dest = self.uniqueDestination(in: documentFolder, original: src.lastPathComponent)
                    
                    if self.copyOnImport {
                        try self.fm.copyItem(at: src, to: dest)
                    } else {
                        try self.fm.moveItem(at: src, to: dest)
                    }
                    
                    // Create attachment metadata
                    let fileSize: Int64
                    do {
                        let attributes = try self.fm.attributesOfItem(atPath: dest.path)
                        fileSize = attributes[.size] as? Int64 ?? 0
                    } catch {
                        fileSize = 0
                    }
                    
                    let attachment = DocumentAttachment(
                        filename: dest.lastPathComponent,
                        originalFilename: src.lastPathComponent,
                        fileSize: fileSize,
                        dateAdded: Date(),
                        isOriginalFile: index == 0
                    )
                    
                    attachments.append(attachment)
                }
                
                // Create sidecar metadata for the document folder
                let sidecarURL = documentFolder.appendingPathExtension("meta.json")
                let meta = Sidecar(
                    name: draft.name,
                    amount: draft.amount,
                    notes: draft.notes,
                    status: draft.status,
                    year: draft.year,
                    createdAt: .now,
                    sourcePath: urls.first?.path,
                    attachments: attachments
                )
                
                self.saveSidecar(meta, to: sidecarURL)
                
            } catch {
                print("Multi-file import failed: \(error)")
                
                await MainActor.run {
                    self.lastImportError = "Failed to import files: \(error.localizedDescription)"
                }
                
                // Check if it's a permission error
                let nsError = error as NSError
                if nsError.code == 513 || nsError.domain == NSCocoaErrorDomain {
                    print("Permission denied. Requesting folder access...")
                    await MainActor.run {
                        self.selectNewRootFolder()
                    }
                }
            }
        }.value
    }
    
    /// Adds files to an existing document, converting single-file to multi-file if needed
    private func addFilesToExistingDocument(_ urls: [URL], to document: DocumentItem) async {
        await Task.detached { [weak self] in
            guard let self = self else { return }
            
            do {
                var updatedMeta = document.meta
                var documentFolder: URL
                
                // Handle conversion from single-file to multi-file
                if !document.isMultiFile {
                    // Convert single file to multi-file document folder
                    let parentFolder = document.url.deletingLastPathComponent()
                    let documentName = document.meta.name
                    let sanitizedName = self.sanitizeFilename(documentName)
                    let folderName = sanitizedName.isEmpty ? "Document" : sanitizedName
                    
                    documentFolder = self.uniqueDestination(in: parentFolder, original: folderName, isDirectory: true)
                    
                    // Create document folder
                    try self.fm.createDirectory(at: documentFolder, withIntermediateDirectories: true)
                    
                    // Move existing file into the folder
                    let originalFile = document.url
                    let newLocation = documentFolder.appendingPathComponent(originalFile.lastPathComponent)
                    try self.fm.moveItem(at: originalFile, to: newLocation)
                    
                    // Update existing attachment metadata
                    if var existingAttachment = updatedMeta.attachments?.first {
                        existingAttachment.filename = newLocation.lastPathComponent
                        updatedMeta.attachments = [existingAttachment]
                    }
                    
                    // Move sidecar file
                    let newSidecarURL = documentFolder.appendingPathExtension("meta.json")
                    try self.fm.moveItem(at: document.sidecarURL, to: newSidecarURL)
                } else {
                    documentFolder = document.documentFolderURL
                }
                
                // Add new files to the document folder
                var newAttachments = updatedMeta.attachments ?? []
                
                for src in urls {
                    let dest = self.uniqueDestination(in: documentFolder, original: src.lastPathComponent)
                    
                    if self.copyOnImport {
                        try self.fm.copyItem(at: src, to: dest)
                    } else {
                        try self.fm.moveItem(at: src, to: dest)
                    }
                    
                    // Create attachment metadata
                    let fileSize: Int64
                    do {
                        let attributes = try self.fm.attributesOfItem(atPath: dest.path)
                        fileSize = attributes[.size] as? Int64 ?? 0
                    } catch {
                        fileSize = 0
                    }
                    
                    let attachment = DocumentAttachment(
                        filename: dest.lastPathComponent,
                        originalFilename: src.lastPathComponent,
                        fileSize: fileSize,
                        dateAdded: Date(),
                        isOriginalFile: false
                    )
                    
                    newAttachments.append(attachment)
                }
                
                updatedMeta.attachments = newAttachments
                
                // Save updated metadata
                let sidecarURL = documentFolder.appendingPathExtension("meta.json")
                self.saveSidecar(updatedMeta, to: sidecarURL)
                
            } catch {
                print("Failed to add files to existing document: \(error)")
            }
        }.value
    }
    
    /// Sanitizes a filename for use as a folder name
    private func sanitizeFilename(_ name: String) -> String {
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "|", with: "-")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "\"", with: "")
    }

    private func uniqueDestination(in folder: URL, original: String, isDirectory: Bool = false) -> URL {
        var attempt = folder.appending(path: original)
        var idx = 1
        while fm.fileExists(atPath: attempt.path) {
            if isDirectory {
                attempt = folder.appending(path: "\(original)-\(idx)")
            } else {
                let base = URL(filePath: original).deletingPathExtension().lastPathComponent
                let ext = URL(filePath: original).pathExtension
                attempt = folder.appending(path: "\(base)-\(idx).\(ext)")
            }
            idx += 1
        }
        return attempt
    }

    func update(_ item: DocumentItem) {
        saveSidecar(item.meta, to: item.sidecarURL)
        // Update the item in place instead of reloading everything
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        }
    }

    func filteredItems() -> [DocumentItem] {
        items.filter { it in
            (selectedYear == nil || it.meta.year == selectedYear!) &&
            (statusFilter == nil || it.meta.status == statusFilter!) &&
            (query.isEmpty || it.meta.name.localizedCaseInsensitiveContains(query) || it.filename.localizedCaseInsensitiveContains(query) || it.meta.notes.localizedCaseInsensitiveContains(query))
        }
    }

    var totalAmount: Double {
        filteredItems().compactMap{ $0.meta.amount }.reduce(0, +)
    }
    
    @MainActor
    func deleteItem(_ item: DocumentItem) {
        do {
            if item.isMultiFile {
                // Delete the entire document folder and its contents
                try fm.removeItem(at: item.documentFolderURL)
                try? fm.removeItem(at: item.sidecarURL)
            } else {
                // Delete single file and its sidecar
                try fm.removeItem(at: item.url)
                try? fm.removeItem(at: item.sidecarURL)
            }
            
            // Update the in-memory items array directly
            items.removeAll { $0.id == item.id }
            updateYearsFromItems()
            
            print("Successfully deleted: \(item.filename)")
        } catch {
            print("Failed to delete: \(error)")
        }
    }
    
    @MainActor
    func deleteItems(_ items: Set<DocumentItem>) {
        var deletedItems: Set<DocumentItem> = []
        
        for item in items {
            do {
                if item.isMultiFile {
                    // Delete the entire document folder and its contents
                    try fm.removeItem(at: item.documentFolderURL)
                    try? fm.removeItem(at: item.sidecarURL)
                } else {
                    // Delete single file and its sidecar
                    try fm.removeItem(at: item.url)
                    try? fm.removeItem(at: item.sidecarURL)
                }
                deletedItems.insert(item)
                print("Successfully deleted: \(item.filename)")
            } catch {
                print("Failed to delete \(item.filename): \(error)")
            }
        }
        
        // Update the in-memory items array directly for immediate UI feedback
        if !deletedItems.isEmpty {
            self.items.removeAll { item in
                deletedItems.contains(item)
            }
            
            // Also update years if needed
            updateYearsFromItems()
            
            print("Removed \(deletedItems.count) items from in-memory array")
        }
    }
    
    // MARK: - Helper Methods
    
    @MainActor
    private func updateYearsFromItems() {
        years = Array(Set(items.map { $0.meta.year })).sorted(by: >)
    }
    
    // MARK: - Status Management
    
    private func loadStatuses() {
        if let saved = UserDefaults.standard.array(forKey: "TaxBoxStatuses") as? [String] {
            availableStatuses = saved
        } else {
            // Default statuses for new users
            availableStatuses = ["Todo", "In Progress", "Done"]
            saveStatuses()
        }
    }
    
    private func saveStatuses() {
        UserDefaults.standard.set(availableStatuses, forKey: "TaxBoxStatuses")
    }
    
    func discoverStatus(_ status: String) {
        if !availableStatuses.contains(status) {
            availableStatuses.append(status)
            saveStatuses()
        }
    }
    
    func defaultStatus() -> String {
        return availableStatuses.first ?? "Todo"
    }
    
    func addStatus(_ status: String) {
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let trimmedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if !availableStatuses.contains(trimmedStatus) {
            availableStatuses.append(trimmedStatus)
            saveStatuses()
        }
    }
    
    func removeStatus(_ status: String) {
        guard availableStatuses.count > 1 else { return } // Always keep at least one status
        if let index = availableStatuses.firstIndex(of: status) {
            availableStatuses.remove(at: index)
            saveStatuses()
            
            // Update any documents using this status to the default
            let defaultStat = defaultStatus()
            for item in items where item.meta.status == status {
                var updatedItem = item
                updatedItem.meta.status = defaultStat
                update(updatedItem)
            }
        }
    }
    
    func reorderStatuses(_ statuses: [String]) {
        availableStatuses = statuses
        saveStatuses()
    }
    
    // MARK: - Error Handling
    
    func clearImportError() {
        lastImportError = nil
    }
    
    // MARK: - iCloud Support
    
    func triggerDownload(for url: URL) {
        do {
            // Check if file is already downloaded
            let resourceValues = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            
            if let status = resourceValues.ubiquitousItemDownloadingStatus {
                if status == .notDownloaded {
                    // Start downloading the file
                    try fm.startDownloadingUbiquitousItem(at: url)
                    downloadingFiles.insert(url)
                    
                    // Update the item to show downloading state
                    if let index = items.firstIndex(where: { $0.url == url }) {
                        items[index].isDownloading = true
                    }
                }
                // Other statuses don't need action
                // .downloaded and .current mean file is available, no action needed
            }
        } catch {
            print("Error triggering download for \(url.lastPathComponent): \(error)")
        }
    }
    
    @MainActor
    func ensureFileDownloaded(_ item: DocumentItem) async -> Bool {
        do {
            let resourceValues = try item.url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            
            guard let status = resourceValues.ubiquitousItemDownloadingStatus else {
                // Not an iCloud file, treat as available
                return true
            }
            
            switch status {
            case .current, .downloaded:
                // File is available locally
                return true
            case .notDownloaded:
                // Need to download the file
                do {
                    try fm.startDownloadingUbiquitousItem(at: item.url)
                    downloadingFiles.insert(item.url)
                    
                    // Update UI to show downloading state
                    if let index = items.firstIndex(where: { $0.url == item.url }) {
                        items[index].isDownloading = true
                    }
                    
                    // Monitor download completion with timeout
                    return await withTimeoutOrNil(seconds: 30) {
                        await self.waitForDownloadCompletion(url: item.url)
                    } ?? false
                    
                } catch {
                    print("Failed to start download: \(error)")
                    return false
                }
                
            default:
                return false
            }
        } catch {
            print("Error checking download status: \(error)")
            return false
        }
    }
    
    private func waitForDownloadCompletion(url: URL) async -> Bool {
        // Poll for download completion (since we don't have proper async NSMetadataQuery yet)
        for _ in 0..<60 { // Check up to 60 times (30 seconds with 0.5s intervals)
            do {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                
                let resourceValues = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                if let status = resourceValues.ubiquitousItemDownloadingStatus {
                    if status == .current || status == .downloaded {
                        // Download complete
                        await MainActor.run {
                            self.downloadingFiles.remove(url)
                            if let index = self.items.firstIndex(where: { $0.url == url }) {
                                self.items[index].isDownloading = false
                            }
                        }
                        return true
                    }
                }
            } catch {
                // Continue waiting
            }
        }
        return false
    }
    
    private func withTimeoutOrNil<T>(seconds: TimeInterval, operation: @escaping () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }
            
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            
            if let result = await group.next() {
                group.cancelAll()
                return result
            }
            
            return nil
        }
    }
    
    private func hasAccessToRoot() async -> Bool {
        await Task.detached { [weak self] in
            guard let self = self else { return false }
            
            // Check if we can write to the root directory
            let testFile = self.root.appendingPathComponent(".taxbox_test")
            let testData = Data("test".utf8)
            
            do {
                try testData.write(to: testFile)
                try self.fm.removeItem(at: testFile)
                return true
            } catch {
                return false
            }
        }.value
    }
    
    // MARK: - Multi-File Attachment Management
    
    /// Removes a single file attachment from a multi-file document
    @MainActor
    func removeAttachment(_ attachment: DocumentAttachment, from document: DocumentItem) {
        guard document.isMultiFile, var attachments = document.meta.attachments else { return }
        
        // Remove the attachment from metadata
        attachments.removeAll { $0.id == attachment.id }
        
        // Handle special cases
        if attachments.isEmpty {
            // No attachments left - delete the entire document
            deleteItem(document)
            return
        } else if attachments.count == 1 {
            // Convert back to single-file document
            convertToSingleFile(document: document, remainingAttachment: attachments[0])
            return
        }
        
        // Update metadata
        var updatedMeta = document.meta
        updatedMeta.attachments = attachments
        
        // Remove the physical file
        let fileURL = document.documentFolderURL.appendingPathComponent(attachment.filename)
        do {
            try fm.removeItem(at: fileURL)
            print("Removed attachment: \(attachment.filename)")
        } catch {
            print("Failed to remove attachment file: \(error)")
        }
        
        // Save updated metadata
        saveSidecar(updatedMeta, to: document.sidecarURL)
        
        // Update in-memory item
        if let index = items.firstIndex(where: { $0.id == document.id }) {
            var updatedDocument = document
            updatedDocument.meta = updatedMeta
            items[index] = updatedDocument
        }
    }
    
    /// Converts a multi-file document with one remaining attachment back to single-file
    private func convertToSingleFile(document: DocumentItem, remainingAttachment: DocumentAttachment) {
        let documentFolder = document.documentFolderURL
        let attachmentURL = documentFolder.appendingPathComponent(remainingAttachment.filename)
        let parentFolder = documentFolder.deletingLastPathComponent()
        let newFileURL = uniqueDestination(in: parentFolder, original: remainingAttachment.filename)
        
        do {
            // Move the file out of the document folder
            try fm.moveItem(at: attachmentURL, to: newFileURL)
            
            // Update metadata to single-file format
            var updatedMeta = document.meta
            updatedMeta.attachments = [DocumentAttachment(
                filename: newFileURL.lastPathComponent,
                originalFilename: remainingAttachment.originalFilename,
                fileSize: remainingAttachment.fileSize,
                dateAdded: remainingAttachment.dateAdded,
                isOriginalFile: true
            )]
            
            // Create new sidecar for the single file
            let newSidecarURL = newFileURL.appendingPathExtension("meta.json")
            saveSidecar(updatedMeta, to: newSidecarURL)
            
            // Remove the old document folder and sidecar
            try fm.removeItem(at: documentFolder)
            try? fm.removeItem(at: document.sidecarURL)
            
            // Update in-memory item
            if let index = items.firstIndex(where: { $0.id == document.id }) {
                var updatedDocument = document
                updatedDocument.url = newFileURL
                updatedDocument.sidecarURL = newSidecarURL
                updatedDocument.meta = updatedMeta
                items[index] = updatedDocument
            }
            
            print("Converted multi-file document back to single file: \(newFileURL.lastPathComponent)")
            
        } catch {
            print("Failed to convert to single file: \(error)")
        }
    }
    
    deinit {
        // Clean up metadata query
        metadataQuery?.stop()
        NotificationCenter.default.removeObserver(self)
        
        // Stop accessing security-scoped resource if we started it
        if isAccessingSecurityScopedResource {
            root.stopAccessingSecurityScopedResource()
        }
    }
}

extension JSONEncoder { static let iso: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }() }
extension JSONDecoder { static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }() }

func setFinderTags(for sidecarURL: URL, year: Int, status: String) {
    // Finder tags functionality temporarily disabled
    // This would require additional entitlements and proper URL resource handling
}
