//
//  LinkedFolderRefreshCoordinator.swift
//  InkPond
//

import Foundation
import Observation

/// Owns the cancellable, retryable lifecycle of an explicit linked-folder
/// refresh. File-system work remains in `ProjectFileManager`; the editor only
/// applies the workspace effects emitted for the current operation.
@MainActor
@Observable
final class LinkedFolderRefreshCoordinator {
    typealias ProgressHandler = @MainActor (LinkedFolderLoadProgress) async -> Void

    enum State: Equatable {
        case idle
        case refreshing(title: String, progress: LinkedFolderLoadProgress)
        case completed(title: String, progress: LinkedFolderLoadProgress)
    }

    struct Request: Equatable {
        let projectID: String
        let title: String
    }

    enum RefreshTarget: Hashable {
        case fileTree
        case referenceCompletions
        case fonts
    }

    enum CompileRequest: Equatable {
        case bypassCacheOnce
    }

    struct WorkspaceRefresh: Equatable {
        let projectID: String
        let result: LinkedFolderLoadResult
        let targets: Set<RefreshTarget>
        let compileRequest: CompileRequest
        let completionProgress: LinkedFolderLoadProgress

        func applying(
            to current: WorkspaceEditorState
        ) -> WorkspaceEditorState {
            WorkspaceEditorState(
                editorText: current.editorText,
                entrySource: current.entrySource,
                fontFileNames: ProjectFileManager.refreshedLinkedFolderFontFileNames(
                    existing: current.fontFileNames,
                    relativePaths: result.relativePaths
                )
            )
        }
    }

    struct WorkspaceEditorState: Equatable {
        let editorText: String
        let entrySource: String
        let fontFileNames: [String]
    }

    enum Effect: Equatable {
        case cancelPreviewCompilation
        case applyWorkspaceRefresh(WorkspaceRefresh)
        case presentFailure(projectID: String, message: String)
    }

    struct Environment {
        var acquireFolder: @MainActor (_ projectID: String, _ title: String) throws -> URL
        var releaseFolder: @MainActor (_ projectID: String) -> Void
        var refreshContents: @MainActor (
            _ folderURL: URL,
            _ projectID: String,
            _ progress: @escaping ProgressHandler
        ) async throws -> LinkedFolderLoadResult
        var sleep: @MainActor (Duration) async throws -> Void

        static let live = Environment(
            acquireFolder: { projectID, title in
                guard let folderURL = BookmarkManager.loadBookmark(projectID: projectID) else {
                    throw InkPondFileError.fileNotFound(title)
                }
                return folderURL
            },
            releaseFolder: { projectID in
                BookmarkManager.stopAccessing(projectID)
            },
            refreshContents: { folderURL, projectID, progress in
                try await ProjectFileManager.refreshLinkedFolderContents(
                    at: folderURL,
                    projectID: projectID,
                    maxDownloadWait: 120
                ) { value in
                    await progress(value)
                }
            },
            sleep: { duration in
                try await Task.sleep(for: duration)
            }
        )
    }

    private(set) var state: State = .idle
    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = AsyncOperationGeneration()

    init(environment: Environment? = nil) {
        self.environment = environment ?? .live
    }

    var isRefreshing: Bool {
        if case .idle = state { return false }
        return true
    }

    var presentedTitle: String? {
        switch state {
        case .idle:
            return nil
        case .refreshing(let title, _), .completed(let title, _):
            return title
        }
    }

    var presentedProgress: LinkedFolderLoadProgress? {
        switch state {
        case .idle:
            return nil
        case .refreshing(_, let progress), .completed(_, let progress):
            return progress
        }
    }

    func start(
        _ request: Request,
        emit: @escaping @MainActor (Effect) -> Void
    ) {
        cancel()

        let operationID = generation.begin()
        state = .refreshing(
            title: request.title,
            progress: LinkedFolderLoadProgress(
                phase: .scanning,
                scannedFileCount: 0,
                downloadedFileCount: 0,
                totalDownloadFileCount: 0
            )
        )
        emit(.cancelPreviewCompilation)

        let environment = environment
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let folderURL = try environment.acquireFolder(request.projectID, request.title)
                defer { environment.releaseFolder(request.projectID) }

                guard generation.isCurrent(operationID) else { return }
                let result = try await environment.refreshContents(
                    folderURL,
                    request.projectID
                ) { [weak self] progress in
                    guard let self,
                          generation.isCurrent(operationID) else { return }
                    state = .refreshing(title: request.title, progress: progress)
                }

                try Task.checkCancellation()
                guard generation.isCurrent(operationID) else { return }

                let completionProgress = LinkedFolderLoadProgress(
                    phase: .complete,
                    scannedFileCount: result.scannedFileCount,
                    downloadedFileCount: result.downloadedFileCount,
                    totalDownloadFileCount: result.downloadedFileCount
                )
                state = .completed(title: request.title, progress: completionProgress)
                emit(
                    .applyWorkspaceRefresh(
                        WorkspaceRefresh(
                            projectID: request.projectID,
                            result: result,
                            targets: [.fileTree, .referenceCompletions, .fonts],
                            compileRequest: .bypassCacheOnce,
                            completionProgress: completionProgress
                        )
                    )
                )

                try await environment.sleep(.milliseconds(700))
                try Task.checkCancellation()
                finish(operationID)
            } catch is CancellationError {
                finish(operationID)
            } catch {
                guard finish(operationID) else { return }
                emit(
                    .presentFailure(
                        projectID: request.projectID,
                        message: error.localizedDescription
                    )
                )
            }
        }
    }

    func cancel() {
        let taskToCancel = task
        task = nil
        if let operationID = generation.current {
            _ = generation.finish(operationID)
        }
        state = .idle
        taskToCancel?.cancel()
    }

    @discardableResult
    private func finish(_ operationID: UUID) -> Bool {
        guard generation.finish(operationID) else { return false }
        task = nil
        state = .idle
        return true
    }
}
