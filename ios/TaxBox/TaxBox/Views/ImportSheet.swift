import SwiftUI
import QuickLookThumbnailing

struct ImportSheet: View {
    let urls: [URL]
    @Binding var draft: DraftMeta
    @EnvironmentObject var model: AppModel
    let isManualAdd: Bool
    var completion: (Bool) -> Void
    @State private var selectedPreviewIndex = 0
    @State private var addToExistingDocument: DocumentItem? = nil
    @State private var showingDocumentPicker = false

    var body: some View {
        HStack(spacing: 20) {
            // Document Preview Section - only show for file imports
            if !isManualAdd {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview")
                        .font(.headline)
                    
                    if urls.count > 1 {
                        Picker("Document", selection: $selectedPreviewIndex) {
                            ForEach(0..<urls.count, id: \.self) { index in
                                Text(urls[index].lastPathComponent).tag(index)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    
                    if let previewUrl = urls.indices.contains(selectedPreviewIndex) ? urls[selectedPreviewIndex] : urls.first {
                        DocumentPreviewView(url: previewUrl)
                            .frame(width: 250, height: 320)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.1))
                            .frame(width: 250, height: 320)
                            .overlay(
                                VStack {
                                    Image(systemName: "doc")
                                        .font(.system(size: 48))
                                        .foregroundColor(.secondary)
                                    Text("No document")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            )
                    }
                }
                
                Divider()
            }
            
            // Form Section
            VStack(alignment: .leading, spacing: 12) {
                Text(isManualAdd ? "Add Placeholder" : "Add Documents").font(.title2).bold()
                if !isManualAdd {
                    HStack {
                        Text("\(urls.count) file(s)")
                        Spacer()
                        if urls.count > 1 {
                            Button("Add to Existing Document") {
                                showingDocumentPicker = true
                            }
                            .buttonStyle(.link)
                        }
                    }
                    
                    if let existingDoc = addToExistingDocument {
                        HStack {
                            Image(systemName: "paperclip")
                                .foregroundColor(.accentColor)
                            Text("Adding to: \(existingDoc.meta.name)")
                                .font(.caption)
                            Button("Change") {
                                showingDocumentPicker = true
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(6)
                    }
                }
                TextField(isManualAdd ? "Document name (e.g., 'W-2 from Employer')" : "Name", text: $draft.name)
                HStack {
                    Text("Amount")
                    TextField("$0.00", value: Binding(get: { draft.amount ?? 0 }, set: { v in draft.amount = v == 0 ? nil : v }), format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                }
                TextField("Notes", text: $draft.notes, axis: .vertical)
                    .frame(height: 60)
                Picker("Status", selection: $draft.status) { 
                    ForEach(model.availableStatuses, id: \.self) { status in
                        Text(status).tag(status)
                    }
                }
                Stepper(value: $draft.year, in: 1980...2100) { Text("Year: \(String(draft.year))") }
                
                Spacer()
                
                HStack { 
                    Spacer()
                    Button("Cancel") { completion(false) }
                    Button(buttonTitle) { 
                        if let existingDoc = addToExistingDocument {
                            // Add to existing document
                            model.importURLs(urls, with: draft, addToExistingDocument: existingDoc)
                            completion(true)
                        } else {
                            // Normal completion flow
                            completion(true)
                        }
                    }.keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 280)
        }
        .padding(20)
        .sheet(isPresented: $showingDocumentPicker) {
            DocumentPickerSheet(
                selectedDocument: $addToExistingDocument,
                isPresented: $showingDocumentPicker
            )
            .frame(width: 500, height: 400)
        }
    }
    
    private var buttonTitle: String {
        if addToExistingDocument != nil {
            return "Add to Document"
        } else if isManualAdd {
            return "Create"
        } else {
            return "Add"
        }
    }
}

struct DocumentPreviewView: View {
    let url: URL
    @State private var image: NSImage? = nil
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if isLoading {
                VStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                    Text("Loading preview...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: url.pathExtension.lowercased() == "heic" ? "photo" : "doc.text")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text("Preview unavailable")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(12)
            }
        }
        .onAppear {
            generatePreview()
        }
        .onChange(of: url) {
            image = nil
            isLoading = true
            generatePreview()
        }
    }
    
    private func generatePreview() {
        // First check if file exists and is accessible
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            print("Preview generation failed: file does not exist at \(url.path)")
            DispatchQueue.main.async {
                self.isLoading = false
                self.image = nil
            }
            return
        }
        
        guard fileManager.isReadableFile(atPath: url.path) else {
            print("Preview generation failed: file is not readable at \(url.path)")
            DispatchQueue.main.async {
                self.isLoading = false
                self.image = nil
            }
            return
        }
        
        // For camera-captured documents, try direct image loading first
        if url.path.contains("TaxBox-Camera") && url.pathExtension.lowercased() == "jpg" {
            if let nsImage = NSImage(contentsOf: url) {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.image = nsImage
                }
                return
            }
        }
        
        // Fall back to QuickLook thumbnail generation
        let request = QLThumbnailGenerator.Request(
            fileAt: url, 
            size: CGSize(width: 320, height: 320), 
            scale: 2, 
            representationTypes: .thumbnail
        )
        
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, error in
            DispatchQueue.main.async {
                self.isLoading = false
                if let error = error {
                    print("Preview generation error for \(self.url.lastPathComponent): \(error)")
                    // For camera documents, try one more direct load
                    if self.url.path.contains("TaxBox-Camera") {
                        self.image = NSImage(contentsOf: self.url)
                    }
                } else if let cg = rep?.cgImage { 
                    self.image = NSImage(cgImage: cg, size: .zero) 
                } else {
                    print("No cgImage for \(self.url.lastPathComponent)")
                    // Try direct load as last resort
                    self.image = NSImage(contentsOf: self.url)
                }
            }
        }
    }
}

// MARK: - Document Picker for Adding to Existing Documents

struct DocumentPickerSheet: View {
    @Binding var selectedDocument: DocumentItem?
    @Binding var isPresented: Bool
    @EnvironmentObject var model: AppModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Add to Existing Document")
                    .font(.title2)
                    .bold()
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            
            Divider()
            
            // Document list
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.filteredItems()) { document in
                        DocumentPickerRow(
                            document: document,
                            isSelected: selectedDocument?.id == document.id,
                            onSelect: {
                                selectedDocument = document
                                isPresented = false
                            }
                        )
                    }
                }
                .padding(.horizontal, 20)
            }
            
            // Footer
            HStack {
                Text("\\(model.filteredItems().count) documents available")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if selectedDocument != nil {
                    Button("Select") {
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct DocumentPickerRow: View {
    let document: DocumentItem
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            ThumbnailView(url: document.primaryAttachmentURL, isOffloaded: false)
                .frame(width: 32, height: 40)
            
            // Document info
            VStack(alignment: .leading, spacing: 2) {
                Text(document.meta.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    Text(document.attachmentCountDisplay)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(document.meta.status)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.2))
                        .foregroundColor(.secondary)
                        .cornerRadius(4)
                }
            }
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onTapGesture {
            onSelect()
        }
    }
}
