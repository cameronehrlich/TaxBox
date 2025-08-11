import Foundation

struct DraftMeta {
    var name: String
    var amount: Double?
    var notes: String
    var status: String
    var year: Int

    static func from(urls: [URL]) -> DraftMeta {
        let base = urls.first?.deletingPathExtension().lastPathComponent ?? ""
        let y = Calendar.current.component(.year, from: .now)
        return DraftMeta(name: base, amount: nil, notes: "", status: "Done", year: y)
    }
}