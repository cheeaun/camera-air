import SwiftUI

@main
struct CameraAirApp: App {
    var body: some Scene {
        WindowGroup {
            CameraRootView()
                .preferredColorScheme(.dark)
        }
    }
}
