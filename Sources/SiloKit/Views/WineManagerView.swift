import SwiftUI

/// The Wine Manager: a GPTK tab (import Apple .dmg) and a Wine tab (install prebuilt Wine builds).
struct WineManagerView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case gptk = "GPTK"
        case wine = "Wine"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .gptk

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            Divider()

            switch tab {
            case .gptk: GPTKManagerView()
            case .wine: WineDownloadView()
            }
        }
        .navigationTitle("Wine Manager")
    }
}
