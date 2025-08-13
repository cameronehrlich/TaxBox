import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImportCSVSheet: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    
    @State private var importResult: CSVImportResult?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var duplicateHandling: DuplicateHandling = .skip
    @State private var selectedFileURL: URL?
    @State private var isImporting = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Text("Import from CSV")
                    .font(.title2)
                    .bold()
                Text("Import document metadata from a CSV file")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            if let result = importResult {
                importPreviewView(result: result)
            } else {
                fileSelectionView
            }
        }
        .padding(24)
        .frame(width: 600, height: 500)
    }
    
    // MARK: - File Selection View
    
    private var fileSelectionView: some View {
        VStack(spacing: 20) {
            // File format info
            VStack(alignment: .leading, spacing: 12) {
                Text("Expected CSV Format:")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("• Required column: name")
                    Text("• Optional columns: year, status, amount, notes")
                    Text("• First row should contain column headers")
                    Text("• Any subset of columns is supported")
                }
                .font(.body)
                .foregroundColor(.secondary)
                
                Text("Example:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.top, 8)
                
                Text("""
                name,year,status,amount,notes
                "W-2 from ABC Company",2025,"Todo",,"Annual wages"
                "Medical receipts Q1",2025,"Todo",450.50,"Doctor visits"
                """)
                .font(.system(.caption, design: .monospaced))
                .padding(12)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
            
            Spacer()
            
            // Error display
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            // Action buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                
                Button("Select CSV File...") {
                    selectCSVFile()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
            }
            
            if isLoading {
                ProgressView("Parsing CSV...")
                    .padding(.top, 8)
            }
        }
    }
    
    // MARK: - Import Preview View
    
    private func importPreviewView(result: CSVImportResult) -> some View {
        VStack(spacing: 16) {
            // Summary
            VStack(spacing: 8) {
                HStack {
                    Text("Import Summary")
                        .font(.headline)
                    Spacer()
                    Button("Select Different File") {
                        importResult = nil
                        selectedFileURL = nil
                        errorMessage = nil
                    }
                    .font(.caption)
                }
                
                HStack(spacing: 20) {
                    VStack {
                        Text("\(result.validRows.count)")
                            .font(.title2)
                            .bold()
                            .foregroundColor(.green)
                        Text("Valid")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack {
                        Text("\(result.invalidRows.count)")
                            .font(.title2)
                            .bold()
                            .foregroundColor(.red)
                        Text("Invalid")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if !result.duplicateNames.isEmpty {
                        VStack {
                            Text("\(result.duplicateNames.count)")
                                .font(.title2)
                                .bold()
                                .foregroundColor(.orange)
                            Text("Duplicates")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding()
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)
            
            // Duplicate handling
            if !result.duplicateNames.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Duplicate Handling")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Picker("", selection: $duplicateHandling) {
                        Text("Skip duplicates").tag(DuplicateHandling.skip)
                        Text("Update existing").tag(DuplicateHandling.update)
                        Text("Create new with suffix").tag(DuplicateHandling.createNew)
                    }
                    .pickerStyle(.segmented)
                }
            }
            
            // Preview table
            VStack(alignment: .leading, spacing: 8) {
                Text("Preview (first 5 rows)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                ScrollView {
                    LazyVStack(spacing: 4) {
                        // Header
                        HStack {
                            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Year").frame(width: 60)
                            Text("Status").frame(width: 80)
                            Text("Amount").frame(width: 80)
                            Text("Notes").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.2))
                        
                        // Rows
                        ForEach(Array(result.rows.prefix(5).enumerated()), id: \.offset) { _, row in
                            HStack {
                                Text(row.name)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                                Text("\(row.year)")
                                    .frame(width: 60)
                                Text(row.status)
                                    .frame(width: 80)
                                    .lineLimit(1)
                                Text(row.amount?.formatted(.currency(code: "USD")) ?? "")
                                    .frame(width: 80)
                                Text(row.notes)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(row.isValid ? Color.clear : Color.red.opacity(0.1))
                            .overlay(
                                Rectangle()
                                    .frame(height: 0.5)
                                    .foregroundColor(.gray.opacity(0.3)),
                                alignment: .bottom
                            )
                        }
                        
                        if result.rows.count > 5 {
                            Text("... and \(result.rows.count - 5) more rows")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                        }
                    }
                }
                .frame(height: 150)
                .background(Color.gray.opacity(0.05))
                .cornerRadius(8)
            }
            
            // Error summary
            if !result.invalidRows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Errors:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.red)
                    
                    ForEach(Array(result.invalidRows.prefix(3).enumerated()), id: \.offset) { _, row in
                        Text("Line \(row.lineNumber): \(row.errors.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    
                    if result.invalidRows.count > 3 {
                        Text("... and \(result.invalidRows.count - 3) more errors")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
            }
            
            Spacer()
            
            // Action buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                
                Button("Import \(result.validRows.count) Items") {
                    performImport(result: result)
                }
                .buttonStyle(.borderedProminent)
                .disabled(result.validRows.isEmpty || isImporting)
            }
            
            if isImporting {
                ProgressView("Creating placeholders...")
                    .padding(.top, 8)
            }
        }
    }
    
    // MARK: - Actions
    
    private func selectCSVFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Select a CSV file to import"
        
        if panel.runModal() == .OK, let url = panel.url {
            selectedFileURL = url
            parseCSVFile(url: url)
        }
    }
    
    private func parseCSVFile(url: URL) {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let data = try Data(contentsOf: url)
                let currentYear = Calendar.current.component(.year, from: .now)
                let defaultStatus = model.defaultStatus()
                
                let result = CSVParser.parseCSV(
                    data: data,
                    defaultYear: currentYear,
                    defaultStatus: defaultStatus
                )
                
                // Update with existing items for duplicate detection
                let resultWithDuplicates = CSVImportResult(
                    rows: result.rows,
                    existingItems: model.items
                )
                
                await MainActor.run {
                    self.importResult = resultWithDuplicates
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to read CSV file: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
    
    private func performImport(result: CSVImportResult) {
        isImporting = true
        
        Task {
            var draftsToCreate: [DraftMeta] = []
            var itemsToUpdate: [DocumentItem] = []
            
            for row in result.validRows {
                // Check for duplicates based on selected handling
                let shouldSkip = result.duplicateNames.contains(row.name.lowercased()) && duplicateHandling == .skip
                
                if !shouldSkip {
                    var finalName = row.name
                    
                    // Handle duplicates
                    if result.duplicateNames.contains(row.name.lowercased()) {
                        if duplicateHandling == .update {
                            // Find and update existing item
                            if let existingItem = model.items.first(where: { $0.meta.name.lowercased() == row.name.lowercased() }) {
                                var updatedItem = existingItem
                                updatedItem.meta.status = row.status
                                updatedItem.meta.amount = row.amount
                                updatedItem.meta.notes = row.notes
                                updatedItem.meta.year = row.year
                                
                                itemsToUpdate.append(updatedItem)
                                continue
                            }
                        } else if duplicateHandling == .createNew {
                            // Add suffix to make name unique
                            var suffix = 1
                            while model.items.contains(where: { $0.meta.name.lowercased() == "\(row.name) (\(suffix))".lowercased() }) {
                                suffix += 1
                            }
                            finalName = "\(row.name) (\(suffix))"
                        }
                    }
                    
                    // Prepare draft for bulk creation
                    let draft = DraftMeta(
                        name: finalName,
                        amount: row.amount,
                        notes: row.notes,
                        status: row.status,
                        year: row.year
                    )
                    
                    draftsToCreate.append(draft)
                }
            }
            
            // Update existing items first
            await MainActor.run {
                for item in itemsToUpdate {
                    model.update(item)
                }
            }
            
            // Bulk create new placeholders - this will only prompt for access once
            if !draftsToCreate.isEmpty {
                await MainActor.run {
                    model.createBulkPlaceholders(draftsToCreate)
                }
            }
            
            await MainActor.run {
                self.isImporting = false
                self.isPresented = false
                
                // Show success message or handle completion as needed
                let totalImported = itemsToUpdate.count + draftsToCreate.count
                print("Successfully imported \(totalImported) items from CSV")
            }
        }
    }
}

#Preview {
    ImportCSVSheet(isPresented: .constant(true))
        .environmentObject(AppModel())
}