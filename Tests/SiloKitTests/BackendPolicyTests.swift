import Testing
@testable import SiloKit

@Suite("BackendPolicy")
struct BackendPolicyTests {

    @Test("recommends GPTK whenever it's installed (handles DirectX 9–12 on Apple Silicon)")
    func recommendsGPTKWhenInstalled() {
        #expect(BackendPolicy.recommended(gptkInstalled: true, crossoverInstalled: true) == .gptk)
        #expect(BackendPolicy.recommended(gptkInstalled: true, crossoverInstalled: false) == .gptk)
        #expect(BackendPolicy.recommended(gptkInstalled: true, crossoverInstalled: true) == .gptk)
    }

    @Test("recommends CrossOver only when GPTK isn't installed")
    func recommendsCrossOverWithoutGPTK() {
        #expect(BackendPolicy.recommended(gptkInstalled: false, crossoverInstalled: true) == .crossover)
        #expect(BackendPolicy.recommended(gptkInstalled: false, crossoverInstalled: false) == .gptk)
    }

    @Test("effective backend falls back to CrossOver when GPTK is requested but not installed")
    func effectiveFallsBack() {
        #expect(BackendPolicy.effective(requested: .gptk, gptkInstalled: false, crossoverInstalled: true) == .crossover)
        #expect(BackendPolicy.effective(requested: .gptk, gptkInstalled: true, crossoverInstalled: true) == .gptk)
        #expect(BackendPolicy.effective(requested: .crossover, gptkInstalled: true, crossoverInstalled: false) == .gptk)
        #expect(BackendPolicy.effective(requested: .crossover, gptkInstalled: true, crossoverInstalled: true) == .crossover)
    }

    @Test("parses the major DirectX version from store requirements text")
    func parsesDirectX() {
        #expect(SteamStoreClient.directXVersion(in: "OS: Windows 10\nDirectX: Version 12\nStorage: 50 GB") == 12)
        #expect(SteamStoreClient.directXVersion(in: "DirectX 9.0c compatible") == 9)
        #expect(SteamStoreClient.directXVersion(in: "DirectX®11") == 11)
        #expect(SteamStoreClient.directXVersion(in: "OS: Windows 7\nMemory: 8 GB") == nil)
    }
}
