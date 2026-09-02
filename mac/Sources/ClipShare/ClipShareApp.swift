import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var dropPanelController: DropPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        dropPanelController = DropPanelController(model: AppModel.shared)
    }
}

@main
struct ClipShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra("ClipShare", systemImage: "arrow.up.circle") {
            AppContentView(model: model)
                .frame(width: 360)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct AppContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if !model.hasLoadedConfiguration {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else if model.isShowingSettings {
                    SetupView(model: model, isSettings: true)
                } else if model.setup.isConfigured {
                    MainView(model: model)
                } else {
                    SetupView(model: model, isSettings: false)
                }
            }

            if let toast = model.toast {
                Text(toast)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 3, y: 1)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
    }
}
