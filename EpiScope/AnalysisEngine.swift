import Foundation

// Which local CLI runs an analysis. Both bring the user's own login and plan,
// so EpiScope still holds no key and opens no socket.
//
// Deliberately an axis with exhaustive switches rather than a flag read off the
// model name: a third engine must fail to compile here instead of silently
// inheriting Claude's argv and Claude's result parser. The model string alone
// cannot answer this — `gpt-5.6-terra` is a Codex model, but a Claude CLI
// pointed at a gateway could be asked for one too.
nonisolated enum AnalysisEngine: String, Codable, Sendable, CaseIterable {
    case claude
    case codex

    var cliName: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }

    // Section header in Settings → Analysis Model. Names the CLI, not the
    // vendor: it is the thing that has to be installed and logged in.
    var menuHeading: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    func locate() -> URL? {
        switch self {
        case .claude: return ClaudeCLI.locate()
        case .codex: return CodexCLI.locate()
        }
    }

    // Where the agent's final answer ends up. Claude prints a result object on
    // stdout; Codex streams events and writes the last message to a file we
    // name, which is more robust than picking it out of the stream.
    func lastMessageURL(in workDir: URL) -> URL? {
        switch self {
        case .claude: return nil
        case .codex: return workDir.appending(path: "last-message.md")
        }
    }

    func arguments(for request: AnalysisRequest) -> [String] {
        switch self {
        case .claude:
            var args = [
                "-p",
                "--output-format", "json",
                "--model", request.model,
                "--max-turns", String(request.maxTurns),
                "--allowedTools", "Read,Grep,Glob",
                // --allowedTools pre-approves tools; it does not disable the rest.
                // Without the three flags below the run would inherit the user's
                // own permissions.allow, defaultMode and MCP servers — so how
                // contained this agent is would depend on how somebody else
                // configured their CLI, while it chews on transcript text written
                // by whoever the observed sessions talked to.
                "--disallowedTools",
                "Bash,Write,Edit,MultiEdit,NotebookEdit,WebFetch,WebSearch,Task",
                "--permission-mode", "default",
                "--strict-mcp-config",
            ]
            for dir in request.addDirs { args += ["--add-dir", dir.path] }
            return args

        case .codex:
            var args = [
                "exec",
                "--json",
                // Reads are what the analysis needs and all it gets. Note this
                // also makes --add-dir unnecessary: that flag grants *write*
                // access, and a read-only sandbox already reads the packets.
                "--sandbox", "read-only",
                // The scratch dir is not a repo, and Codex refuses to run
                // outside one without this.
                "--skip-git-repo-check",
                // The counterpart of Claude's --strict-mcp-config. Deliberately
                // this rather than --ignore-user-config: that flag would also
                // discard the user's `model`, and the model a Codex user wants
                // is the one already in their config.toml.
                "-c", "mcp_servers={}",
                // Analysis runs are EpiScope's own business; they should not
                // pile up in the user's Codex history. It also keeps them out
                // of ~/.codex/sessions, which the indexer watches — every run
                // would otherwise wake a scan.
                "--ephemeral",
                "-C", request.workDir.path,
            ]
            // Empty means "whatever config.toml says". Which models a CLI
            // accepts depends on its version and the account's plan, so a list
            // baked in here would be wrong on somebody's machine within a
            // release — better to defer to the tool that knows.
            if !request.model.isEmpty { args += ["--model", request.model] }
            if let out = lastMessageURL(in: request.workDir) {
                args += ["--output-last-message", out.path]
            }
            // `-` is what makes Codex read the prompt from stdin. Passing it as
            // argv would hit ARG_MAX and put the whole prompt in `ps`.
            args.append("-")
            return args
        }
    }

    // Where a hand-picked binary is remembered. One key per engine: pointing
    // EpiScope at a codex binary must not overwrite where claude was found.
    var cliPathDefaultsKey: String {
        switch self {
        case .claude: return "claudeCLIPath"
        case .codex: return "codexCLIPath"
        }
    }

    // PATH for spawned CLI runs. Finder-launched apps inherit a bare
    // /usr/bin:/bin PATH; the CLI (or the node its wrapper execs) may live
    // in Homebrew or ~/.local, so prepend the usual suspects plus the
    // resolved binary's own directory.
    static func environment(for cli: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [
            cli.deletingLastPathComponent().path,
            home + "/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return env
    }

    var cliMissingMessage: String {
        switch self {
        case .claude:
            return "The claude CLI was not found. Install Claude Code, or point "
                + "EpiScope at the binary via the claudeCLIPath default."
        case .codex:
            return "The codex CLI was not found. Install OpenAI Codex, or point "
                + "EpiScope at the binary via the codexCLIPath default."
        }
    }
}

// Locates the user's `codex` binary. Same rules as ClaudeCLI: the user default
// wins but only while it still looks like the Codex CLI and neither it nor its
// directory is world-writable, because an analysis starts on its own daily
// timer and would run whatever the default names, unattended.
nonisolated enum CodexCLI {
    static func locate() -> URL? {
        var candidates: [String] = []
        if let override = UserDefaults.standard.string(forKey: "codexCLIPath"),
           !override.isEmpty {
            let path = NSString(string: override).expandingTildeInPath
            if URL(fileURLWithPath: path).lastPathComponent.hasPrefix("codex"),
               ClaudeCLI.ownerOnlyWritable(path) {
                candidates.append(path)
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates += [
            home + "/.local/bin/codex",
            home + "/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

// One row of the Analysis Model menu. The engine is carried here rather than
// derived from the id — see the note on AnalysisEngine.
//
// `id` is what lands in the `analysisModel` default and in the report record,
// and it doubles as the pricing key, so it keeps the vendor prefix that
// SessionIndex.pricingTable uses. `cliModel` is what the CLI is actually asked
// for, which for Codex is the same name without that prefix.
nonisolated struct AnalysisModelChoice: Sendable {
    let id: String
    let name: String
    let engine: AnalysisEngine
    let cliModel: String

    // Computed, not a stored constant: the Codex entry reads a user default,
    // and a `static let` would freeze whatever it said at first access.
    static var all: [AnalysisModelChoice] { [
        .init(id: "claude-sonnet-4-6", name: "Sonnet 4.6", engine: .claude,
              cliModel: "claude-sonnet-4-6"),
        .init(id: "claude-sonnet-5", name: "Sonnet 5", engine: .claude,
              cliModel: "claude-sonnet-5"),
        .init(id: "claude-opus-5", name: "Opus 5", engine: .claude,
              cliModel: "claude-opus-5"),
        .init(id: "claude-opus-4-8", name: "Opus 4.8", engine: .claude,
              cliModel: "claude-opus-4-8"),
        .init(id: "claude-haiku-4-5", name: "Haiku 4.5", engine: .claude,
              cliModel: "claude-haiku-4-5"),
        // One Codex entry, not a model list. Codex users already choose their
        // model in ~/.codex/config.toml, and which names a given CLI accepts
        // moves faster than this menu could: a CLI one version behind rejects
        // the very model its own config names. `codexAnalysisModel` pins one
        // for anybody who wants a different model here than everywhere else.
        .init(id: "codex", name: "Codex — model from config.toml", engine: .codex,
              cliModel: UserDefaults.standard.string(forKey: "codexAnalysisModel") ?? ""),
    ] }

    static var fallback: AnalysisModelChoice { all[0] }

    // An id from the default may name a model that has since been dropped from
    // the menu; fall back rather than run something nobody chose.
    static func named(_ id: String) -> AnalysisModelChoice {
        all.first { $0.id == id } ?? fallback
    }
}
