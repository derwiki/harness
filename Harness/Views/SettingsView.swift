//
//  SettingsView.swift
//  Harness
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.modelIDKey) private var modelID = AppSettings.defaultModelID
    /// Only holds a newly typed key. The stored key is never loaded into the UI.
    @State private var newAPIKey = ""
    @State private var hasStoredKey = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(hasStoredKey ? "Enter a new key to replace it" : "sk-or-…", text: $newAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if hasStoredKey {
                        Button("Remove Key", role: .destructive, action: removeKey)
                    }
                } header: {
                    Text("OpenRouter API Key")
                } footer: {
                    Text(hasStoredKey ? "A key is stored in the Keychain." : "No key is stored.")
                }

                Section {
                    TextField("provider/model", text: $modelID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("Custom Model ID")
                } footer: {
                    Text("Any OpenRouter model slug that supports tool calling. If it is not a preset, it shows as an extra option in the New Chat menu. Requests only route to zero-data-retention endpoints.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: saveAndDismiss)
                }
            }
            .onAppear {
                hasStoredKey = KeychainStore.readAPIKey() != nil
            }
        }
    }

    private func saveAndDismiss() {
        let key = newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            do {
                try KeychainStore.saveAPIKey(key)
            } catch {
                errorMessage = "Could not save the key: \(error.localizedDescription)"
                return
            }
        }
        modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
    }

    private func removeKey() {
        do {
            try KeychainStore.deleteAPIKey()
            hasStoredKey = false
        } catch {
            errorMessage = "Could not remove the key: \(error.localizedDescription)"
        }
    }
}

#Preview {
    SettingsView()
}
