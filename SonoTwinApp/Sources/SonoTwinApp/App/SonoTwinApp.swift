import AppKit

// MARK: - @main Entry Point
// The @main attribute marks this as the application's entry point.
// When the app launches, Swift automatically calls the static main() function.
// This is an alternative to using SwiftUI's @main App protocol.

@main
struct SonoTwinApp {
    static func main() {
        // NSApplication.shared is the singleton representing our running application.
        // In AppKit (macOS), every app has exactly one NSApplication instance.
        let app = NSApplication.shared

        // The delegate receives lifecycle events (launch, terminate, etc.).
        // We create our custom AppDelegate to handle these events.
        let delegate = AppDelegate()
        app.delegate = delegate

        // .accessory policy means the app won't show in the Dock.
        // This is typical for menu bar-only apps (like Dropbox, 1Password, etc.).
        // Other options: .regular (normal app), .prohibited (background only)
        app.setActivationPolicy(.accessory)

        // app.run() starts the main event loop and never returns.
        // From this point, the app responds to user interactions until terminated.
        app.run()
    }
}
