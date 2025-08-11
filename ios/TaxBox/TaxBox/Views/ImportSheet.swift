import SwiftUI

struct ImportSheet: View {
    let urls: [URL]
    @Binding var draft: DraftMeta
    @EnvironmentObject var model: AppModel
    var completion: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Documents").font(.title2).bold()
            Text("\(urls.count) file(s)")
            TextField("Name", text: $draft.name)
            HStack {
                Text("Amount")
                TextField("$0.00", value: Binding(get: { draft.amount ?? 0 }, set: { v in draft.amount = v == 0 ? nil : v }), format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
            }
            TextField("Notes", text: $draft.notes, axis: .vertical)
            Picker("Status", selection: $draft.status) { 
                ForEach(model.availableStatuses, id: \.self) { status in
                    Text(status).tag(status)
                }
            }
            Stepper(value: $draft.year, in: 1980...2100) { Text("Year: \(String(draft.year))") }
            HStack { Spacer(); Button("Cancel") { completion(false) }; Button("Add") { completion(true) }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
    }
}