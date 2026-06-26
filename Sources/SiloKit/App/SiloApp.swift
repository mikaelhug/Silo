import SwiftUI

/// The SwiftUI application. Call `SiloApp.main()` to launch (see the `silo` executable target).
public struct SiloApp: App {
    @State private var environment = AppEnvironment()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .frame(minWidth: 920, minHeight: 600)
                .task { await environment.bootstrap() }
        }
        .windowToolbarStyle(.unified)
    }
}
