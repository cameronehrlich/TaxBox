import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var showFolderPicker = false
    
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
                        showFolderPicker = true
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
            
            Spacer()
        }
        .padding(30)
        .frame(width: 500, height: 300)
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.root = url
                    model.bootstrap()
                }
            case .failure(let error):
                print("Folder selection failed: \(error)")
            }
        }
    }
}