# Emdash iOS - Changelog

## [Unreleased] - Initial Implementation

### Completed

#### Project Structure & Configuration
- [x] XcodeGen `project.yml` for reproducible Xcode project generation
- [x] SPM dependencies: Citadel (SSH), SwiftTerm (terminal)
- [x] Info.plist with multi-scene support, all orientations, local network usage description
- [x] iOS 18+ deployment target (for SwiftData + Citadel withPTY)

#### Models (SwiftData)
- [x] `SSHConnectionModel` - SSH connection storage with auth types (password, key, agent)
- [x] `ProjectModel` - Remote project with SSH connection reference, git info
- [x] `AgentTask` - Task with worktree path, branch, status, archive support
- [x] `Conversation` - Multi-agent conversation tabs per task
- [x] `ChatMessage` - Message storage for conversations

#### Services
- [x] `ProviderRegistry` - All 21 CLI agent definitions matching Electron registry
- [x] `SSHService` - SSH connection pool using Citadel (connect, disconnect, executeCommand, startShell, listFiles/SFTP)
- [x] `KeychainService` - iOS Keychain credential storage (password + passphrase per connection)
- [x] `RemoteGitService` - Git operations over SSH (createWorktree, removeWorktree, listWorktrees, getDefaultBranch, isGitRepo)
- [x] `RemotePtyService` - Agent PTY sessions over SSH shell channels (startSession, stopSession, write, resize)
- [x] `AgentManager` - Agent lifecycle orchestration (detectAgents, createAndStartTask, addConversation, teardownTask)
- [x] `SSHConnectionMonitor` - Connection health checks (30s interval) with auto-reconnection (3 retries, [1s, 5s, 15s] backoff). Port of Electron's SshConnectionMonitor
- [x] `SessionMapService` - Claude session isolation with deterministic UUIDs and persistent session map. Port of Electron's applySessionIsolation() from ptyManager.ts

#### Views (SwiftUI)
- [x] `ContentView` - Root layout with NavigationSplitView (iPad) / NavigationStack (iPhone)
- [x] `HomeView` - Welcome screen with quick actions and recent projects
- [x] `ProjectListView` - Sidebar with project tree, task list, archive support
- [x] `ProjectDetailView` - Project info, connection status, git info, task list
- [x] `AddRemoteProjectView` - 4-step wizard (connection -> auth -> path browse -> confirm)
- [x] `CreateTaskView` - Task creation with agent picker, prompt, env vars
- [x] `TaskDetailView` - Conversation tabs, terminal output, input bar, add agent
- [x] `TaskListView` / `TaskListRow` - Reusable task list components
- [x] `TerminalView` / `TerminalViewModel` - Terminal output display with auto-scroll
- [x] `TaskTerminalPane` - Terminal in detail/right column
- [x] `AgentPickerView` - Agent selection list
- [x] `AgentStatusView` - Running agents overview
- [x] `SSHConnectionListView` - Connection management
- [x] `AddSSHConnectionView` - New connection form with test
- [x] `HostKeyVerificationView` - Host key trust dialog
- [x] `SettingsView` - App settings with branch prefix, default shell, terminal font

#### Utilities
- [x] `ShellEscape` - quoteShellArg + isValidEnvVarName (port of shellEscape.ts)
- [x] `Logger` - os.Logger categories (ssh, pty, git, agent, db)
- [x] `PtyIdHelper` - PTY ID construction/parsing matching Electron format

#### Tests
- [x] `ShellEscapeTests` - Shell escaping and env var validation
- [x] `PtyIdHelperTests` - PTY ID make/parse roundtrip
- [x] `ProviderRegistryTests` - Registry completeness, lookup, detection
- [x] `SessionMapServiceTests` - Deterministic UUID, session isolation logic, resume behavior
- [x] `SSHConnectionMonitorTests` - Config initialization, metrics defaults

#### SSH Integration (Phase 2)
- [x] **SSH keepalive & reconnection** - `SSHConnectionMonitor` with 30s health checks, max 3 reconnect attempts with [1s, 5s, 15s] backoff. Wired into `AppState.connectAndMonitor()` for automatic monitoring on connect
- [x] **Remote init keystrokes** - Port of Electron's `buildRemoteInitKeystrokes()` pattern: `command -v` CLI check, `exec` to replace shell, helpful error message if CLI not found on remote

#### Agent Features (Phase 2)
- [x] **Session isolation for Claude** - Port of Electron's `applySessionIsolation()` with deterministic UUID generation via SHA-256, persistent session map at `~/Library/Application Support/emdash/pty-session-map.json`, full 5-case decision tree matching Electron exactly
- [x] **Agent resume** - `AgentManager.resumeTask()` supports resume flag (`-c -r` for Claude, `--continue` for others). Resume integrates with session isolation — known sessions get `--resume <uuid>`, new resumes use generic flags
- [x] **Agent detection caching** - `detectAgents()` caches results for 5 minutes per connection (configurable TTL). `forceRefresh` parameter for manual override. Cache invalidated on reconnection via `invalidateDetectionCache()`
- [x] **Keystroke injection timing** - TUI agents (amp, opencode) use 1500ms delay, prompt sent directly to SSH shell channel (matching Electron's remote SSH keystroke pattern)

#### Data & Persistence (Phase 2)
- [x] **Task state persistence** - Saves/restores last active project and task via UserDefaults. `AppState.saveActiveIds()` called on every navigation change. `restoreActiveState()` called on app launch after SwiftData container is ready
- [x] **Conversation message logging** - `TerminalViewModel.saveOutputAsMessage()` persists terminal output as `ChatMessage` records for history

#### UI Polish (Phase 2)
- [x] **Terminal keyboard toolbar** - Custom `TerminalKeyboardToolbar` with Esc, Tab, Ctrl+C, Ctrl+D, Ctrl+Z, Ctrl+L, and arrow keys. Scrollable horizontal layout
- [x] **Dark mode terminal** - Terminal always uses dark background (`.colorScheme(.dark)`) regardless of system appearance
- [x] **Pull-to-refresh** - `.refreshable` on `ProjectDetailView` re-detects agents (force refresh) and refreshes git branch/remote info
- [x] **iPad keyboard shortcuts** - Cmd+N (new task), Cmd+Shift+T (add remote project), Cmd+, (settings) via hidden Button + keyboardShortcut pattern
- [x] **Task status badges** - Visual status indicators on task rows (running spinner, completed checkmark, failed warning, idle pause)
- [x] **Resume banner** - Stopped/failed tasks show a resume banner at the top of TaskDetailView with one-tap resume
- [x] **Settings: Clear Data** - Full data wipe with confirmation dialog (deletes all models, clears caches, resets navigation)
- [x] **Settings: Disconnect All** - One-tap disconnect all SSH connections and stop monitoring
- [x] **Settings: Cache management** - Clear agent detection cache from settings

#### Bug Fixes & Citadel API Corrections (Phase 2.1)

##### Major
- [x] **Wired up real SSH shell streaming** - Replaced stubbed `SSHService.startShell()` with Citadel's `executeCommandStream(_:inShell:true)`. Agent output now streams to the terminal in real-time. The command is passed upfront at shell creation instead of being written after. `RemotePtyService.startSession()` builds the full init command and passes it to `startShell(command:)`. Added output buffering in `RemotePtySession` so data arriving before `TerminalView` attaches is not lost.
  - **Known limitation**: Interactive write (user typing to the agent) is not supported with `executeCommandStream` in Citadel 0.7.x. Requires upgrade to Citadel 0.9+ (`withPTY`/`withTTY`) for full interactive terminal I/O. Keystroke injection for TUI agents (amp, opencode) is also not supported in streaming mode.
- [x] **Fixed Citadel `CommandFailed` error on project creation** - Citadel's `executeCommand()` throws `SSHClient.CommandFailed` when a remote command exits non-zero instead of returning an exit code. Wrapped in a do-catch inside `SSHService.executeCommand()` so callers get an `ExecResult` with `exitCode: 1` instead of a thrown error. This fixed `isGitRepo()`, `getDefaultBranch()`, `getCurrentBranch()`, and `getRemoteUrl()` which all rely on checking `exitCode`.
- [x] **Fixed project/task navigation not working** - Two issues: (1) On iPhone, `selectProject()` never pushed a destination onto `NavigationPath`, so `NavigationStack` didn't navigate. Added `navigationPath.append()` for both project and task selection when `sizeClass != .regular`. (2) On iPad, `List(selection:)` was intercepting taps on `DisclosureGroup` labels, causing rows to stay highlighted without triggering `onTapGesture`. Replaced `DisclosureGroup` with a `Section` + `Button` header + conditional `if isExpanded` content. Removed `List(selection:)` binding — selection is now handled by explicit tap callbacks.

##### Minor
- [x] **Fixed `SSHConnectionMonitor` closure capture errors** - Swift strict concurrency requires explicit `self.` in `@MainActor` closures and `os.Logger` string interpolation (auto-closures). Made health check constants `static let` and used `Self.maxReconnectAttempts` etc. Stored static values in local variables before `Task` closures.
- [x] **Fixed Citadel auth method signature** - Changed `.passwordBased(.init(username:password:))` to `.passwordBased(username:password:)` to match Citadel's actual static factory method signature.
- [x] **Removed non-existent `SSHShell` type** - Citadel doesn't have a client-side `SSHShell` type. Replaced with closure-based `SSHShellSession` (dataStream + writeHandler + closeHandler) that's independent of Citadel's internal types.
- [x] **Removed `Insecure.RSA.PrivateKey` namespace conflict** - Placeholder `Insecure` enum conflicted with NIOSSH's `Insecure` namespace. Removed entirely; key auth now falls back to password with a warning or throws a descriptive error.
- [x] **Fixed `executeCommand` return type** - Citadel's `executeCommand()` returns a single `ByteBuffer` (stdout only), not a tuple. Removed `response.0` / `response.1` tuple access.
- [x] **Fixed SFTP `listDirectory` types** - `listDirectory(atPath:)` returns `[SFTPMessage.Name]` containing a `components` array of `SFTPPathComponent`. Fixed to iterate both levels (`nameMessage.components`) to access `filename` and `attributes`.
- [x] **Fixed `permissions` type** - `SFTPFileAttributes.permissions` is `UInt32?`, not an option set. Removed `.rawValue` call.

#### Navigation & UI Fixes (Phase 2.2)

##### Major
- [x] **Fixed task navigation from ProjectDetailView** - Tapping a task in the project detail screen did nothing on iPhone. Added `@Environment(\.horizontalSizeClass)` and `navigationPath.append(NavigationDestination.task(task))` for compact size class so tasks correctly push onto the navigation stack.
- [x] **Stale task reset on app launch** - SSH sessions are ephemeral and don't survive app restarts (no tmux/screen). Added `resetStaleTasks()` in `EmdashApp.swift` that marks any tasks left in `.running` status as `.idle` on launch, preventing misleading "running" indicators for dead sessions.
- [x] **Terminal session retry with output buffering** - `TerminalView` was showing "No active session for this agent" due to a race condition between session creation (SSH connect + shell spawn) and view attachment (`onAppear`). Added `getSessionWithRetry()` with progressive delays (300ms, 700ms, 1500ms) and output buffering in `RemotePtySession` so data arriving before the view attaches is queued and flushed when `onOutput` is set.

##### Minor
- [x] **Auto-navigate to task after creation** - `CreateTaskView` now pushes `NavigationDestination.task(task)` after sheet dismissal on iPhone, with a 300ms delay to let the sheet animation complete. Previously the user had to manually find and tap the new task.
- [x] **Fixed grey floating task rows in sidebar** - Removed `.padding(.leading, 16)` and `.listRowBackground(nil)` from `ProjectListView` task rows that caused inconsistent rendering with grey backgrounds not matching the list surface.
- [x] **Added "Stopped" label for idle tasks** - Task rows in `ProjectListView` now show an orange "· Stopped" indicator for tasks with `.idle` status, making it clear that a previous session has ended and the task needs to be resumed.
- [x] **TerminalView empty ptyId guard** - `TerminalViewModel.attach()` now validates for empty `ptyId` early and shows "No agent configured for this conversation" instead of attempting a session lookup that would always fail.
- [x] **MainActor safety in terminal callbacks** - `onOutput` and `onExit` callbacks in `TerminalViewModel` now dispatch to `@MainActor` via `Task { @MainActor in }` to prevent potential data races when called from background SSH streams.

#### Agent Execution & Recovery Fixes (Phase 2.3)

##### Major
- [x] **Fixed remote init keystrokes causing bash syntax errors** - The `buildRemoteInitKeystrokes()` function wrapped the agent command in `sh -c '...'`, which caused double-quoting issues when inner arguments also used single quotes (from `quoteShellArg`). Combined with Citadel's `executeCommandStream` appending `\n;exit\n` to the command, this produced bash parse errors like `syntax error near unexpected token '¡exit'`. Removed the `sh -c` wrapper entirely — the `if command -v ... then exec ... else ... fi` block now runs directly in the SSH shell channel. Also added user profile sourcing (`.profile`, `.bashrc`, `.bash_profile`) at the top of the init sequence so agent CLIs installed via version managers are found.
- [x] **Fixed worktree creation silently failing** - `RemoteGitService.createWorktree()` checked for `"fatal:"` or `"error:"` in stderr to detect failures, but Citadel's `CommandFailed` catch in `SSHService.executeCommand()` returns a generic `"Command failed with exit code X"` message (losing the actual stderr). Changed to check `exitCode != 0` directly instead of pattern-matching stderr content. Also provides a helpful error message when the generic stderr is detected.
- [x] **Fixed task stuck as "Running" after session ends (black screen, no resume)** - `spawnAgent()`'s `onExit` callback only updated the in-memory `runningAgents` dictionary but never persisted the status change to SwiftData. Tasks left in `.running` status hid the resume banner and showed a dead black terminal. Added `markTaskIdle()` method that fetches the task from SwiftData via `modelContainer.mainContext` and sets `status = .idle` with a timestamp. The `onExit` callback now also cleans up `activeTerminals`.
- [x] **Fixed resume failing with non-existent worktree** - `AgentManager.resumeTask()` used the stored `task.worktreePath` without verifying the directory exists on the remote server. If the original worktree creation failed silently or the remote was cleaned up, resume would fail with `cd: No such file or directory`. Added a `test -d` check over SSH before spawning the agent; if the directory is missing, the worktree is automatically recreated via `RemoteGitService.createWorktree()`, and the task's `worktreePath` and `branch` are updated.
- [x] **Fixed agent detection not finding version-manager-installed CLIs** - SSH exec channels are non-interactive, so `.bashrc`'s standard guard (`[ -z "$PS1" ] && return`) prevents version managers like `mise`, `nvm`, `asdf`, `volta`, and `fnm` from activating. CLIs installed via these tools (e.g., `gemini` at `~/.local/share/mise/shims/gemini`) were invisible to `command -v`. Fixed by explicitly prepending common version manager shim/bin paths to `PATH` before sourcing profiles:
  - `~/.local/share/mise/shims` (mise/rtx)
  - `~/.asdf/shims` (asdf)
  - `~/.volta/bin` (volta)
  - `~/.local/bin` (pipx, user-local)
  - `~/.npm-global/bin` (npm custom prefix)
  - `~/.nvm/current/bin` (nvm symlink)
  - `~/.fnm/aliases/default/bin` (fnm)
  - `/usr/local/bin` (homebrew macOS, manual)
  - `/home/linuxbrew/.linuxbrew/bin` (homebrew Linux)

  Applied to both `AgentManager.detectAgents()` and `RemotePtyService.buildRemoteInitKeystrokes()` so detection and execution use the same enriched PATH.

##### Minor
- [x] **Terminal output history persistence** - Terminal output was ephemeral — re-entering a task showed a black screen with no record of previous sessions. Added auto-save: when a session ends (`onExit`) or the view detaches (`onDisappear`), the live session output is saved as a `ChatMessage` record (sender: `"terminal"`) in SwiftData. On attach, any previously saved messages for the conversation are loaded and displayed with a `--- Previous session ---` separator before live output. Added `conversationId` parameter to `TerminalView` and `liveSessionOutput` tracking to `TerminalViewModel`.
- [x] **Removed `bash -l -c` detection approach** - The initial fix for agent detection used `bash -l -c 'command -v ...'` (login shell), but login shells can hang on interactive profile elements (e.g., `fortune`, `motd`) or produce extra stdout that pollutes the detection result. Replaced with inline profile sourcing that doesn't depend on shell mode.

#### Chat UX & Follow-Up Flow (Phase 2.4)

##### Major
- [x] **Follow-up messages via new sessions** - Implemented a chat-like experience within the one-shot SSH streaming constraint (Citadel 0.7.x). Each user follow-up message creates a new SSH session by calling `AgentManager.resumeTask(followUpPrompt:)`. The prompt is passed to the CLI alongside session isolation flags. For Claude: `claude --session-id <uuid> "follow-up"` (preserves conversation context). For Gemini/others: `gemini --yolo "follow-up"` (fresh invocation). User messages are persisted as `ChatMessage(sender: "user")` in SwiftData and shown in terminal history with `> ` prefix.
- [x] **Agent working indicator** - Added a blue "Agent is working..." bar with a spinner above the terminal when `task.isRunning`. Input bar disabled during agent execution with "Agent is working..." placeholder. Send button replaced with spinner. Previously there was zero visual feedback while the agent processed.
- [x] **Terminal auto-reattach on new session** - Added `sessionGeneration` counter to `AppState`, incremented every time `AgentManager.spawnAgent()` creates a new PTY session. `TerminalView` uses `.id("\(ptyId)-\(sessionGeneration)")` to force SwiftUI recreation, triggering a fresh `attach()` that loads updated history and connects to the new session.
- [x] **Removed bare resume (always require prompt)** - The old "Resume" button called `resumeTask()` with no prompt, which always fails in the iOS app because there's no interactive stdin (Citadel 0.7.x limitation). Agents like Gemini errored with "no input provided via stdin". Removed the Resume button from the status banner and the "Resume Agent" toolbar menu item. The input bar is now the only way to continue — every interaction includes a prompt.

##### Minor
- [x] **Fixed Gemini `-i` flag in piped SSH context** - Gemini/Qwen's `initialPromptFlag: "-i"` maps to `--prompt-interactive` which requires a real TTY. SSH streaming uses piped stdin, not a PTY, so this always failed with "The --prompt-interactive flag cannot be used when input is piped from stdin." Changed `buildCliCommand()` to pass the prompt as a positional argument instead when the flag is `-i`.
- [x] **Fixed Gemini `--resume` consuming prompt as session ID** - When both `--resume` and a positional prompt were passed (`gemini --resume "message"`), Gemini interpreted the prompt text as a session identifier, causing "Invalid session identifier" errors. Fixed by setting `isResume: false` when `followUpPrompt` is provided in `resumeTask()`. Claude still gets continuity via `--session-id` from `applySessionIsolation()`.
- [x] **Prompt allowed alongside resume flags** - Removed the `!options.isResume` guard in `RemotePtyService.buildCliCommand()` that prevented initial prompts from being passed during resume. This matches the Electron app's `buildProviderCliArgs` which does NOT exclude prompts when resuming. Enables `claude --resume <uuid> "follow-up"` for agents that support it.
- [x] **Status banner redesign** - Replaced the orange "Agent stopped" resume banner with a green "Agent finished — Send a message below to continue" informational banner. Failed tasks show red "Agent failed" with error details. The banner now guides users to the input bar instead of offering a broken bare-resume button.
- [x] **Terminal history interleaving** - History now properly interleaves terminal output and user messages chronologically. Each terminal output chunk gets a "--- Session ended ---" suffix. User messages display with `> ` prefix at their correct timestamp position. Previously the user's follow-up appeared above a "--- Previous session ---" marker in the wrong order.
- [x] **Input bar disabled during agent execution** - Input field and send button are disabled while `task.isRunning`, preventing users from typing messages that would be silently dropped (SSH writes not supported in streaming mode). Shows spinner in place of send button.
- [x] **Removed dead `sendInput()` / `agentManager.sendInput()` call path from TaskDetailView** - The old input bar called `sendInput()` which tried to write to the SSH session (`agentManager.sendInput` → `remotePtyService.write`), but writes are a no-op in Citadel 0.7.x streaming mode. Replaced entirely with `sendFollowUp()` which creates new sessions.

#### Interactive Terminal & PTY Rewrite (Phase 2.5)

##### Major
- [x] **Interactive terminal via Citadel `withPTY`** - Replaced the one-shot `executeCommandStream` pattern with Citadel's `withPTY` API for full bidirectional I/O. Agent sessions are now persistent interactive PTY sessions with real stdin writes, stdout streaming, and terminal resize support. No more session recreation on every follow-up message. The Citadel library was already resolved at v0.12.0 (not 0.7.x as previous code comments stated) — `withPTY`/`withTTY` have been available since 0.9.0.
- [x] **Rewritten `SSHShellSession`** - Replaced the closure-based session (with no-op `writeHandler`) with one backed by `TTYStdinWriter`. Real `write(_ data:)` via `writer.write(ByteBuffer)`, real `resize(cols:rows:)` via `writer.changeSize()`. Uses `CheckedContinuation` to synchronize writer availability between the `withPTY` closure startup and the caller.
- [x] **New `startInteractiveShell()` in `SSHService`** - Opens a long-lived PTY session via `client.withPTY()` in a detached `Task`. The closure stays alive via `Task.sleep` until cancelled. `TTYStdinWriter` (outbound) and `TTYOutput` (inbound) are bridged to the `SSHShellSession` for write and read operations.
- [x] **Init commands as stdin writes** - `RemotePtyService.startSession()` now opens a bare interactive shell first, then writes init commands (PATH setup, env exports, cd, agent CLI) as individual stdin lines. Previously the entire command was baked into `executeCommandStream` upfront.
- [x] **Direct input to running sessions** - `TaskDetailView` input bar now writes directly to the PTY stdin when the agent is running (via `agentManager.sendInput()`). When the agent has stopped, input resumes with a new session. No more session recreation for every follow-up. Keyboard toolbar keys (Ctrl+C, Tab, arrows, etc.) now send real terminal control sequences to the agent.

##### Minor
- [x] **Bumped deployment target to iOS 18** - Required for `withPTY`/`withTTY` which carry `@available(macOS 15.0, *)` annotation (maps to iOS 18+). Updated `project.yml`, `Package.swift`, and documentation.
- [x] **Removed `sessionGeneration` workaround** - The counter that forced `TerminalView` recreation via `.id()` is no longer needed since sessions are persistent. Removed from `AppState` and `AgentManager.spawnAgent()`.
- [x] **Removed `-i` flag workaround** - Gemini/Qwen's `-i` (interactive prompt) flag now works correctly because we have a real PTY. Removed the special case that fell back to positional arguments.
- [x] **Keystroke injection now supported** - TUI agents (Amp, OpenCode) that use `useKeystrokeInjection: true` can now have their prompts typed into the terminal via PTY stdin writes with a 500ms startup delay.
- [x] **Input bar always enabled while running** - The input bar is no longer disabled during agent execution. Users can type and send messages at any time — input goes directly to the agent's stdin.

### TODO - Remaining Features (pick up here)

#### Critical - SSH Integration
- [ ] **Citadel SSH auth refinement** - Key auth currently falls back to password. Needs proper PEM key parsing for ED25519/RSA/ECDSA via Citadel's `SSHAuthenticationMethod` types. Password auth (`.passwordBased(username:password:)`) works correctly.
- [ ] **SSH agent forwarding** - iOS doesn't have SSH agent natively. Investigate using the Secure Enclave or imported keys. Currently throws unsupported error
- [ ] **Host key verification wiring** - `HostKeyVerificationView` UI is built but not wired to `SSHClient.connect()`. Need to implement `SSHHostKeyValidator` callback that presents the view and awaits user decision
- [ ] **SSH config file parsing** - Parse `~/.ssh/config` for host aliases (like Electron's `sshGetConfig` IPC). Would allow auto-fill in AddRemoteProjectView

#### Critical - Terminal
- [ ] **SwiftTerm integration** - Replace the current plain-text `TerminalView` with SwiftTerm's `TerminalView` (UIViewRepresentable wrapper). SwiftTerm provides full VT100/xterm emulation with colors, cursor positioning, scrollback. The current view just appends raw text with no ANSI parsing
- [ ] **Terminal copy/paste** - Add context menu with copy selection, paste from clipboard

#### Important - Agent Features
- [ ] **Provider custom config** - Allow per-provider overrides (custom CLI path, extra args, env vars) stored in UserDefaults. Mirrors Electron's `getProviderCustomConfig()`
- [ ] **Remote agent installation** - Allow users to install supported CLI agents on the remote server from the app (e.g., `npm install -g @anthropic-ai/claude-code`, `npm install -g @anthropic-ai/gemini-cli`). Show install button next to undetected agents in the picker or a dedicated management view

#### Important - Data & Persistence
- [ ] **SwiftData migrations** - As schema evolves, add versioned schema support. Currently using default schema with no migration plan
- [ ] **iCloud sync** - Optional iCloud sync for SSH connections and project metadata (not credentials)
- [ ] merge the work from the task since each task is creating its own git worktrees. we need to mark work as done and merge the task at some point to main 

#### Important - UI Polish
- [ ] **iPad split view refinement** - The three-column layout needs proper sizing and collapse behavior. Test with different iPad sizes
- [ ] **Drag-to-reorder projects** - Electron sidebar supports drag reorder. SwiftUI List supports this with `onMove`
- [ ] **Drag-to-reorder tasks** - Same as above within each project
- [ ] **Haptic feedback** - Add haptics for connection state changes, task completion

#### Nice-to-Have
- [ ] **File changes / diff viewer** - Port Electron's FileChangesPanel with git diff rendering. Would need `git diff` parsing and syntax-highlighted diff view
- [ ] **SFTP file browser** - Standalone file browser for remote projects (currently only used in AddRemoteProject wizard)
- [ ] **Notification support** - Push notifications when an agent completes or fails (requires background processing)
- [ ] **Shortcuts integration** - Siri Shortcuts for "Start task on project X with agent Y"
- [ ] **Widget** - Home screen widget showing running agent count and status
- [ ] **Linear/Jira/GitHub integration** - Port issue tracker integration from Electron app
- [ ] **Skills system** - Port AgentSkills support for cross-agent skill packages
- [ ] **Worktree pooling** - Pre-create reserve worktrees for instant task starts (like Electron's WorktreePoolService)
- [ ] **Multi-window (iPadOS)** - Support multiple scenes for side-by-side task viewing
- [ ] **Accessibility** - VoiceOver labels, dynamic type support, reduce motion
