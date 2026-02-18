import AppKit

@main
struct AudioScribeApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate

        // Set activation policy to accessory (no dock icon)
        app.setActivationPolicy(.accessory)

        app.run()
    }
}
