import SwiftUI

@main
struct MP4SpliceApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 640, minHeight: 460)
        }
        .windowResizability(.contentMinSize)
    }
}
