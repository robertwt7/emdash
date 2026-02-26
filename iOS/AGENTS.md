# Emdash iOS

Native iOS app for orchestrating multiple CLI coding agents remotely via SSH. This is the iOS companion to the Electron desktop app at the repo root.

## Tech Stack

- **Platform**: iOS 18+, iPadOS 17+
- **UI**: SwiftUI, NavigationSplitView (iPad) / NavigationStack (iPhone)
- **Database**: SwiftData (SQLite-backed)
- **SSH**: Citadel (pure Swift, NIO-based SSH client)
- **Terminal**: SwiftTerm (VT100/xterm emulator) — **not yet integrated, using plain text view**
- **Credentials**: iOS Keychain via Security framework
- **Crypto**: CryptoKit (SHA-256 for deterministic session UUIDs)
- **Build**: XcodeGen (`project.yml`) for reproducible project generation

## Quickstart

1. Install XcodeGen: `brew install xcodegen`
2. Generate Xcode project: `cd iOS && xcodegen generate`
3. Open `iOS/Emdash.xcodeproj` in Xcode 15+
4. Select iOS 18+ simulator or device, build and run

If XcodeGen is not available, create an Xcode project manually with the source files in `Emdash/` and add SPM dependencies for `Citadel` and `SwiftTerm`.

## Architecture

### Remote-Only Design

Unlike the Electron app which supports both local and remote projects, the iOS app is **remote-only**. All agent execution happens on remote servers via SSH. There are no local worktrees, no local PTY, no local git operations.

### Process Model

Single-process iOS app with actor-based concurrency:

- **Main Actor**: All UI state, SwiftData operations
- **SSHService (actor)**: SSH connection pool, command execution, interactive PTY sessions (Citadel withPTY)
- **RemotePtyService (actor)**: Agent PTY session lifecycle over SSH shells
- **RemoteGitService (actor)**: Git worktree operations over SSH
- **SSHConnectionMonitor (@MainActor)**: Health checks (30s) + auto-reconnect with backoff
- **SessionMapService**: Claude session isolation with deterministic UUIDs

### Data Flow

```
User creates task
  -> AgentManager.createAndStartTask()
    -> RemoteGitService.createWorktree()       [SSH exec]
    -> RemotePtyService.startSession()          [SSH PTY channel]
      -> SSHService.startInteractiveShell()     [Citadel withPTY]
      -> writes init commands to PTY stdin:
           export PATH="...version-manager-shims...:$PATH"
           export ENV_VAR='value'
           cd /path && exec cli args
    -> TerminalView displays output via onData callback
    -> User input -> SSHShellSession.write()    [PTY stdin - interactive!]

User resumes stopped task
  -> AgentManager.resumeTask()
    -> SessionMapService.applySessionIsolation()  [check known sessions]
    -> RemotePtyService.startSession(isResume: true)
      -> Claude: --resume <uuid> or --session-id <uuid>
      -> Others: -c -r, --continue, etc.
```

### Key Files

```
iOS/
├── AGENTS.md                    # This file
├── CLAUDE.md                    # Points to AGENTS.md
├── CHANGELOG.md                 # Feature status and TODOs
├── project.yml                  # XcodeGen project spec
├── Package.swift                # SPM package (minimal)
├── Emdash/
│   ├── App/
│   │   ├── EmdashApp.swift      # @main entry, SwiftData container setup, state restoration
│   │   └── AppState.swift       # Observable state, navigation, service refs, state persistence
│   ├── Models/
│   │   ├── SSHConnectionModel.swift  # SSH connection (host, port, auth)
│   │   ├── ProjectModel.swift        # Remote project (path, git info, connection ref)
│   │   ├── AgentTask.swift           # Task (worktree, branch, status, agent)
│   │   ├── Conversation.swift        # Agent conversation tab
│   │   └── ChatMessage.swift         # Terminal output log
│   ├── Services/
│   │   ├── ProviderRegistry.swift      # All 21 CLI agent definitions
│   │   ├── SSHService.swift            # SSH connection pool (Citadel)
│   │   ├── SSHConnectionMonitor.swift  # Health checks + auto-reconnect
│   │   ├── SessionMapService.swift     # Claude session isolation (deterministic UUIDs)
│   │   ├── KeychainService.swift       # Keychain credential storage
│   │   ├── RemoteGitService.swift      # Git over SSH
│   │   ├── RemotePtyService.swift      # Agent PTY over SSH shell
│   │   └── AgentManager.swift          # Agent lifecycle orchestration
│   ├── Views/
│   │   ├── ContentView.swift              # Root navigation (split/stack) + keyboard shortcuts
│   │   ├── HomeView.swift                 # Welcome + quick actions
│   │   ├── Projects/
│   │   │   ├── ProjectListView.swift      # Sidebar project/task tree
│   │   │   ├── ProjectDetailView.swift    # Project info + task list + pull-to-refresh
│   │   │   └── AddRemoteProjectView.swift # 4-step SSH wizard
│   │   ├── Tasks/
│   │   │   ├── TaskListView.swift         # Reusable task list
│   │   │   ├── TaskDetailView.swift       # Conversation tabs + terminal + resume
│   │   │   └── CreateTaskView.swift       # Task creation form
│   │   ├── Terminal/
│   │   │   └── TerminalView.swift         # Terminal output + keyboard toolbar + message logging
│   │   ├── Agents/
│   │   │   ├── AgentPickerView.swift      # Agent selection
│   │   │   └── AgentStatusView.swift      # Running agents overview
│   │   ├── SSH/
│   │   │   ├── SSHConnectionListView.swift    # Connection management
│   │   │   ├── AddSSHConnectionView.swift     # New connection form
│   │   │   └── HostKeyVerificationView.swift  # Host key trust dialog
│   │   └── Settings/
│   │       └── SettingsView.swift         # App settings + data management
│   ├── Utilities/
│   │   ├── ShellEscape.swift    # Shell arg quoting + env var validation
│   │   └── Logger.swift         # os.Logger categories
│   └── Resources/
│       ├── Info.plist
│       └── Assets.xcassets/
└── EmdashTests/
    ├── ShellEscapeTests.swift
    ├── PtyIdHelperTests.swift
    ├── ProviderRegistryTests.swift
    ├── SessionMapServiceTests.swift
    └── SSHConnectionMonitorTests.swift
```

### Models (SwiftData)

Five models with cascade delete hierarchy: `SSHConnectionModel -> ProjectModel -> AgentTask -> Conversation -> ChatMessage`

| Model | Key Fields | Relationships |
|-------|-----------|---------------|
| `SSHConnectionModel` | name, host, port, username, authType, privateKeyPath | -> projects |
| `ProjectModel` | name, remotePath, gitRemote, gitBranch, baseRef | -> sshConnection, -> tasks |
| `AgentTask` | name, branch, worktreePath, status, agentId, archivedAt | -> project, -> conversations |
| `Conversation` | title, providerId, isMain, displayOrder | -> task, -> messages |
| `ChatMessage` | content, sender, timestamp | -> conversation |

### Provider Registry

All 21 CLI agents from the Electron app's `registry.ts` are defined in `ProviderRegistry.swift`:

| Agent | CLI | Auto-approve | Prompt Flag | Resume | Notes |
|-------|-----|-------------|-------------|--------|-------|
| Claude Code | `claude` | `--dangerously-skip-permissions` | positional | `-c -r` | `--session-id` support |
| Codex | `codex` | `--full-auto` | positional | `resume --last` | |
| Gemini | `gemini` | `--yolo` | `-i` | `--resume` | |
| Qwen | `qwen` | `--yolo` | `-i` | `--continue` | |
| Amp | `amp` | `--dangerously-allow-all` | keystroke | none | TUI, keystroke injection |
| *...17 more* | | | | | See `ProviderRegistry.swift` |

### SSH Security

- **Shell escaping**: All remote command arguments use `ShellEscape.quoteShellArg()` (single-quote wrapping with embedded quote escaping)
- **Env var validation**: Names validated against `^[A-Za-z_][A-Za-z0-9_]*$`
- **Shell allowlist**: Only `/bin/bash`, `/bin/sh`, `/bin/zsh`, `/usr/bin/bash`, `/usr/bin/zsh`, `/usr/bin/fish` and `/usr/local/bin` variants
- **Credentials**: Stored in iOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- **Connection limit**: Max 10 concurrent SSH connections
- **CLI detection**: Remote `command -v` check before `exec` prevents running unknown binaries

### SSH Connection Health

Port of Electron's `SshConnectionMonitor`:
- **Health check interval**: 30 seconds
- **Max reconnect attempts**: 3
- **Backoff schedule**: [1s, 5s, 15s]
- **Auto-reconnect**: Uses stored credentials from Keychain
- **State tracking**: `connected` -> `error` -> `reconnecting` -> `connected|disconnected`

### Claude Session Isolation

Port of Electron's `applySessionIsolation()` from `ptyManager.ts`:

1. **Deterministic UUIDs**: SHA-256 hash of task/conversation ID with RFC 4122 v4 bits
2. **Persistent session map**: JSON file at `~/Library/Application Support/emdash/pty-session-map.json`
3. **5-case decision tree**:
   - Known session → `--resume <uuid>`
   - Additional chat → `--session-id <new-uuid>`
   - Main with other sessions → `--session-id <uuid>`
   - First-time main → `--session-id <uuid>` (proactive)
   - Resuming with no isolation → nil (generic `-c -r`)

### Remote Worktree Path

Worktrees are created at: `<projectPath>/.emdash/worktrees/<slug>-<timestamp>`

This matches the Electron app's `RemoteGitService.createWorktree()` pattern (not the local `../worktrees/` sibling pattern).

### Remote Init Keystrokes

Port of Electron's `buildRemoteInitKeystrokes()`:
```bash
export API_KEY='value'
cd '/path/to/worktree'
sh -c 'if command -v claude >/dev/null 2>&1; then exec claude --dangerously-skip-permissions "prompt"; else printf "%s\n" "emdash: claude not found on remote. Install: npm install -g @anthropic-ai/claude-code"; fi'
```

Key features:
- `exec` replaces the shell with the agent process (clean process tree)
- `command -v` checks CLI existence before running
- Helpful error message with install command if CLI is missing

### PTY ID Format

Matches Electron exactly: `{providerId}-main-{taskId}` or `{providerId}-chat-{conversationId}`

Parsing handles provider ID prefix ambiguity by trying longest IDs first (e.g., `continue` before `co`).

## What's Different from Electron

| Feature | Electron | iOS |
|---------|----------|-----|
| Local projects | Yes | No (remote only) |
| Local worktrees | Yes (`../worktrees/`) | No |
| Local PTY | Yes (node-pty) | No (SSH shell only) |
| Worktree pooling | Yes (pre-created reserves) | No |
| File preservation | Yes (.env, .envrc copies) | No |
| Session isolation (Claude) | Yes (deterministic UUID) | Yes (ported) |
| Agent resume | Yes (per-provider flags) | Yes (ported) |
| Agent detection caching | Implicit (per-window) | Yes (5-min TTL cache) |
| Connection monitoring | Yes (SshConnectionMonitor) | Yes (ported) |
| Terminal emulator | xterm.js | SwiftTerm (TODO) |
| Terminal keyboard | Native keyboard | Custom toolbar (Esc, Ctrl+C, arrows) |
| File diffs | Yes (Monaco diff) | TODO |
| Skills system | Yes (AgentSkills) | TODO |
| Issue tracker integration | Yes (Linear, Jira, GitHub) | TODO |
| Auto-updater | Yes (electron-updater) | No (App Store) |
| Multi-window | Yes (Electron windows) | TODO (iPadOS scenes) |
| State persistence | Yes (localStorage) | Yes (UserDefaults) |
| iPad keyboard shortcuts | N/A | Yes (Cmd+N, Cmd+Shift+T, Cmd+,) |

## Current Status

**Phase 1 (COMPLETE)**: Foundation
- All models, services, and views are scaffolded with real logic
- 21 agent providers registered
- Full SSH connection wizard with file browser
- Task creation and multi-agent conversation support
- Basic terminal output display

**Phase 2 (COMPLETE)**: SSH Integration & Agent Features
- SSH connection monitoring with auto-reconnect (30s health checks, 3 retries, backoff)
- Claude session isolation (deterministic UUIDs, persistent session map, 5-case decision tree)
- Agent resume support with session isolation integration
- Agent detection caching (5-min TTL)
- Remote init keystrokes matching Electron's CLI check + exec pattern
- Task state persistence across app launches
- Terminal keyboard toolbar (Esc, Tab, Ctrl+C/D/Z/L, arrows)
- Always-dark terminal background
- Pull-to-refresh on project detail
- iPad keyboard shortcuts
- Resume banner for stopped/failed tasks
- Settings: clear data, disconnect all, cache management
- 5 test files covering shell escape, PTY IDs, providers, session map, connection monitor

**Phase 3 (TODO)**: Terminal Polish
- SwiftTerm integration for proper VT100 emulation
- Terminal resize support
- Terminal copy/paste

**Phase 4 (TODO)**: Feature Parity
- Host key verification wiring
- Citadel SSH auth refinement (proper key types)
- Provider custom config
- File changes/diff viewer
- Notification support

See `CHANGELOG.md` for detailed TODO items with implementation guidance.

## Guardrails

- **ALWAYS** generate Xcode project via `xcodegen generate` after modifying `project.yml`
- **NEVER** commit `.xcodeproj` files — they're generated from `project.yml`
- **ALWAYS** use `ShellEscape.quoteShellArg()` for any string passed to remote shell
- **ALWAYS** validate env var names with `ShellEscape.isValidEnvVarName()` before exporting
- **ALWAYS** check shell binary against the allowlist before spawning remote PTY
- **NEVER** store credentials in SwiftData — use `KeychainService` for passwords/passphrases
- Do not modify the provider registry without also updating the Electron registry in sync
- Keep the PTY ID format in sync with Electron's `ptyId.ts`
- Keep the remote worktree path format in sync with Electron's `RemoteGitService.ts`
- Keep the session isolation decision tree in sync with Electron's `applySessionIsolation()`

## Code Style

- **Swift**: Strict concurrency with actors and `@MainActor`
- **SwiftUI**: Prefer `@State`/`@Binding` for view-local state, `@EnvironmentObject` for shared app state
- **Naming**: Types PascalCase, properties/methods camelCase, constants camelCase
- **File naming**: Types match filename (`SSHService.swift` contains `SSHService`)
- **Error handling**: Custom error enums conforming to `LocalizedError` for each service
- **Logging**: Use `Log.ssh`, `Log.pty`, `Log.git`, `Log.agent`, `Log.db` categories

## Building

```bash
# Generate Xcode project
cd iOS
xcodegen generate

# Open in Xcode
open Emdash.xcodeproj

# Or build from command line
xcodebuild -scheme Emdash -destination 'platform=iOS Simulator,name=iPhone 16'
```
