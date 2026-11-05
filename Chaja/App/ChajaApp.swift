import SwiftUI

@main
struct ChajaApp: App {
    var body: some Scene {
        WindowGroup("Chaja") {
            ContentView()
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
    }
}
