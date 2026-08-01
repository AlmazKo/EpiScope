import AppKit

@main
enum EpiScopeMain {
    private static let delegate = AppDelegate()

    static func main() {
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }
}
