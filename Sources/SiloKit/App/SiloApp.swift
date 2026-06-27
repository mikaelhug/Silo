import SwiftUI

/// The SwiftUI application. Call `SiloApp.main()` to launch (see the `silo` executable target).
public struct SiloApp: App {
    @State private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .frame(minWidth: 920, minHeight: 600)
                .task { await environment.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    // Returning to Silo (e.g. after downloading games in Steam) re-scans the library.
                    if phase == .active { Task { await environment.refreshLibraryIfReady() } }
                }
        }
        .windowToolbarStyle(.unified)

        // Logs open as independent windows so they stay up (live-tailing) while you drive the main
        // window — e.g. watching steam.log while pressing "Open Steam".
        WindowGroup(id: "silo-log", for: LogTarget.self) { $target in
            if let target {
                LogViewerView(title: target.title, url: target.url)
            }
        }
    }
}
