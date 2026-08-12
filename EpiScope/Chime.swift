import AppKit

// The alert chime: which system sound answers a permission prompt, and how it
// is played. Lives apart from the code that decides *when* to chime so the
// menu-bar path and the settings pane share one list, one default and one
// player — a preview that sounded different from the alarm would be a lie.
@MainActor
enum Chime {
    static let none = "None"
    static let defaultName = "Glass"
    static let choices: [String] = [
        none,
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass",
        "Hero", "Morse", "Ping", "Pop", "Purr",
        "Sosumi", "Submarine", "Tink",
    ]

    private static let key = "chimeSound"

    static var name: String {
        get { UserDefaults.standard.string(forKey: key) ?? defaultName }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var isOn: Bool { name != none }

    static func playCurrent() {
        guard isOn else { return }
        play(name)
    }

    // Short alert chime via /usr/bin/afplay — a throwaway child process plays
    // the file (on the main output, i.e. master volume) and exits. Any in-process
    // audio API (AVAudioPlayer, AudioServices, NSSound) initialises CoreAudio in
    // *our* process and leaves its threads warm; afplay keeps all of that in the
    // child, so EpiScope spins up no audio threads at all. Falls back to NSSound
    // if afplay is somehow unavailable.
    static func play(_ name: String) {
        guard name != none else { return }
        let path = "/System/Library/Sounds/\(name).aiff"
        guard FileManager.default.fileExists(atPath: path) else {
            NSSound(named: name)?.play()
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = [path]
        // Hold the Process until it exits so its child is reaped (no zombie);
        // the handler drops it once afplay finishes.
        p.terminationHandler = { proc in
            DispatchQueue.main.async { inFlight.removeAll { $0 === proc } }
        }
        do {
            try p.run()
            inFlight.append(p)
        } catch {
            NSSound(named: name)?.play()
        }
    }

    // afplay children in flight, kept alive until they exit (see above).
    private static var inFlight: [Process] = []
}
