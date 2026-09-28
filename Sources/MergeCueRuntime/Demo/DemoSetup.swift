import Foundation
import MergeCueCore
import MergeCueEngine
import MergeCueFixtures
import MergeCueStore

/// Demo-only wiring after the baseline sync: every demo account's `acme/payments-api` is mapped to the synthetic
/// checkout and the mapping is confirmed, so code tasks get real isolated worktrees at the "PR head".
enum DemoSetup {
    static func ensureMappings(engine: MergeCueEngine, database: MergeCueDatabase, scenario: DemoScenario) async {
        let checkout = MergeCuePaths.fileSystemPath(scenario.repository.checkout)
        let log = MCLog(category: "runtime")
        for account in DemoScenario.accounts {
            do {
                let snapshots = try await engine.changeRequests(account: account.id)
                let repos = Set(snapshots.map(\.summary.repository).filter {
                    $0.fullPath.caseInsensitiveCompare(DemoRepository.fullPath) == .orderedSame
                }.map(\.key))
                for repo in repos {
                    let existing = try await engine.mappings(repo: repo)
                    if let mapping = existing.first(where: { $0.checkoutPath == checkout }) {
                        if !mapping.isConfirmed { try await engine.confirmMapping(id: mapping.id) }
                        continue
                    }
                    let mapping = try await engine.addMapping(repo: repo, repoFullPath: DemoRepository.fullPath, checkoutPath: checkout)
                    if !mapping.isConfirmed { try await engine.confirmMapping(id: mapping.id) }
                }
            } catch {
                log.error("Demo mapping for \(account.kind.displayName) failed: \(error.localizedDescription)")
            }
        }
    }
}
