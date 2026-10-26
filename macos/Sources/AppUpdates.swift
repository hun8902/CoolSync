import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

final class MacUpdates {
    static let shared=MacUpdates()
    #if canImport(Sparkle)
    private var controller:SPUStandardUpdaterController?
    #endif
    func start() {
        #if canImport(Sparkle)
        guard controller == nil else { return }
        controller=SPUStandardUpdaterController(startingUpdater:true,updaterDelegate:nil,userDriverDelegate:nil)
        #endif
    }
    func check() {
        #if canImport(Sparkle)
        start();controller?.checkForUpdates(nil)
        #else
        NSWorkspace.shared.open(URL(string:"https://github.com/hun8902/CoolSync/releases")!)
        #endif
    }
}
