
import SwiftUI

@main
struct WatchZoneApp: App {
    init() {
        #if DEBUG
        let b = Bundle.main
        print("GAMEON_DEBUG bundlePath=\(b.bundlePath)")
        print("GAMEON_DEBUG executablePath=\(b.executablePath ?? "(nil)")")
        print("GAMEON_DEBUG bundleIdentifier=\(b.bundleIdentifier ?? "(nil)")")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.light)
        }
    }
}
