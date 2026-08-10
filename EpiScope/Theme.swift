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

        // Session lifecycle strip. These are opaque on purpose: the phases
        // tile the whole bar, and translucent label greys composited over the
        // groove turned every session into one flat slab. Idle and Away are
        // deliberately quiet — a month-long session is mostly Away, and it
        // should read as an empty track with work marked on it, not as a
        // painted bar. Working and Permission double as the summary line's
        // text colour, so both stay dark enough to read at 10pt.
        let lifeWorking: NSColor
        let lifePermission: NSColor
        let lifeIdle: NSColor
        let lifeAway: NSColor
        let lifeTrack: NSColor        // groove under the phases, and its edge
        let lifeEdit: NSColor
        let lifeError: NSColor
        let lifeInterrupt: NSColor
        let lifeCompact: NSColor
    }

    static let light = Tokens(
        diffAdded:   NSColor(srgbRed: 0.102, green: 0.498, blue: 0.216, alpha: 1),  // #1a7f37
        diffRemoved: NSColor(srgbRed: 0.812, green: 0.133, blue: 0.180, alpha: 1),  // #cf222e

        lifeWorking:    NSColor(srgbRed: 0.102, green: 0.498, blue: 0.216, alpha: 1),  // #1a7f37
        lifePermission: NSColor(srgbRed: 0.812, green: 0.133, blue: 0.180, alpha: 1),  // #cf222e
        lifeIdle:       NSColor(srgbRed: 0.847, green: 0.871, blue: 0.894, alpha: 1),  // #d8dee4
        lifeAway:       NSColor(srgbRed: 0.918, green: 0.933, blue: 0.949, alpha: 1),  // #eaeef2
        lifeTrack:      NSColor(srgbRed: 0.965, green: 0.973, blue: 0.980, alpha: 1),  // #f6f8fa
        lifeEdit:       NSColor(srgbRed: 0.059, green: 0.486, blue: 0.525, alpha: 1),  // #0f7c86
        lifeError:      NSColor(srgbRed: 0.812, green: 0.133, blue: 0.180, alpha: 1),  // #cf222e
        lifeInterrupt:  NSColor(srgbRed: 0.737, green: 0.298, blue: 0.000, alpha: 1),  // #bc4c00
        lifeCompact:    NSColor(srgbRed: 0.510, green: 0.314, blue: 0.875, alpha: 1)   // #8250df
    )

    static let dark = Tokens(
        diffAdded:   NSColor(srgbRed: 0.247, green: 0.725, blue: 0.314, alpha: 1),  // #3fb950
        diffRemoved: NSColor(srgbRed: 0.973, green: 0.318, blue: 0.286, alpha: 1),  // #f85149

        lifeWorking:    NSColor(srgbRed: 0.247, green: 0.725, blue: 0.314, alpha: 1),  // #3fb950
        lifePermission: NSColor(srgbRed: 0.973, green: 0.318, blue: 0.286, alpha: 1),  // #f85149
        lifeIdle:       NSColor(srgbRed: 0.188, green: 0.212, blue: 0.239, alpha: 1),  // #30363d
        lifeAway:       NSColor(srgbRed: 0.129, green: 0.149, blue: 0.176, alpha: 1),  // #21262d
        lifeTrack:      NSColor(srgbRed: 0.086, green: 0.106, blue: 0.133, alpha: 1),  // #161b22
        lifeEdit:       NSColor(srgbRed: 0.224, green: 0.773, blue: 0.812, alpha: 1),  // #39c5cf
        lifeError:      NSColor(srgbRed: 0.973, green: 0.318, blue: 0.286, alpha: 1),  // #f85149
        lifeInterrupt:  NSColor(srgbRed: 0.859, green: 0.427, blue: 0.157, alpha: 1),  // #db6d28
        lifeCompact:    NSColor(srgbRed: 0.639, green: 0.443, blue: 0.969, alpha: 1)   // #a371f7
    )

    // MARK: - Dynamic colours (what views actually use)

    static let diffAdded = dynamic(\.diffAdded)
    static let diffRemoved = dynamic(\.diffRemoved)

    static let lifeWorking = dynamic(\.lifeWorking)
    static let lifePermission = dynamic(\.lifePermission)
    static let lifeIdle = dynamic(\.lifeIdle)
    static let lifeAway = dynamic(\.lifeAway)
    static let lifeTrack = dynamic(\.lifeTrack)
    static let lifeEdit = dynamic(\.lifeEdit)
    static let lifeError = dynamic(\.lifeError)
    static let lifeInterrupt = dynamic(\.lifeInterrupt)
    static let lifeCompact = dynamic(\.lifeCompact)

    private static func dynamic(_ token: KeyPath<Tokens, NSColor>) -> NSColor {
        NSColor(name: nil) { appearance in
            let set = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? dark : light
            return set[keyPath: token]
        }
    }
}
