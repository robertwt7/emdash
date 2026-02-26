# Interactive Terminal via Citadel `withPTY`

**Date**: 2026-02-26
**Status**: Approved

## Problem

The iOS app currently uses `executeCommandStream(_:inShell:true)` for SSH agent sessions. This is a one-shot, read-only approach — the entire command is baked in at session start, output streams back, but stdin writes are no-ops. Every user follow-up recreates a new SSH session, which is slow and breaks conversational continuity.

## Discovery

Citadel is already resolved at **v0.12.0** (not 0.7.x as code comments stated). The `withPTY`/`withTTY` APIs have been available since 0.9.0 and provide full bidirectional I/O with `TTYStdinWriter` (write + resize) and `TTYOutput` (async read stream).

**Constraint**: `withPTY`/`withTTY` require `@available(macOS 15.0, *)` which maps to iOS 18+. Decision: bump deployment target from iOS 17 to iOS 18.

## Approach

Replace `executeCommandStream` with `withPTY` for agent sessions. One persistent interactive session per agent run with real stdin/stdout/resize.

## Architecture

```
User Input (InputBar / Keyboard Toolbar)
    |
AgentManager.sendInput(ptyId:, text:)
    |
RemotePtyService.write(sessionId:, text:)
    |
SSHShellSession.write(data:)  -- backed by TTYStdinWriter.write()
    |
SSH Channel --> Remote Server stdin --> Agent CLI process
    |
stdout --> SSH Channel --> TTYOutput AsyncSequence
    |
SSHShellSession.onData --> RemotePtySession --> TerminalViewModel
    |
TerminalView (SwiftUI)
```

## Component Changes

### SSHService.swift

New `startInteractiveShell(connectionId:cols:rows:) -> SSHShellSession`:
- Calls `client.withPTY(ptyRequest) { inbound, outbound in ... }` in a detached Task
- Uses `CheckedContinuation` to bridge the `TTYStdinWriter` back to the caller
- Background task drains `inbound` stream, fires `onData` callbacks
- `onExit` fires when inbound stream ends (agent exits or connection drops)

`SSHShellSession` gains:
- `writer: TTYStdinWriter?` — replaces the no-op writeHandler
- Real `write(_ data:)` via `writer.write(ByteBuffer(bytes:))`
- Real `resize(cols:rows:)` via `writer.changeSize()`

### RemotePtyService.swift

`startSession()` changes from baking the full command into `executeCommandStream` to:
1. Open bare interactive shell via `startInteractiveShell()`
2. Write init commands as stdin lines (PATH setup, env vars, cd, agent command)

`buildRemoteInitKeystrokes()` returns individual lines instead of a joined command.

### TaskDetailView.swift

- Input bar sends directly to running session stdin (not `sendFollowUp()`)
- Remove `sendFollowUp()` and session-recreation pattern
- When agent is running: input goes to `agentManager.sendInput()`
- When agent has exited: input starts a new agent session with the prompt

### TerminalView.swift

- `onInput` becomes functional (sends to PTY stdin)
- Keyboard toolbar keys (Ctrl+C = `\x03`, Tab = `\t`, etc.) write to stdin
- Terminal resize events call `session.resize()`

### Deployment Target

`project.yml`: `iOS: "17.0"` -> `iOS: "18.0"`

## What Gets Removed

- `sendFollowUp()` workaround in TaskDetailView
- `resumeTask(followUpPrompt:)` in AgentManager
- No-op `writeHandler` closure
- `appState.sessionGeneration` counter for forced view recreation
- Session recreation on every follow-up message

## What Stays

- Terminal output history (for re-entering view after navigation)
- `executeCommand()` for fire-and-forget ops (git, detection)
- `--session-id` for Claude multi-conversation support
- `autoSaveOutput()` / `loadHistory()` for persistence

## Edge Cases

- **Agent exits**: inbound stream ends -> onExit fires -> "Agent finished" banner
- **SSH drops**: withPTY closure throws -> error surfaced -> reconnect prompt
- **Ctrl+C**: Write `\x03` to stdin -> SIGINT via PTY
- **App backgrounded**: iOS may suspend connection; detect on foreground and show reconnect
