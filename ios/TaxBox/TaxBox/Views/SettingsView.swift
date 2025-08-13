import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("TaxBox Settings")
                .font(.largeTitle)
                .fontWeight(.semibold)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Document Storage Location")
                    .font(.headline)
                
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.secondary)
                    
                    Text(model.root.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(6)
                    
                    Button("Choose...") {
                        model.selectNewRootFolder()
                    }
                }
                
                Text("This is where all your tax documents are stored.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Import Behavior")
                    .font(.headline)
                
                Toggle("Copy files when importing (safer)", isOn: $model.copyOnImport)
                
                Text(model.copyOnImport ? 
                     "Files will be copied to TaxBox, leaving originals in place." : 
                     "Files will be moved to TaxBox, removing them from their original location.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Status Options")
                    .font(.headline)
                
                StatusManagementView()
                    .environmentObject(model)
                
                Text("Customize the status options available for your documents.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(30)
        .frame(width: 500, height: 450)
    }
}

struct StatusManagementView: View {
    @EnvironmentObject var model: AppModel
    @State private var newStatusName = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.availableStatuses, id: \.self) { status in
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 8))
                    
                    Text(status)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if model.availableStatuses.count > 1 {
                        Button(action: { model.removeStatus(status) }) {
                            Image(systemName: "minus.circle")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.05))
                .cornerRadius(6)
            }
            
            HStack {
                TextField("New status name", text: $newStatusName)
                    .textFieldStyle(.roundedBorder)
                
                Button("Add") {
                    model.addStatus(newStatusName)
                    newStatusName = ""
                }
                .disabled(newStatusName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}