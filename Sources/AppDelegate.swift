import AppKit

// TIER 2 — UNVERIFIED. Never compiled, never run. Depends on runtime
// behavior that was not observable when written. Rewrite freely.
// Do NOT patch symptom-by-symptom.

/// Entry point. LSUIElement in Info.plist keeps this Dock- and window-free;
/// MenuBarController.start() is the only thing that runs.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let menuBarController = MenuBarController()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // `delegate` stays alive as a local var for as long as app.run() blocks,
        // which is the whole process lifetime — NSApplication.delegate is weak.
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController.start()
    }
}
