import Foundation

// MARK: - Provider ID

enum ProviderId: String, CaseIterable, Codable, Identifiable {
    case codex
    case claude
    case cursor
    case gemini
    case qwen
    case droid
    case amp
    case opencode
    case copilot
    case charm
    case auggie
    case goose
    case kimi
    case kilocode
    case kiro
    case rovo
    case cline
    case continueAgent = "continue"
    case codebuff
    case mistral
    case pi

    var id: String { rawValue }
}

// MARK: - Provider Definition

struct ProviderDefinition: Identifiable {
    let id: ProviderId
    let name: String
    let cli: String?
    let commands: [String]
    let versionArgs: [String]
    let detectable: Bool
    let autoApproveFlag: String?
    let initialPromptFlag: String? // nil = no prompt support, "" = positional
    let useKeystrokeInjection: Bool
    let resumeFlag: String?
    let sessionIdFlag: String?
    let defaultArgs: [String]
    let planActivateCommand: String?
    let autoStartCommand: String?
    let icon: String? // SF Symbol name
    let docUrl: String?
    let installCommand: String?

    var displayName: String { name }

    var hasCli: Bool { cli != nil || autoStartCommand != nil }

    var effectiveCli: String? {
        if let auto = autoStartCommand { return auto.components(separatedBy: " ").first }
        return cli
    }
}

// MARK: - Provider Registry

enum ProviderRegistry {
    static let providers: [ProviderDefinition] = [
        ProviderDefinition(
            id: .codex, name: "Codex", cli: "codex",
            commands: ["codex"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: "--full-auto", initialPromptFlag: "",
            useKeystrokeInjection: false, resumeFlag: "resume --last",
            sessionIdFlag: nil, defaultArgs: [], planActivateCommand: nil,
            autoStartCommand: nil, icon: "terminal",
            docUrl: "https://github.com/openai/codex",
            installCommand: "npm install -g @openai/codex"
        ),
        ProviderDefinition(
            id: .claude, name: "Claude Code", cli: "claude",
            commands: ["claude"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: "--dangerously-skip-permissions", initialPromptFlag: "",
            useKeystrokeInjection: false, resumeFlag: "-c -r",
            sessionIdFlag: "--session-id", defaultArgs: [], planActivateCommand: "/plan",
            autoStartCommand: nil, icon: "bubble.left.and.text.bubble.right",
            docUrl: "https://docs.anthropic.com/en/docs/claude-code",
            installCommand: "npm install -g @anthropic-ai/claude-code"
        ),
        ProviderDefinition(
            id: .cursor, name: "Cursor Agent", cli: "cursor-agent",
            commands: ["cursor-agent", "cursor"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: "-f", initialPromptFlag: "",
            useKeystrokeInjection: false, resumeFlag: nil,
            sessionIdFlag: nil, defaultArgs: [], planActivateCommand: nil,
            autoStartCommand: nil, icon: "cursorarrow.click",
            docUrl: nil, installCommand: nil
        ),
        ProviderDefinition(
            id: .gemini, name: "Gemini CLI", cli: "gemini",
            commands: ["gemini"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: "--yolo", initialPromptFlag: "-i",
            useKeystrokeInjection: false, resumeFlag: "--resume",
            sessionIdFlag: nil, defaultArgs: [], planActivateCommand: nil,
            autoStartCommand: nil, icon: "sparkles",
            docUrl: "https://github.com/google-gemini/gemini-cli",
            installCommand: "npm install -g @anthropic-ai/gemini-cli"
        ),
        ProviderDefinition(
            id: .qwen, name: "Qwen Code", cli: "qwen",
            commands: ["qwen"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: "--yolo", initialPromptFlag: "-i",
            useKeystrokeInjection: false, resumeFlag: "--continue",
            sessionIdFlag: nil, defaultArgs: [], planActivateCommand: nil,
            autoStartCommand: nil, icon: "text.bubble",
            docUrl: nil, installCommand: nil
        ),
        ProviderDefinition(
            id: .droid, name: "Droid", cli: "droid",
            commands: ["droid"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: nil, initialPromptFlag: "",
            useKeystrokeInjection: false, resumeFlag: "-r",
            sessionIdFlag: nil, defaultArgs: [], planActivateCommand: nil,
            autoStartCommand: nil, icon: "cpu",
            docUrl: nil, installCommand: nil
        ),
        ProviderDefinition(
            id: .amp, name: "Amp", cli: "amp",
            commands: ["amp"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: "--dangerously-allow-all", initialPromptFlag: "",
            useKeystrokeInjection: true, resumeFlag: nil,
            sessionIdFlag: nil, defaultArgs: [], planActivateCommand: nil,
            autoStartCommand: nil, icon: "bolt",
            docUrl: nil, installCommand: nil
        ),
        ProviderDefinition(
            id: .opencode, name: "OpenCode", cli: "opencode",
            commands: ["opencode"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: nil, initialPromptFlag: "",
            useKeystrokeInjection: true, resumeFlag: nil,
            sessionIdFlag: nil, defaultArgs: [], planActivateCommand: nil,
            autoStartCommand: nil, icon: "chevron.left.forwardslash.chevron.right",
            docUrl: nil, installCommand: nil
        ),
        ProviderDefinition(
            id: .copilot, name: "GitHub Copilot", cli: "copilot",
            commands: ["copilot"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: "--allow-all-tools", initialPromptFlag: nil,
            useKeystrokeInjection: false, resumeFlag: nil,
            sessionIdFlag: nil, defaultArgs: [], planActivateCommand: nil,
            autoStartCommand: nil, icon: "airplane",
            docUrl: nil, installCommand: nil
        ),
        ProviderDefinition(
            id: .charm, name: "Charm (Crush)", cli: "crush",
            commands: ["crush"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: "--yolo", initialPromptFlag: nil,
            useKeystrokeInjection: false, resumeFlag: nil,
            sessionIdFlag: nil, defaultArgs: [], planActivateCommand: nil,
            autoStartCommand: nil, icon: "heart",
            docUrl: nil, installCommand: nil
        ),
        ProviderDefinition(
            id: .auggie, name: "Auggie", cli: "auggie",
            commands: ["auggie"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: nil, initialPromptFlag: "",
            useKeystrokeInjection: false, resumeFlag: nil,
            sessionIdFlag: nil, defaultArgs: ["--allow-indexing"],
            planActivateCommand: nil, autoStartCommand: nil,
            icon: "magnifyingglass", docUrl: nil, installCommand: nil
        ),
        ProviderDefinition(
            id: .goose, name: "Goose", cli: "goose",
            commands: ["goose"], versionArgs: ["--version"], detectable: false,
            autoApproveFlag: nil, initialPromptFlag: "-t",
            useKeystrokeInjection: false, resumeFlag: nil,
            sessionIdFlag: nil, defaultArgs: ["run", "-s"],
            planActivateCommand: nil, autoStartCommand: nil,
            icon: "bird", docUrl: nil, installCommand: nil
        ),
        ProviderDefinition(
            id: .kimi, name: "Kimi", cli: "kimi",
            commands: ["kimi"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: "--yolo", initialPromptFlag: "-c",
            useKeystrokeInjection: false, resumeFlag: nil,
            sessionIdFlag: nil, defaultArgs: [], planActivateCommand: nil,
            autoStartCommand: nil, icon: "moon",
            docUrl: nil, installCommand: nil
        ),
        ProviderDefinition(
            id: .kilocode, name: "Kilocode", cli: "kilocode",
            commands: ["kilocode"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: "--auto", initialPromptFlag: "",
            useKeystrokeInjection: false, resumeFlag: "--continue",
            sessionIdFlag: nil, defaultArgs: [], planActivateCommand: nil,
            autoStartCommand: nil, icon: "k.circle",
            docUrl: nil, installCommand: nil
        ),
        ProviderDefinition(
            id: .kiro, name: "Kiro", cli: "kiro-cli",
            commands: ["kiro-cli", "kiro"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: nil, initialPromptFlag: "",
            useKeystrokeInjection: false, resumeFlag: nil,
            sessionIdFlag: nil, defaultArgs: ["chat"],
            planActivateCommand: nil, autoStartCommand: nil,
            icon: "wand.and.stars", docUrl: nil, installCommand: nil
        ),
        ProviderDefinition(
            id: .rovo, name: "Rovo Dev", cli: nil,
            commands: ["rovodev", "acli"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: "--yolo", initialPromptFlag: nil,
            useKeystrokeInjection: false, resumeFlag: nil,
            sessionIdFlag: nil, defaultArgs: [],
            planActivateCommand: nil, autoStartCommand: "acli rovodev run",
            icon: "r.circle", docUrl: nil, installCommand: nil
        ),
        ProviderDefinition(
            id: .cline, name: "Cline", cli: "cline",
            commands: ["cline"], versionArgs: ["help"], detectable: true,
            autoApproveFlag: "--yolo", initialPromptFlag: "",
            useKeystrokeInjection: false, resumeFlag: nil,
            sessionIdFlag: nil, defaultArgs: [], planActivateCommand: nil,
            autoStartCommand: nil, icon: "c.circle",
            docUrl: nil, installCommand: nil
        ),
        ProviderDefinition(
            id: .continueAgent, name: "Continue", cli: "cn",
            commands: ["cn"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: nil, initialPromptFlag: "-p",
            useKeystrokeInjection: false, resumeFlag: "--resume",
            sessionIdFlag: nil, defaultArgs: [], planActivateCommand: nil,
            autoStartCommand: nil, icon: "arrow.right.circle",
            docUrl: nil, installCommand: nil
        ),
        ProviderDefinition(
            id: .codebuff, name: "Codebuff", cli: "codebuff",
            commands: ["codebuff"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: nil, initialPromptFlag: "",
            useKeystrokeInjection: false, resumeFlag: nil,
            sessionIdFlag: nil, defaultArgs: [], planActivateCommand: nil,
            autoStartCommand: nil, icon: "shield",
            docUrl: nil, installCommand: nil
        ),
        ProviderDefinition(
            id: .mistral, name: "Mistral (Vibe)", cli: "vibe",
            commands: ["vibe"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: "--auto-approve", initialPromptFlag: "--prompt",
            useKeystrokeInjection: false, resumeFlag: nil,
            sessionIdFlag: nil, defaultArgs: [], planActivateCommand: nil,
            autoStartCommand: nil, icon: "wind",
            docUrl: nil, installCommand: nil
        ),
        ProviderDefinition(
            id: .pi, name: "Pi", cli: "pi",
            commands: ["pi"], versionArgs: ["--version"], detectable: true,
            autoApproveFlag: nil, initialPromptFlag: "",
            useKeystrokeInjection: false, resumeFlag: "-c",
            sessionIdFlag: nil, defaultArgs: [], planActivateCommand: nil,
            autoStartCommand: nil, icon: "pi.circle",
            docUrl: nil, installCommand: nil
        ),
    ]

    private static let providerMap: [ProviderId: ProviderDefinition] = {
        Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
    }()

    static func provider(for id: ProviderId) -> ProviderDefinition? {
        providerMap[id]
    }

    static var detectableProviders: [ProviderDefinition] {
        providers.filter { $0.detectable && !$0.commands.isEmpty }
    }

    static func isValidProvider(_ raw: String) -> Bool {
        ProviderId(rawValue: raw) != nil
    }
}
