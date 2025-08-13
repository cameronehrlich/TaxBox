import Foundation
import UniformTypeIdentifiers
import AppKit
import Cocoa

// Status is now a simple String - no more enum limitations

struct Sidecar: Codable, Equatable, Hashable {
    var name: String
    var amount: Double?
    var notes: String
    var status: String
    var year: Int
    var createdAt: Date
    var sourcePath: String?
}

struct DocumentItem: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    var sidecarURL: URL
    var meta: Sidecar
    var isDownloading: Bool = false
    var downloadProgress: Double = 0.0

    var filename: String { url.lastPathComponent }
}

final class AppModel: ObservableObject {
    @Published var items: [DocumentItem] = []
    @Published var years: [Int] = []
    @Published var selectedYear: Int? = Calendar.current.component(.year, from: .now)
    @Published var statusFilter: String? = nil
    @Published var availableStatuses: [String] = []
    @Published var query: String = ""
    @Published var copyOnImport: Bool = true
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

    @MainActor
    func reload() {
        Task {
            await performReload()
        }
    }
    
    @MainActor
    private func performReload() async {
        let found = await Task.detached { [weak self] () -> ([DocumentItem], Set<Int>) in
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
                        for f in files where f.pathExtension.lowercased() != "json" {
                            let sc = f.appendingPathExtension("meta.json")
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
                            }
                        }
                    }
                    if hasDocuments {
                        foundYears.insert(y)
                    }
                }
            }
            
            return (foundItems, foundYears)
        }.value
        
        // Update UI on main actor
        self.years = found.1.sorted(by: >)
        if self.selectedYear == nil { self.selectedYear = self.years.first }
        self.items = found.0.sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
        
        // Trigger downloads for any files that need it
        for item in self.items where item.isDownloading {
            triggerDownload(for: item.url)
        }
    }

    func loadSidecar(_ url: URL, fallbackFor file: URL, year: Int) -> Sidecar? {
        if let data = try? Data(contentsOf: url), let sc = try? JSONDecoder.iso.decode(Sidecar.self, from: data) { 
            // Discover and add this status if it's new
            discoverStatus(sc.status)
            return sc 
        }
        let base = file.deletingPathExtension().lastPathComponent
        return Sidecar(name: base, amount: nil, notes: "", status: defaultStatus(), year: year, createdAt: .now, sourcePath: nil)
    }

    func saveSidecar(_ meta: Sidecar, to url: URL) {
        if let data = try? JSONEncoder.iso.encode(meta) { try? data.write(to: url, options: [.atomic]) }
        setFinderTags(for: url.deletingPathExtension(), year: meta.year, status: meta.status)
    }

    @MainActor
    func importURLs(_ urls: [URL], with draft: DraftMeta) {
        Task {
            // Check if we have access to the root folder
            if await !hasAccessToRoot() {
                print("No access to root folder, requesting permission")
                selectNewRootFolder()
                return
            }
            
            for src in urls { 
                await importURL(src, with: draft) 
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
            
            await Task.detached { [weak self] in
                guard let self = self else { return }
                
                let yearURL = self.root.appending(path: String(draft.year))
                try? self.fm.createDirectory(at: yearURL, withIntermediateDirectories: true)
                
                // Create a placeholder filename based on the name
                let sanitizedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                let filename = sanitizedName.isEmpty ? "Document" : sanitizedName
                let placeholderFile = self.uniqueDestination(in: yearURL, original: "\(filename).placeholder")
                
                // Create an empty placeholder file
                try? Data().write(to: placeholderFile)
                
                // Create the metadata
                let sidecarURL = placeholderFile.appendingPathExtension("meta.json")
                let meta = Sidecar(name: draft.name, amount: draft.amount, notes: draft.notes, status: draft.status, year: draft.year, createdAt: .now, sourcePath: nil)
                self.saveSidecar(meta, to: sidecarURL)
            }.value
            
            await performReload()
        }
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
                
                let sidecarURL = dest.appendingPathExtension("meta.json")
                let meta = Sidecar(name: draft.name, amount: draft.amount, notes: draft.notes, status: draft.status, year: draft.year, createdAt: .now, sourcePath: src.path)
                self.saveSidecar(meta, to: sidecarURL)
            } catch {
                print("Import failed: \(error)")
                
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

    private func uniqueDestination(in folder: URL, original: String) -> URL {
        var attempt = folder.appending(path: original)
        var idx = 1
        while fm.fileExists(atPath: attempt.path) {
            let base = URL(filePath: original).deletingPathExtension().lastPathComponent
            let ext = URL(filePath: original).pathExtension
            attempt = folder.appending(path: "\(base)-\(idx).\(ext)")
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
            try fm.removeItem(at: item.url)
            try? fm.removeItem(at: item.sidecarURL)
            Task { @MainActor in
                reload()
            }
        } catch {
            print("Failed to delete: \(error)")
        }
    }
    
    @MainActor
    func deleteItems(_ items: Set<DocumentItem>) {
        for item in items {
            do {
                try fm.removeItem(at: item.url)
                try? fm.removeItem(at: item.sidecarURL)
            } catch {
                print("Failed to delete \(item.filename): \(error)")
            }
        }
        Task { @MainActor in
            reload()
        }
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
