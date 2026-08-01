import AppKit

/// Entry point. A normal, Dock-visible app — MenuBarController.start() sets
/// up the window that's the whole UI.
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

    /// Without this, closing the window (red button) leaves no way to bring
    /// it back — there's no menu bar icon anymore, and clicking the Dock
    /// icon with no visible windows does nothing by default.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            menuBarController.reopenWindow()
        }
        return true
    }
}
