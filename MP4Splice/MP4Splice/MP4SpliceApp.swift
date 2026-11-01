import SwiftUI

@main
struct MP4SpliceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 640, minHeight: 460)
        }
        .windowResizability(.contentMinSize)
    }
}
