import SwiftUI

struct SettingsView: View { 
    @EnvironmentObject var model: AppModel
    
    var body: some View { 
        Form { 
            Toggle("Copy files on import (safer)", isOn: $model.copyOnImport) 
            Text("Root: \(model.root.path)") 
        } 
        .padding(20) 
    } 
}