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

    /// Starts the bounded checkout scan unless one is running. Returns false when one already runs.
    func startCheckoutScan(_ repos: [RepoKey]) -> Bool {
        guard scanTask == nil else { return false }
        scanGeneration += 1
        let generation = scanGeneration
        let total = min(repos.count, MergeCueEngine.maxDetectedRepositories)
        checkoutScan = CheckoutScanState(isRunning: true, done: 0, total: total, suggestions: checkoutScan.suggestions)
        notifyLocalChange()
        let engine = runtime.engine
        scanTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<CheckoutDetectionReport, AppBackendError>
            do {
                let report = try await engine.detectCheckouts(for: repos) { done, total in
                    Task { await self.updateScanProgress(generation, done: done, total: total) }
                }
                result = .success(report)
            } catch {
                result = .failure(Self.backendError(error))
            }
            await self.finishCheckoutScan(generation, result)
        }
        return true
    }

    private func updateScanProgress(_ generation: Int, done: Int, total: Int) {
        guard generation == scanGeneration, checkoutScan.isRunning else { return }
        checkoutScan.done = max(checkoutScan.done, done)
        checkoutScan.total = total
        notifyLocalChange()
    }

    private func finishCheckoutScan(_ generation: Int, _ result: Result<CheckoutDetectionReport, AppBackendError>) {
        guard generation == scanGeneration else { return }
        var state = checkoutScan
        state.isRunning = false
        state.finishedAt = Date()
        switch result {
        case .success(let report):
            state.done = state.total
            state.mappedCount = report.mapped.count
            state.suggestions.merge(report.suggestions) { _, new in new }
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
