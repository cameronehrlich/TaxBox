import Foundation
import UniformTypeIdentifiers
import AppKit

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
            UserDefaults.standard.set(root.path, forKey: "TaxBoxRootPath")
            reload()
        }
    }

    let fm = FileManager.default
    
    init() {
        // Check for saved root path
        if let savedPath = UserDefaults.standard.string(forKey: "TaxBoxRootPath") {
            self.root = URL(fileURLWithPath: savedPath)
        } else {
            // Default to ~/Documents/TaxBox
            self.root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/TaxBox")
            UserDefaults.standard.set(self.root.path, forKey: "TaxBoxRootPath")
        }
        
        // Load saved statuses or use defaults
        loadStatuses()
    }

    func bootstrap() {
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func openRootInFinder() { NSWorkspace.shared.activateFileViewerSelecting([root]) }

    func reload() {
        var found: [DocumentItem] = []
        var ys = Set<Int>()
        if let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for yURL in entries where (try? yURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if let y = Int(yURL.lastPathComponent) {
                    var hasDocuments = false
                    if let files = try? fm.contentsOfDirectory(at: yURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        for f in files where f.pathExtension.lowercased() != "json" {
                            let sc = f.appendingPathExtension("meta.json")
                            if let meta = loadSidecar(sc, fallbackFor: f, year: y) {
                                found.append(DocumentItem(url: f, sidecarURL: sc, meta: meta))
                                hasDocuments = true
                            }
                        }
                    }
                    // Only add year if we found actual documents
                    if hasDocuments {
                        ys.insert(y)
                    }
                }
            }
        }
        DispatchQueue.main.async {
            self.years = ys.sorted(by: >)
            if self.selectedYear == nil { self.selectedYear = self.years.first }
            self.items = found.sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
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

    func importURLs(_ urls: [URL], with draft: DraftMeta) {
        for src in urls { importURL(src, with: draft) }
        reload()
    }
    
    func createPlaceholder(with draft: DraftMeta) {
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
        
        reload()
    }

    private func importURL(_ src: URL, with draft: DraftMeta) {
        let yearURL = root.appending(path: String(draft.year))
        try? fm.createDirectory(at: yearURL, withIntermediateDirectories: true)
        let dest = uniqueDestination(in: yearURL, original: src.lastPathComponent)
        do {
            if copyOnImport { try fm.copyItem(at: src, to: dest) } else { try fm.moveItem(at: src, to: dest) }
            let sidecarURL = dest.appendingPathExtension("meta.json")
            let meta = Sidecar(name: draft.name, amount: draft.amount, notes: draft.notes, status: draft.status, year: draft.year, createdAt: .now, sourcePath: src.path)
            saveSidecar(meta, to: sidecarURL)
        } catch { print("Import failed: \(error)") }
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
    
    func deleteItem(_ item: DocumentItem) {
        do {
            try fm.removeItem(at: item.url)
            try? fm.removeItem(at: item.sidecarURL)
            reload()
        } catch {
            print("Failed to delete: \(error)")
        }
    }
    
    func deleteItems(_ items: Set<DocumentItem>) {
        for item in items {
            do {
                try fm.removeItem(at: item.url)
                try? fm.removeItem(at: item.sidecarURL)
            } catch {
                print("Failed to delete \(item.filename): \(error)")
            }
        }
        reload()
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
}

extension JSONEncoder { static let iso: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }() }
extension JSONDecoder { static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }() }

func setFinderTags(for sidecarURL: URL, year: Int, status: String) {
    // Finder tags functionality temporarily disabled
    // This would require additional entitlements and proper URL resource handling
}