// mergecue-diagnose — read-only check of MergeCue's own provider code against the accounts connected in the app.
//
//   swift run mergecue-diagnose [bitbucket|github|gitlab]
//
// Uses the app's database (accounts, repositories, stored snapshots) and the credentials MergeCue saved in the
// Keychain (macOS may ask for access). Runs the real adapter: authored listing, then hydrating each change request,
// printing counts, timings and the exact error for anything that fails. Nothing is written to the providers;
// tokens are never printed (errors pass through SecretRedactor).
import Foundation
import MergeCueCore
import MergeCueNetworking
import MergeCueRuntime
import MergeCueStore

@main
struct Diagnose {
    static func main() async {
        let filter = CommandLine.arguments.dropFirst().first.map { $0.lowercased() }
        let paths = MergeCuePaths()
        let database: MergeCueDatabase
        do {
            database = try MergeCueDatabase(url: paths.database)
        } catch {
            print("Cannot open the MergeCue database at \(paths.database.path): \(error)")
            exit(1)
        }
        let credentials = KeychainCredentialStore()
        let factory = LiveProviderFactory(clock: SystemClock(), appVersion: "diagnose")
        let accounts = ((try? await database.accounts()) ?? []).filter { account in
            guard let filter else { return true }
            return account.id.kind.rawValue.contains(filter) || account.id.kind.displayName.lowercased().contains(filter)
        }
        if accounts.isEmpty { print("No matching accounts connected in MergeCue."); return }
        let tracking = (try? await database.setting("engine.tracking_preferences", as: TrackingPreferences.self)) ?? .authoredOnly

        for account in accounts {
            print("\n=== \(account.id.kind.displayName) · @\(account.username) (\(account.instance.host))")
            print("selected namespaces: \(account.selectedNamespaces.isEmpty ? "all" : account.selectedNamespaces.joined(separator: ", "))")
            print("tracking: authored\(tracking.includeReviewRequests ? " + review requests" : "")\(tracking.includeInvolved ? " + involved" : "")")
            let stored = (try? await database.snapshots(account: account.id)) ?? []
            let repositories = (try? await database.repositories(account: account.id)) ?? []
            let synced = (try? await database.hasCompletedInitialSync(account: account.id)) ?? false
            print("stored: \(stored.count) change request(s), \(repositories.count) repositorie(s); initial sync done: \(synced)")
            guard let credential = try? credentials.load(for: account.id) else {
                print("!! no credential in the Keychain for this account"); continue
            }
            let provider = factory.makeProvider(account: account, credential: credential)
            let query = ChangeRequestQuery(scope: .authored, namespaces: account.selectedNamespaces, repositories: repositories)
            let started = Date()
            let page: ChangeRequestPage
            do {
                page = try await provider.listChangeRequests(query)
            } catch {
                print("!! authored listing FAILED after \(elapsed(started)): \(describe(error))")
                continue
            }
            print("authored listing: \(page.items.count) open (\(elapsed(started)))\(page.notModified ? " [not modified]" : "")")
            for summary in page.items {
                let label = "\(summary.repository.fullPath)\(summary.ref.kind.numberPrefix)\(summary.key.number)"
                let t0 = Date()
                do {
                    let snapshot = try await provider.hydrate(summary)
                    print("  ok  \(label): \(snapshot.threads.count) thread(s), \(snapshot.checks.count) check(s), \(snapshot.commits.count) commit(s) (\(elapsed(t0)))")
                } catch {
                    print("  !!  \(label): hydrate FAILED after \(elapsed(t0)): \(describe(error))")
                }
            }
        }
        print("\nDone. Nothing was changed. The output contains no tokens.")
    }

    static func elapsed(_ start: Date) -> String { String(format: "%.1fs", Date().timeIntervalSince(start)) }

    static func describe(_ error: any Error) -> String {
        let providerError = ProviderError.classify(error).map { "[\($0.code)] " } ?? ""
        return SecretRedactor.redact(providerError + String(describing: error))
    }
}
