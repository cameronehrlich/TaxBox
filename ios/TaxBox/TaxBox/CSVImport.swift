import Foundation

// MARK: - CSV Import Data Structures

struct CSVImportRow {
    let lineNumber: Int
    let name: String
    let year: Int
    let status: String
    let amount: Double?
    let notes: String
    let isValid: Bool
    let errors: [String]
    
    init(lineNumber: Int, name: String, year: Int, status: String, amount: Double?, notes: String) {
        self.lineNumber = lineNumber
        self.name = name
        self.year = year
        self.status = status
        self.amount = amount
        self.notes = notes
        
        var errors: [String] = []
        
        // Validate name (required)
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Name is required")
        }
        
        // Validate year range
        if year < 1980 || year > 2100 {
            errors.append("Year must be between 1980 and 2100")
        }
        
        self.errors = errors
        self.isValid = errors.isEmpty
    }
}

struct CSVImportResult {
    let rows: [CSVImportRow]
    let validRows: [CSVImportRow]
    let invalidRows: [CSVImportRow]
    let totalRows: Int
    let duplicateNames: Set<String>
    
    init(rows: [CSVImportRow], existingItems: [DocumentItem]) {
        self.rows = rows
        self.validRows = rows.filter { $0.isValid }
        self.invalidRows = rows.filter { !$0.isValid }
        self.totalRows = rows.count
        
        // Find duplicates with existing items
        let existingNames = Set(existingItems.map { $0.meta.name.lowercased() })
        let importNames = rows.compactMap { $0.isValid ? $0.name.lowercased() : nil }
        self.duplicateNames = Set(importNames.filter { existingNames.contains($0) })
    }
}

enum DuplicateHandling {
    case skip
    case update
    case createNew
}

// MARK: - CSV Parser

struct CSVParser {
    static func parseCSV(data: Data, defaultYear: Int, defaultStatus: String) -> CSVImportResult {
        guard let content = String(data: data, encoding: .utf8) else {
            return CSVImportResult(rows: [], existingItems: [])
        }
        
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard !lines.isEmpty else {
            return CSVImportResult(rows: [], existingItems: [])
        }
        
        // Parse header row
        let headerLine = lines[0]
        let headers = parseCSVLine(headerLine).map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        
        // Find column indices
        let nameIndex = headers.firstIndex(of: "name")
        let yearIndex = headers.firstIndex(of: "year")
        let statusIndex = headers.firstIndex(of: "status")
        let amountIndex = headers.firstIndex(of: "amount")
        let notesIndex = headers.firstIndex(of: "notes")
        
        var rows: [CSVImportRow] = []
        
        // Parse data rows
        for (index, line) in lines.dropFirst().enumerated() {
            let values = parseCSVLine(line)
            let lineNumber = index + 2 // +2 because we're 1-indexed and skipped header
            
            // Extract values with safe indexing
            let name = nameIndex.flatMap { values.indices.contains($0) ? values[$0] : nil } ?? ""
            let yearStr = yearIndex.flatMap { values.indices.contains($0) ? values[$0] : nil } ?? ""
            let status = statusIndex.flatMap { values.indices.contains($0) ? values[$0] : nil } ?? defaultStatus
            let amountStr = amountIndex.flatMap { values.indices.contains($0) ? values[$0] : nil } ?? ""
            let notes = notesIndex.flatMap { values.indices.contains($0) ? values[$0] : nil } ?? ""
            
            // Parse year
            let year: Int
            if let parsedYear = Int(yearStr.trimmingCharacters(in: .whitespacesAndNewlines)), parsedYear > 0 {
                year = parsedYear
            } else {
                year = defaultYear
            }
            
            // Parse amount
            let amount: Double?
            let cleanAmountStr = amountStr.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
            
            if cleanAmountStr.isEmpty {
                amount = nil
            } else if let parsedAmount = Double(cleanAmountStr) {
                amount = parsedAmount
            } else {
                amount = nil
            }
            
            let row = CSVImportRow(
                lineNumber: lineNumber,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                year: year,
                status: status.trimmingCharacters(in: .whitespacesAndNewlines),
                amount: amount,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            
            rows.append(row)
        }
        
        return CSVImportResult(rows: rows, existingItems: [])
    }
    
    private static func parseCSVLine(_ line: String) -> [String] {
        var values: [String] = []
        var currentValue = ""
        var insideQuotes = false
        var i = line.startIndex
        
        while i < line.endIndex {
            let char = line[i]
            
            if char == "\"" {
                if insideQuotes {
                    // Check if this is an escaped quote
                    let nextIndex = line.index(after: i)
                    if nextIndex < line.endIndex && line[nextIndex] == "\"" {
                        currentValue.append("\"")
                        i = line.index(after: nextIndex)
                        continue
                    } else {
                        insideQuotes = false
                    }
                } else {
                    insideQuotes = true
                }
            } else if char == "," && !insideQuotes {
                values.append(currentValue)
                currentValue = ""
            } else {
                currentValue.append(char)
            }
            
            i = line.index(after: i)
        }
        
        values.append(currentValue)
        return values
    }
}