//
//  ProjectEditorStateStore.swift
//  InkPond
//

import Foundation

struct ProjectEditorSavedState: Codable, Equatable {
    var openTabPaths: [String] = []
    var activeTabPath: String?
    var outlineCollapsedItemIDsByFile: [String: [String]] = [:]

    static let empty = ProjectEditorSavedState()
}

enum ProjectEditorStateStore {
    private static let keyPrefix = "projectEditorState"

    static func load(projectID: String, defaults: UserDefaults = .standard) -> ProjectEditorSavedState {
        guard let data = defaults.data(forKey: key(for: projectID)) else {
            return .empty
        }
        return (try? JSONDecoder().decode(ProjectEditorSavedState.self, from: data)) ?? .empty
    }

    static func save(
        _ state: ProjectEditorSavedState,
        projectID: String,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key(for: projectID))
    }

    static func saveTabs(
        projectID: String,
        openTabPaths: [String],
        activeTabPath: String?,
        defaults: UserDefaults = .standard
    ) {
        update(projectID: projectID, defaults: defaults) { state in
            state.openTabPaths = uniquePaths(openTabPaths)
            state.activeTabPath = activeTabPath
        }
    }

    static func outlineCollapsedItemIDs(
        projectID: String,
        fileName: String,
        defaults: UserDefaults = .standard
    ) -> Set<String> {
        Set(load(projectID: projectID, defaults: defaults).outlineCollapsedItemIDsByFile[fileName] ?? [])
    }

    static func saveOutlineCollapsedItemIDs(
        projectID: String,
        fileName: String,
        collapsedItemIDs: Set<String>,
        defaults: UserDefaults = .standard
    ) {
        update(projectID: projectID, defaults: defaults) { state in
            if collapsedItemIDs.isEmpty {
                state.outlineCollapsedItemIDsByFile.removeValue(forKey: fileName)
            } else {
                state.outlineCollapsedItemIDsByFile[fileName] = collapsedItemIDs.sorted()
            }
        }
    }

    private static func update(
        projectID: String,
        defaults: UserDefaults,
        mutate: (inout ProjectEditorSavedState) -> Void
    ) {
        var state = load(projectID: projectID, defaults: defaults)
        mutate(&state)
        save(state, projectID: projectID, defaults: defaults)
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { path in
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    private static func key(for projectID: String) -> String {
        "\(keyPrefix).\(projectID)"
    }
}
