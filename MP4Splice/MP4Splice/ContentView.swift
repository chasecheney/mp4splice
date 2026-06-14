import SwiftUI

struct ContentView: View {
    enum Tab { case join, split, queue }
    @State private var selection: Tab = .join
    @StateObject private var queue = JobQueue()

    var body: some View {
        TabView(selection: $selection) {
            JoinView()
                .tabItem { Label("Join", systemImage: "square.stack.3d.down.right") }
                .tag(Tab.join)

            SplitView()
                .tabItem { Label("Split", systemImage: "scissors") }
                .tag(Tab.split)

            QueueView()
                .tabItem { Label("Queue", systemImage: "list.bullet.rectangle") }
                .badge(queue.activeCount)
                .tag(Tab.queue)
        }
        .padding()
        .environmentObject(queue)
    }
}

#Preview {
    ContentView()
}
