import SwiftUI

struct ContentView: View {
    private let appGroupID = "group.com.MeBoard.MeBoard"
    private let key = "stored_text_entries"

    @State private var savedItems: [String] = []
    @State private var containerPath: String = "(not checked)"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App Group container:")
                .font(.headline)
            Text(containerPath)
                .font(.footnote)
                .textSelection(.enabled)

            Button("Refresh") { load() }

            List(savedItems, id: \.self) { Text($0) }
        }
        .padding()
        .onAppear { load() }
    }

    private func load() {
        let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )
        containerPath = url?.path ?? "NIL (entitlement not applied)"

        let defaults = UserDefaults(suiteName: appGroupID)
        savedItems = defaults?.stringArray(forKey: key) ?? []
    }
}
