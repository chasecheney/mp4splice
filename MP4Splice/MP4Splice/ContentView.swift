import SwiftUI

struct ContentView: View {
    enum Tab { case join, split }
    @State private var selection: Tab = .join

    var body: some View {
        TabView(selection: $selection) {
            JoinView()
                .tabItem { Label("Join", systemImage: "square.stack.3d.down.right") }
                .tag(Tab.join)

            SplitView()
                .tabItem { Label("Split", systemImage: "scissors") }
                .tag(Tab.split)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
