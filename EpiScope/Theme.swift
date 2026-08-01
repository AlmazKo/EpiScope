import AppKit

// Design tokens, one explicit set per appearance. Views reference the
// dynamic colours (Theme.diffAdded etc.) — those resolve against the
// current appearance at draw time, so theme switches repaint correctly
// without any invalidation code. To tune a colour, edit the light /
// dark token sets; nothing else needs touching.
enum Theme {
    struct Tokens {
        // Git-diff palette (GitHub's): deep tones for light mode where
        // bright system colours wash out, bright tones for dark mode.
        let diffAdded: NSColor
        let diffRemoved: NSColor
    }

    static let light = Tokens(
        diffAdded:   NSColor(srgbRed: 0.102, green: 0.498, blue: 0.216, alpha: 1),  // #1a7f37
        diffRemoved: NSColor(srgbRed: 0.812, green: 0.133, blue: 0.180, alpha: 1)   // #cf222e
    )

    static let dark = Tokens(
        diffAdded:   NSColor(srgbRed: 0.247, green: 0.725, blue: 0.314, alpha: 1),  // #3fb950
        diffRemoved: NSColor(srgbRed: 0.973, green: 0.318, blue: 0.286, alpha: 1)   // #f85149
    )

    // MARK: - Dynamic colours (what views actually use)

    static let diffAdded = dynamic(\.diffAdded)
    static let diffRemoved = dynamic(\.diffRemoved)

    private static func dynamic(_ token: KeyPath<Tokens, NSColor>) -> NSColor {
        NSColor(name: nil) { appearance in
            let set = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? dark : light
            return set[keyPath: token]
        }
    }
}
