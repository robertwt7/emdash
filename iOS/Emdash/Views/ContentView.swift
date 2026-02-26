import SwiftUI
import SwiftData

/// Root view: NavigationSplitView for iPad, NavigationStack for iPhone.
/// Mirrors the Electron app's three-panel layout.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \ProjectModel.createdAt, order: .reverse) private var projects: [ProjectModel]

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad: Three-column layout
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebarContent
                } content: {
                    mainContent
                } detail: {
                    detailContent
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                // iPhone: Stack navigation
                NavigationStack(path: $appState.navigationPath) {
                    sidebarContent
                        .navigationDestination(for: NavigationDestination.self) { dest in
                            switch dest {
                            case .home:
                                HomeView()
                            case .project(let project):
                                ProjectDetailView(project: project)
                            case .task(let task):
                                TaskDetailView(task: task)
                            case .settings:
                                SettingsView()
                            case .addRemoteProject:
                                AddRemoteProjectView()
                            }
                        }
                }
            }
        }
        // iPad keyboard shortcuts
        .keyboardShortcut("n", modifiers: [.command]) { appState.showingCreateTask = true }
        .keyboardShortcut("t", modifiers: [.command, .shift]) { appState.showingAddRemoteProject = true }
        .keyboardShortcut(",", modifiers: [.command]) { appState.showingSettings = true }
    }

    // MARK: - Sidebar (Project + Task list)

    private var sidebarContent: some View {
        ProjectListView(
            projects: projects,
            onSelectProject: { project in
                appState.selectProject(project)
                if sizeClass != .regular {
                    appState.navigationPath.append(NavigationDestination.project(project))
                }
            },
            onSelectTask: { task in
                appState.selectTask(task)
                if sizeClass != .regular {
                    appState.navigationPath.append(NavigationDestination.task(task))
                }
            }
        )
        .navigationTitle("Emdash")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        appState.showingAddRemoteProject = true
                    } label: {
                        Label("Add Remote Project", systemImage: "globe.badge.chevron.backward")
                    }
                    Divider()
                    Button {
                        appState.showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
            }
        }
        .sheet(isPresented: $appState.showingAddRemoteProject) {
            AddRemoteProjectView()
        }
        .sheet(isPresented: $appState.showingSettings) {
            SettingsView()
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        Group {
            if let project = appState.selectedProject {
                if let task = appState.activeTask {
                    TaskDetailView(task: task)
                } else {
                    ProjectDetailView(project: project)
                }
            } else {
                HomeView()
            }
        }
    }

    // MARK: - Detail (Terminal / File Changes)

    private var detailContent: some View {
        Group {
            if let task = appState.activeTask {
                TaskTerminalPane(task: task)
            } else {
                ContentUnavailableView(
                    "No Task Selected",
                    systemImage: "terminal",
                    description: Text("Select a task to view its terminal output")
                )
            }
        }
    }
}

// MARK: - Keyboard Shortcut Extension

private extension View {
    /// Convenience for adding iPad keyboard shortcuts that trigger an action.
    func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers, action: @escaping () -> Void) -> some View {
        self.background(
            Button("") { action() }
                .keyboardShortcut(key, modifiers: modifiers)
                .frame(width: 0, height: 0)
                .opacity(0)
        )
    }
}
