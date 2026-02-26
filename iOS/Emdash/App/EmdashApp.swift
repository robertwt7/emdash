import SwiftUI
import SwiftData

@main
struct EmdashApp: App {
    @StateObject private var appState = AppState()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SSHConnectionModel.self,
            ProjectModel.self,
            AgentTask.self,
            Conversation.self,
            ChatMessage.self,
        ])
        let config = ModelConfiguration(
            "emdash",
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .modelContainer(sharedModelContainer)
                .onAppear {
                    appState.modelContainer = sharedModelContainer
                    appState.setupConnectionMonitor()
                    restoreState()
                }
        }
    }

    /// Restore last active project/task from UserDefaults (like Electron's useAppInitialization).
    private func restoreState() {
        let context = sharedModelContainer.mainContext

        // Reset stale running tasks — SSH sessions don't survive app restart.
        // Without tmux/screen, any task marked as .running is orphaned.
        resetStaleTasks(context: context)

        let descriptor = FetchDescriptor<ProjectModel>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        guard let projects = try? context.fetch(descriptor) else { return }
        appState.restoreActiveState(projects: projects)
    }

    /// Mark any tasks left in .running status as .idle on app launch.
    /// Remote SSH sessions are ephemeral — they don't persist across app restarts.
    private func resetStaleTasks(context: ModelContext) {
        let descriptor = FetchDescriptor<AgentTask>()
        guard let tasks = try? context.fetch(descriptor) else { return }
        var resetCount = 0
        for task in tasks where task.status == .running {
            task.status = .idle
            task.updatedAt = Date()
            resetCount += 1
        }
        if resetCount > 0 {
            try? context.save()
            Log.agent.info("Reset \(resetCount) stale running task(s) to idle on launch")
        }
    }
}
