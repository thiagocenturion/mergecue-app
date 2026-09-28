import MergeCueCore

extension BitbucketCloudProvider {
    /// What the Bitbucket Cloud adapter supports (manifest version 1).
    ///
    /// Write capabilities are implemented; whether they may be used is decided by `Account.writesEnabled`, the
    /// token's scopes (`write:pullrequest:bitbucket`) and per-action approval — not by this manifest.
    public static let capabilityManifest = CapabilityManifest(
        provider: .bitbucketCloud,
        manifestVersion: 1,
        entries: [
            .listAuthored: .supported,
            .listReviewRequested: .partial(
                note: "Bitbucket has no cross-repository reviewer search; MergeCue queries each selected repository "
                    + "(or up to 30 recently updated repositories of the selected workspaces)."
            ),
            .listInvolved: .partial(
                note: "Per-repository BBQL on participants (reviewed, approved or commented), over the same repositories "
                    + "as review requests (selected, or up to 30 recently updated ones)."
            ),
            .readThreads: .partial(
                note: "Outdated inline comments are detected from the comment's anchor commit; Bitbucket does not "
                    + "always report them explicitly."
            ),
            .resolveThread: .supported,
            .readChecks: .supported,
            .readFailureLog: .partial(
                note: "Bitbucket Pipelines step logs only; external commit statuses expose just their details link."
            ),
            .requestChanges: .supported,
            .createReply: .supported,
            .merge: .partial(
                note: "Bitbucket's merge endpoint has no head-SHA guard: MergeCue re-checks the head right before "
                    + "merging, but a push in the remaining window can still be merged. Merge checks that need admin "
                    + "access are not evaluated, so MergeCue never reports \"Ready to merge\" for Bitbucket."
            ),
            .fetchHead: .supported,
            .deepLink: .supported,
        ]
    )
}
