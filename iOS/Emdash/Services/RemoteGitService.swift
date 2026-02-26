import Foundation

/// Remote Git operations over SSH. Port of Electron's RemoteGitService.
actor RemoteGitService {
    private let sshService: SSHService

    init(sshService: SSHService) {
        self.sshService = sshService
    }

    struct WorktreeInfo {
        let path: String
        let branch: String
        let isMain: Bool
    }

    // MARK: - Worktree Operations

    /// Create a worktree at <projectPath>/.emdash/worktrees/<slug>-<timestamp>.
    /// Mirrors RemoteGitService.createWorktree() from Electron.
    func createWorktree(
        connectionId: String,
        projectPath: String,
        taskName: String,
        baseRef: String? = nil
    ) async throws -> WorktreeInfo {
        let slug = slugify(taskName)
        let timestamp = Int(Date().timeIntervalSince1970)
        let worktreeDir = "\(slug)-\(timestamp)"
        let relPath = ".emdash/worktrees/\(worktreeDir)"
        let fullPath = normalizePath("\(projectPath)/\(relPath)")
        let branchName = worktreeDir

        // Ensure .emdash/worktrees directory exists
        _ = try await sshService.executeCommand(
            connectionId: connectionId,
            command: "mkdir -p .emdash/worktrees",
            cwd: projectPath
        )

        // Resolve base ref
        let resolvedBase: String
        if let base = baseRef {
            let verify = try await sshService.executeCommand(
                connectionId: connectionId,
                command: "git rev-parse --verify \(ShellEscape.quoteShellArg(base))",
                cwd: projectPath
            )
            if verify.exitCode == 0 {
                resolvedBase = base
            } else {
                resolvedBase = try await getDefaultBranch(connectionId: connectionId, cwd: projectPath)
            }
        } else {
            resolvedBase = try await getDefaultBranch(connectionId: connectionId, cwd: projectPath)
        }

        // Create the worktree
        let result = try await sshService.executeCommand(
            connectionId: connectionId,
            command: "git worktree add \(ShellEscape.quoteShellArg(relPath)) -b \(ShellEscape.quoteShellArg(branchName)) \(ShellEscape.quoteShellArg(resolvedBase))",
            cwd: projectPath
        )

        if result.exitCode != 0 {
            // Citadel's CommandFailed catch in SSHService returns generic stderr,
            // so provide a helpful message with the most common cause.
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteGitError.worktreeCreationFailed(
                detail.isEmpty || detail.hasPrefix("Command failed")
                    ? "git worktree add exited with code \(result.exitCode). Ensure the repo has at least one commit and branch '\(resolvedBase)' exists."
                    : detail
            )
        }

        Log.git.info("Created remote worktree: \(fullPath) on branch \(branchName)")

        return WorktreeInfo(
            path: fullPath,
            branch: branchName,
            isMain: false
        )
    }

    /// Remove a worktree and its branch.
    func removeWorktree(
        connectionId: String,
        projectPath: String,
        worktreePath: String,
        branch: String?
    ) async throws {
        let normalizedWT = normalizePath(worktreePath)
        let normalizedProject = normalizePath(projectPath)

        // Safety: never remove the main worktree
        guard normalizedWT != normalizedProject else {
            throw RemoteGitError.cannotRemoveMainWorktree
        }

        // Remove the worktree
        _ = try await sshService.executeCommand(
            connectionId: connectionId,
            command: "git worktree remove --force \(ShellEscape.quoteShellArg(worktreePath))",
            cwd: projectPath
        )

        // Prune stale worktree metadata
        _ = try await sshService.executeCommand(
            connectionId: connectionId,
            command: "git worktree prune",
            cwd: projectPath
        )

        // Delete the branch if specified
        if let branch = branch, !branch.isEmpty {
            _ = try await sshService.executeCommand(
                connectionId: connectionId,
                command: "git branch -D \(ShellEscape.quoteShellArg(branch))",
                cwd: projectPath
            )
        }

        // Clean up the directory if it still exists
        _ = try await sshService.executeCommand(
            connectionId: connectionId,
            command: "rm -rf \(ShellEscape.quoteShellArg(worktreePath))",
            cwd: nil
        )

        Log.git.info("Removed remote worktree: \(worktreePath)")
    }

    /// List all worktrees for a project.
    func listWorktrees(
        connectionId: String,
        projectPath: String
    ) async throws -> [WorktreeInfo] {
        let result = try await sshService.executeCommand(
            connectionId: connectionId,
            command: "git worktree list --porcelain",
            cwd: projectPath
        )

        var worktrees: [WorktreeInfo] = []
        var currentPath: String?
        var currentBranch: String?
        var isDetached = false

        for line in result.stdout.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                // Save previous worktree if any
                if let path = currentPath {
                    worktrees.append(WorktreeInfo(
                        path: path,
                        branch: currentBranch ?? "detached",
                        isMain: path == normalizePath(projectPath)
                    ))
                }
                currentPath = String(line.dropFirst("worktree ".count))
                currentBranch = nil
                isDetached = false
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                currentBranch = ref.replacingOccurrences(of: "refs/heads/", with: "")
            } else if line == "detached" {
                isDetached = true
            }
        }

        // Don't forget the last one
        if let path = currentPath {
            worktrees.append(WorktreeInfo(
                path: path,
                branch: currentBranch ?? (isDetached ? "detached" : "unknown"),
                isMain: path == normalizePath(projectPath)
            ))
        }

        return worktrees
    }

    // MARK: - Branch Operations

    func getDefaultBranch(
        connectionId: String,
        cwd: String
    ) async throws -> String {
        // Try HEAD first
        let head = try await sshService.executeCommand(
            connectionId: connectionId,
            command: "git rev-parse --abbrev-ref HEAD",
            cwd: cwd
        )
        let headBranch = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.exitCode == 0 && !headBranch.isEmpty && headBranch != "HEAD" {
            return headBranch
        }

        // Fallback: try common branch names
        for candidate in ["main", "master", "develop", "trunk"] {
            let verify = try await sshService.executeCommand(
                connectionId: connectionId,
                command: "git rev-parse --verify \(candidate)",
                cwd: cwd
            )
            if verify.exitCode == 0 {
                return candidate
            }
        }

        return "HEAD"
    }

    func getCurrentBranch(
        connectionId: String,
        cwd: String
    ) async throws -> String {
        let result = try await sshService.executeCommand(
            connectionId: connectionId,
            command: "git rev-parse --abbrev-ref HEAD",
            cwd: cwd
        )
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func getRemoteUrl(
        connectionId: String,
        cwd: String
    ) async throws -> String? {
        let result = try await sshService.executeCommand(
            connectionId: connectionId,
            command: "git remote get-url origin",
            cwd: cwd
        )
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    /// Verify a path is a git repository.
    func isGitRepo(
        connectionId: String,
        path: String
    ) async throws -> Bool {
        let result = try await sshService.executeCommand(
            connectionId: connectionId,
            command: "git rev-parse --is-inside-work-tree",
            cwd: path
        )
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    // MARK: - Helpers

    private func slugify(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func normalizePath(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        while p.hasSuffix("/") && p.count > 1 {
            p = String(p.dropLast())
        }
        return p
    }
}

enum RemoteGitError: LocalizedError {
    case worktreeCreationFailed(String)
    case cannotRemoveMainWorktree
    case notAGitRepo(String)

    var errorDescription: String? {
        switch self {
        case .worktreeCreationFailed(let detail):
            return "Worktree creation failed: \(detail)"
        case .cannotRemoveMainWorktree:
            return "Cannot remove the main worktree"
        case .notAGitRepo(let path):
            return "\(path) is not a git repository"
        }
    }
}
