import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: ConfigStore
    @State private var showDebug = false

    var body: some View {
        ZStack {
            HandSceneView(model: model)
                .ignoresSafeArea()

            GlassChrome(showDebug: $showDebug)

            if model.calibrating { CalibrationView() }
        }
        .foregroundStyle(.white)
        .onAppear { model.start() }
        .sheet(isPresented: $showDebug) {
            DebugSettingsView()
                .environmentObject(store)
                .environmentObject(model)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }
}

