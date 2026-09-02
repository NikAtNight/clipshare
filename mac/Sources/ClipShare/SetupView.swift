import SwiftUI

struct SetupView: View {
    @Bindable var model: AppModel
    let isSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect ClipShare")
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 8) {
                TextField("Server", text: $model.setup.serverURLText)
                    .textFieldStyle(.roundedBorder)
                SecureField("Paste your owner token", text: $model.setup.tokenText)
                    .textFieldStyle(.roundedBorder)
                Text("The token lives in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let errorMessage = model.setup.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if isSettings {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Drop target", selection: dropPanelCornerSelection) {
                        ForEach(DropPanelCorner.allCases) { corner in
                            Text(corner.shortLabel)
                                .help(corner.label)
                                .tag(corner)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("The floating card appears in this corner while you drag a video.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Position drop target…") {
                        model.isPositioningPanel = true
                    }
                }
            }

            HStack {
                if isSettings {
                    Button("Sign Out") {
                        model.signOut()
                    }
                }
                Spacer()
                if isSettings {
                    Button("Cancel", role: .cancel) {
                        model.isShowingSettings = false
                    }
                }
                Button {
                    model.saveSetup()
                } label: {
                    if model.setup.isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Connect")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    model.setup.isSaving
                        || model.setup.serverURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.setup.tokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(16)
    }

    private var dropPanelCornerSelection: Binding<DropPanelCorner> {
        Binding {
            model.dropPanelCorner
        } set: { corner in
            DropPanel.clearSavedOrigin()
            model.dropPanelCorner = corner
        }
    }
}
