import Foundation
import MergeCueCore

nonisolated extension PreviewWorld {
    func bitbucketPayments42() -> ChangeRequestSnapshot {
        let repo = repository(bb, id: "{1f0e5c8a-3b2d-4c6e-8f7a-9b0c1d2e3f40}", path: "acme/payments-api")
        let lucia = person("lucia.m", "Lucía Moreno", .bitbucketCloud)
        let head = "b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0"
        let summary = summary(repo, remoteID: "42", number: 42, title: "Harden webhook signature verification",
                              author: mona(.bitbucketCloud), involvement: [.authored], source: "feature/webhook-sig-v2", head: head,
                              created: ago(hours: 20), updated: ago(minutes: 2))
        let question = thread(summary, id: "412077331", anchor: DiffAnchor(
            path: "src/webhooks/signature.ts", line: 19, side: .new, commitSHA: head,
            diffHunk: """
            @@ -12,6 +12,14 @@ export function verifySignature(req: WebhookRequest, secret: string): boolean {
            +  const expected = createHmac("sha256", secret)
            +    .update(req.rawBody)
            +    .digest("hex");
            +  return timingSafeEqual(Buffer.from(expected), Buffer.from(req.signature));
             }
            """,
            nativePosition: ["to": "19", "path": "src/webhooks/signature.ts"]
        ), resolved: false, comments: [
            comment("412077331", lucia, "Why not reuse the existing `HmacVerifier` from payments-core here instead of a second implementation?",
                    at: ago(minutes: 2)),
        ])
        let general = thread(summary, id: "412060015", kind: .conversation, resolved: nil, resolvable: false, comments: [
            comment("412060015", mona(.bitbucketCloud), "Ready for review — this also rejects signatures older than 5 minutes.", at: ago(hours: 20)),
        ])
        return ChangeRequestSnapshot(
            summary: summary,
            description: "Verifies webhook signatures with a constant-time comparison and rejects replays older than 5 minutes.",
            reviewers: [Reviewer(person: lucia, state: .pending, isRequired: nil)],
            approvals: ApprovalStatus(approvedBy: [], requiredCount: nil, isSatisfied: nil),
            threads: [question, general],
            checks: [
                check(summary, .bitbucketPipelineStep, id: "{7d1e0c55-2a1b-4c3d-9e8f-0a1b2c3d4e5f}", name: "Pipeline #1187 · build",
                      status: .success, completed: ago(minutes: 30), detailsPath: "pipelines/results/1187"),
                check(summary, .bitbucketStatus, id: "security-scan", name: "security-scan", status: .success,
                      completed: ago(minutes: 28), detailsPath: "pipelines/results/1187"),
            ],
            commits: [CommitInfo(sha: "b1c2d3e", title: "Constant-time webhook signature check", author: "mona-dev", authoredAt: ago(hours: 20))],
            changedFiles: [
                ChangedFile(path: "src/webhooks/signature.ts", status: .modified, additions: 26, deletions: 9),
                ChangedFile(path: "src/webhooks/signature.test.ts", status: .modified, additions: 40, deletions: 2),
            ],
            readiness: .checksGreen,
            fetchedAt: ago(minutes: 4),
            nativeRefs: ["api": "https://api.bitbucket.org/2.0/repositories/acme/payments-api/pullrequests/42"]
        )
    }

    func bitbucketCheckout128() -> ChangeRequestSnapshot {
        let repo = repository(bb, id: "{2a1b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d}", path: "acme/checkout-web")
        let dchen = person("dchen", "Dana Chen", .bitbucketCloud)
        let head = "d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3"
        let summary = summary(repo, remoteID: "128", number: 128, title: "Move the Apple Pay button above the fold",
                              author: mona(.bitbucketCloud), involvement: [.authored], source: "feature/apple-pay-above-fold", head: head,
                              created: ago(hours: 9), updated: ago(minutes: 3))
        let layout = thread(summary, id: "412066120", anchor: DiffAnchor(
            path: "src/components/PaymentButtons.tsx", line: 64, side: .new, commitSHA: head,
            diffHunk: """
            @@ -58,7 +58,9 @@ export function PaymentButtons({ total }: Props) {
               return (
            -    <Stack direction="column">
            +    <Stack direction="row" gap={8}>
                   <ApplePayButton amount={total} />
            """
        ), resolved: false, comments: [
            comment("412066120", dchen, "On 320 pt wide screens the button now overlaps the promo banner — please stack them below 360 pt.",
                    at: ago(minutes: 45)),
        ])
        return ChangeRequestSnapshot(
            summary: summary,
            description: "Moves the Apple Pay button next to the card button so it is visible without scrolling.",
            reviewers: [Reviewer(person: dchen, state: .changesRequested, isRequired: nil)],
            approvals: ApprovalStatus(approvedBy: [], requiredCount: nil, isSatisfied: nil),
            threads: [layout],
            checks: [check(summary, .bitbucketStatus, id: "build", name: "build", status: .success, completed: ago(hours: 8),
                           detailsPath: "pipelines/results/2210")],
            commits: [CommitInfo(sha: "d4e5f6a", title: "Row layout for payment buttons", author: "mona-dev", authoredAt: ago(hours: 9))],
            changedFiles: [ChangedFile(path: "src/components/PaymentButtons.tsx", status: .modified, additions: 12, deletions: 5)],
            readiness: .blocked(reasons: ["Changes requested"]),
            fetchedAt: ago(minutes: 4)
        )
    }

    func bitbucketRisk9() -> ChangeRequestSnapshot {
        let repo = repository(bb, id: "{3c2d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f}", path: "acme/risk-rules")
        let nina = person("nina.w", "Nina Weber", .bitbucketCloud)
        let summary = summary(repo, remoteID: "9", number: 9, title: "Tighten velocity rule thresholds",
                              author: nina, involvement: [.reviewRequested], source: "nina/velocity-thresholds",
                              head: "e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5", created: ago(hours: 6), updated: ago(minutes: 50))
        return ChangeRequestSnapshot(
            summary: summary,
            description: "Lowers the card-velocity threshold from 12 to 8 attempts per 10 minutes for new merchants.",
            reviewers: [Reviewer(person: mona(.bitbucketCloud), state: .pending, isRequired: nil)],
            approvals: ApprovalStatus(approvedBy: [], requiredCount: nil, isSatisfied: nil),
            checks: [check(summary, .bitbucketStatus, id: "rules-lint", name: "rules-lint", status: .success, completed: ago(hours: 5),
                           detailsPath: "pipelines/results/318")],
            commits: [CommitInfo(sha: "e6f7a8b", title: "Velocity thresholds for new merchants", author: "nina.w", authoredAt: ago(hours: 6))],
            changedFiles: [ChangedFile(path: "rules/velocity.yaml", status: .modified, additions: 6, deletions: 6)],
            readiness: .checksGreen,
            fetchedAt: ago(minutes: 4)
        )
    }

    func bitbucketCheckout131(logs: inout [String: LogExcerpt]) -> ChangeRequestSnapshot {
        let repo = repository(bb, id: "{2a1b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d}", path: "acme/checkout-web")
        let head = "f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6"
        let summary = summary(repo, remoteID: "131", number: 131, title: "Localize checkout errors (pt-BR)",
                              author: mona(.bitbucketCloud), involvement: [.authored], source: "feature/pt-br-errors", head: head,
                              created: ago(hours: 30), updated: ago(minutes: 40))
        let safari = check(summary, .bitbucketPipelineStep, id: "{9a8b7c6d-5e4f-4a3b-2c1d-0e9f8a7b6c5d}", name: "e2e / safari",
                           status: .failure, required: nil, started: ago(hours: 2), completed: ago(minutes: 95),
                           summaryText: "1 failed, 37 passed", detailsPath: "pipelines/results/2231")
        logs[safari.key.id] = LogExcerpt.make(rawLog: """
        + npx playwright test --project=webkit
        Running 38 tests using 4 workers
          ✓  checkout/errors.spec.ts:12:3 › shows card declined in pt-BR (2.1s)
          ✘  checkout/errors.spec.ts:31:3 › shows expired card message in pt-BR (5.0s)
            Error: expect(locator).toHaveText(expected)
            Expected string: "Cartão expirado. Use outro cartão."
            Received string: "Card expired. Use another card."
        1 failed
          checkout/errors.spec.ts:31:3 › shows expired card message in pt-BR
        37 passed (1.4m)
        Step "e2e / safari" failed with exit code 1
        """, maxBytes: 16_384, fullLogURL: safari.detailsURL)
        return ChangeRequestSnapshot(
            summary: summary,
            description: "Adds pt-BR translations for checkout error messages.",
            reviewers: [],
            approvals: ApprovalStatus(approvedBy: [], requiredCount: nil, isSatisfied: nil),
            threads: [],
            checks: [
                safari,
                check(summary, .bitbucketPipelineStep, id: "{1b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e}", name: "e2e / chromium",
                      status: .success, completed: ago(minutes: 100), detailsPath: "pipelines/results/2231"),
            ],
            commits: [CommitInfo(sha: "f7a8b9c", title: "pt-BR checkout error strings", author: "mona-dev", authoredAt: ago(hours: 30))],
            changedFiles: [
                ChangedFile(path: "src/i18n/pt-BR/checkout.json", status: .added, additions: 48, deletions: 0),
                ChangedFile(path: "src/checkout/errors.ts", status: .modified, additions: 6, deletions: 2),
            ],
            readiness: .blocked(reasons: ["1 failing check"]),
            fetchedAt: ago(minutes: 4)
        )
    }
}
