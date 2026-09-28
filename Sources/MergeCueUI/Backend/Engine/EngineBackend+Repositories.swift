import Foundation
import MergeCueCore
import MergeCueEngine

// `.loadRepositories` and `.scanCheckouts`: background work whose progress lives in the backend and is merged into
// `AppState` by `loadState()`. Both always finish (success, failure or cancellation) and notify observers.

extension EngineBackend {
    func startRepositoryListing(_ key: AccountKey, forceRefresh: Bool) {
        if repositoryTasks[key] != nil && !forceRefresh { return }
        repositoryTasks[key]?.cancel()
        repositoryLists[key] = .loading(previous: repositoryLists[key]?.repositories ?? [])
        notifyLocalChange()
        let engine = runtime.engine
        repositoryTasks[key] = Task { [weak self] in
            let outcome: RepositoryListState
            do {
                let listing = try await engine.accountRepositories(key, forceRefresh: forceRefresh)
                outcome = .loaded(listing.repositories, fetchedAt: listing.fetchedAt, isTruncated: listing.isTruncated)
            } catch {
                let message = Self.backendError(error).errorDescription ?? "The repositories could not be listed."
                outcome = .failed(message, previous: [])
            }
            await self?.finishRepositoryListing(key, outcome)
        }
    }

    private func finishRepositoryListing(_ key: AccountKey, _ outcome: RepositoryListState) {
        if case .failed(let message, _) = outcome {
            repositoryLists[key] = .failed(message, previous: repositoryLists[key]?.repositories ?? [])
        } else {
            repositoryLists[key] = outcome
        }
        repositoryTasks[key] = nil
        notifyLocalChange()
    }

    /// Starts the single-pass checkout scan unless one is running. Returns false when one already runs.
    func startCheckoutScan(_ repos: [RepoKey]) -> Bool {
        guard scanTask == nil else { return false }
        scanGeneration += 1
        let generation = scanGeneration
        checkoutScan = CheckoutScanState(isRunning: true, suggestions: checkoutScan.suggestions)
        notifyLocalChange()
        let engine = runtime.engine
        scanTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<CheckoutDetectionReport, AppBackendError>
            do {
                let report = try await engine.detectCheckouts(for: repos) { progress in
                    Task { await self.updateScanProgress(generation, progress) }
                }
                result = .success(report)
            } catch {
                result = .failure(Self.backendError(error))
            }
            await self.finishCheckoutScan(generation, result)
        }
        return true
    }

    /// Cancels the running scan (its task finishes with `wasCancelled`).
    func cancelCheckoutScan() -> Bool {
        guard let scanTask else { return false }
        scanTask.cancel()
        return true
    }

    private func updateScanProgress(_ generation: Int, _ progress: CheckoutScanProgress) {
        guard generation == scanGeneration, checkoutScan.isRunning else { return }
        checkoutScan.directoriesScanned = max(checkoutScan.directoriesScanned, progress.directoriesScanned)
        checkoutScan.checkoutsFound = max(checkoutScan.checkoutsFound, progress.checkoutsFound)
        checkoutScan.isMatching = checkoutScan.isMatching || progress.isMatching
        notifyLocalChange()
    }

    private func finishCheckoutScan(_ generation: Int, _ result: Result<CheckoutDetectionReport, AppBackendError>) {
        guard generation == scanGeneration else { return }
        var state = checkoutScan
        state.isRunning = false
        state.isMatching = false
        state.finishedAt = Date()
        switch result {
        case .success(let report):
            state.directoriesScanned = report.directoriesScanned
            state.checkoutsFound = report.checkoutsFound
            state.mappedCount = report.mapped.count
            state.wasCancelled = report.wasCancelled
            state.isTruncated = report.isTruncated
            if !report.wasCancelled {
                state.suggestions = report.suggestions
            }
            state.errorMessage = nil
        case .failure(let error):
            state.errorMessage = error.errorDescription
        }
        checkoutScan = state
        scanTask = nil
        notifyLocalChange()
    }

    /// Waits for running listings and scans (tests).
    func waitForRepositoryWork() async {
        while let task = scanTask ?? repositoryTasks.values.first {
            await task.value
        }
    }
}

extension EngineBackend {
    /// "Choose Folder…": preview first (nothing saved for a mismatch unless `mapAnyway`, never for a folder that is
    /// not a checkout), then save and read the mapping back so a failed write can never pass silently.
    func mapCheckoutFolder(repo: RepoKey, repoFullPath: String, checkoutPath: String, mapAnyway: Bool) async throws -> AppCommandResult {
        let engine = runtime.engine
        let preview = try await engine.previewMapping(repo: repo, repoFullPath: repoFullPath, checkoutPath: checkoutPath)
        guard preview.isRepository else {
            return AppCommandResult(mappingPreview: preview)
        }
        if preview.suggestion.confidence == .mismatch && !mapAnyway {
            return AppCommandResult(mappingPreview: preview)
        }
        let mapping = try await engine.addMapping(repo: repo, repoFullPath: repoFullPath, checkoutPath: checkoutPath, confirm: mapAnyway)
        guard try await engine.mappings(repo: repo).contains(where: { $0.id == mapping.id }) else {
            throw AppBackendError.failed("The mapping of \(repoFullPath) could not be saved. Try again, or check that MergeCue can write to its data folder.")
        }
        let place = UIFormat.abbreviatedPath(mapping.checkoutPath)
        let moved = mapping.checkoutPath != preview.chosenPath ? " (the checkout containing the folder you chose)" : ""
        let message: String = switch mapping.confidence {
        case .exact: "Mapped \(repoFullPath) to \(place)\(moved): exact remote match, confirmed."
        case .probable: "Mapped \(repoFullPath) to \(place)\(moved) — probable match. Click Confirm to use it."
        case .mismatch: "Mapped \(repoFullPath) to \(place)\(moved) anyway (remotes don't match), confirmed by you."
        }
        return AppCommandResult(message: message, savedMapping: mapping, tone: mapping.confidence == .probable ? .attention : .success)
    }
}
