import Foundation

/// GraphQL documents used by the adapter. Every operation is named (`MergeCue…`) and the name is also sent as
/// `operationName`, so stub transports can dispatch on it.
///
/// Ids: `fullDatabaseId` (BigInt, serialized as a string) is used for pull requests, reviews and comments because
/// their `databaseId` (32-bit `Int`) is deprecated. Repositories, users and check runs keep `databaseId`.
enum GitHubQuery: String, Sendable, CaseIterable {
    case search = "MergeCueSearch"
    case pullRequest = "MergeCuePullRequest"
    case reviewThreadsPage = "MergeCueReviewThreadsPage"
    case issueCommentsPage = "MergeCueIssueCommentsPage"
    case reviewsPage = "MergeCueReviewsPage"
    case checkContextsPage = "MergeCueCheckContextsPage"
    case thread = "MergeCueThread"
    case threadCommentsPage = "MergeCueThreadCommentsPage"
    case resolveThread = "MergeCueResolveThread"
    case unresolveThread = "MergeCueUnresolveThread"

    /// Page sizes (GitHub caps `first`/`last` at 100).
    static let searchPageSize = 50
    static let threadPageSize = 50
    static let commentPageSize = 50

    var operationName: String { rawValue }

    var document: String {
        switch self {
        case .search:
            """
            query MergeCueSearch($q: String!, $first: Int!, $after: String) {
              viewer { login databaseId name avatarUrl }
              search(query: $q, type: ISSUE, first: $first, after: $after) {
                issueCount
                pageInfo { hasNextPage endCursor }
                nodes {
                  __typename
                  ... on PullRequest {
                    id fullDatabaseId number title url state isDraft createdAt updatedAt
                    headRefName baseRefName headRefOid baseRefOid isCrossRepository
                    author { ...MCActor }
                    repository { ...MCRepo }
                    headCommit: commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } }
                  }
                }
              }
            }
            """ + Self.actorFragment + Self.repoFragment

        case .pullRequest:
            """
            query MergeCuePullRequest($owner: String!, $name: String!, $number: Int!) {
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) {
                  id fullDatabaseId number title body url state isDraft createdAt updatedAt
                  headRefName baseRefName headRefOid baseRefOid isCrossRepository
                  mergeStateStatus mergeable reviewDecision
                  author { ...MCActor }
                  repository { ...MCRepo }
                  headRepository { ...MCRepo }
                  reviewRequests(first: 50) {
                    nodes {
                      asCodeOwner
                      requestedReviewer {
                        __typename
                        ... on User { login databaseId name avatarUrl }
                        ... on Bot { login databaseId avatarUrl }
                        ... on Mannequin { login databaseId avatarUrl }
                        ... on Team { name slug databaseId avatarUrl }
                      }
                    }
                  }
                  latestReviews(first: 50) { nodes { state author { ...MCActor } } }
                  reviews(first: 50) { pageInfo { hasNextPage endCursor } nodes { ...MCReview } }
                  comments(first: 50) { pageInfo { hasNextPage endCursor } nodes { ...MCIssueComment } }
                  reviewThreads(first: 50) { pageInfo { hasNextPage endCursor } nodes { ...MCThread } }
                  commits(last: 100) {
                    nodes { commit { oid messageHeadline authoredDate author { name user { login } } } }
                  }
                  files(first: 100) { totalCount nodes { path additions deletions changeType } }
                  headCommit: commits(last: 1) {
                    nodes {
                      commit {
                        oid
                        statusCheckRollup {
                          state
                          contexts(first: 100) { pageInfo { hasNextPage endCursor } nodes { ...MCContext } }
                        }
                      }
                    }
                  }
                }
              }
            }
            """ + Self.actorFragment + Self.repoFragment + Self.reviewFragment + Self.issueCommentFragment
                + Self.threadFragment + Self.reviewCommentFragment + Self.contextFragment

        case .reviewThreadsPage:
            """
            query MergeCueReviewThreadsPage($owner: String!, $name: String!, $number: Int!, $after: String) {
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) {
                  reviewThreads(first: 50, after: $after) { pageInfo { hasNextPage endCursor } nodes { ...MCThread } }
                }
              }
            }
            """ + Self.actorFragment + Self.threadFragment + Self.reviewCommentFragment

        case .issueCommentsPage:
            """
            query MergeCueIssueCommentsPage($owner: String!, $name: String!, $number: Int!, $after: String) {
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) {
                  comments(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { ...MCIssueComment } }
                }
              }
            }
            """ + Self.actorFragment + Self.issueCommentFragment

        case .reviewsPage:
            """
            query MergeCueReviewsPage($owner: String!, $name: String!, $number: Int!, $after: String) {
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) {
                  reviews(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { ...MCReview } }
                }
              }
            }
            """ + Self.actorFragment + Self.reviewFragment

        case .checkContextsPage:
            """
            query MergeCueCheckContextsPage($owner: String!, $name: String!, $number: Int!, $after: String) {
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) {
                  headCommit: commits(last: 1) {
                    nodes {
                      commit {
                        oid
                        statusCheckRollup {
                          state
                          contexts(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { ...MCContext } }
                        }
                      }
                    }
                  }
                }
              }
            }
            """ + Self.contextFragment

        case .thread:
            """
            query MergeCueThread($id: ID!) {
              node(id: $id) { __typename ...MCThread }
            }
            """ + Self.actorFragment + Self.threadFragment + Self.reviewCommentFragment

        case .threadCommentsPage:
            """
            query MergeCueThreadCommentsPage($id: ID!, $after: String) {
              node(id: $id) {
                __typename
                ... on PullRequestReviewThread {
                  comments(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { ...MCReviewComment } }
                }
              }
            }
            """ + Self.actorFragment + Self.reviewCommentFragment

        case .resolveThread:
            """
            mutation MergeCueResolveThread($id: ID!) {
              resolveReviewThread(input: {threadId: $id}) { thread { id isResolved } }
            }
            """

        case .unresolveThread:
            """
            mutation MergeCueUnresolveThread($id: ID!) {
              unresolveReviewThread(input: {threadId: $id}) { thread { id isResolved } }
            }
            """
        }
    }

    // MARK: Fragments

    private static let actorFragment = """

        fragment MCActor on Actor {
          __typename login avatarUrl
          ... on User { databaseId name }
          ... on Bot { databaseId }
          ... on Mannequin { databaseId }
        }
        """

    private static let repoFragment = """

        fragment MCRepo on Repository {
          databaseId name nameWithOwner url sshUrl isPrivate
          owner { login }
          defaultBranchRef { name }
        }
        """

    private static let reviewFragment = """

        fragment MCReview on PullRequestReview {
          id fullDatabaseId body state submittedAt url
          author { ...MCActor }
          commit { oid }
        }
        """

    private static let issueCommentFragment = """

        fragment MCIssueComment on IssueComment {
          id fullDatabaseId body url createdAt updatedAt
          author { ...MCActor }
        }
        """

    private static let threadFragment = """

        fragment MCThread on PullRequestReviewThread {
          id isResolved isOutdated path line startLine originalLine originalStartLine diffSide startDiffSide subjectType
          viewerCanResolve viewerCanUnresolve viewerCanReply
          pullRequest { number }
          repository { databaseId nameWithOwner }
          comments(first: 50) { pageInfo { hasNextPage endCursor } nodes { ...MCReviewComment } }
        }
        """

    private static let reviewCommentFragment = """

        fragment MCReviewComment on PullRequestReviewComment {
          id fullDatabaseId body url createdAt updatedAt diffHunk outdated
          author { ...MCActor }
          replyTo { fullDatabaseId }
          commit { oid }
          originalCommit { oid }
        }
        """

    private static let contextFragment = """

        fragment MCContext on StatusCheckRollupContext {
          __typename
          ... on CheckRun {
            databaseId name status conclusion detailsUrl url title summary startedAt completedAt
            isRequired(pullRequestNumber: $number)
            checkSuite { app { slug name } workflowRun { databaseId runNumber workflow { name } } }
          }
          ... on StatusContext {
            id context state targetUrl description createdAt
            isRequired(pullRequestNumber: $number)
          }
        }
        """
}
