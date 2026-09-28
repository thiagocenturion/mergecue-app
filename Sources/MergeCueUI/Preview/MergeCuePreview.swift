import Foundation
import MergeCueCore
import SwiftUI

/// Entry points for the synthetic preview (app shell without the engine, SwiftUI previews, snapshots, tests).
public enum MergeCuePreview {
    /// A live-clock preview backend. The UI shows a persistent "Preview data" badge.
    public nonisolated static func makeBackend(variant: PreviewVariant = .standard) -> any AppBackend {
        PreviewBackend(variant: variant)
    }

    /// A preview backend frozen at `now` (reproducible snapshots and tests).
    public nonisolated static func makeBackend(variant: PreviewVariant, now: Date) -> any AppBackend {
        PreviewBackend(variant: variant, now: { now })
    }

    /// The initial state of a variant at `now`.
    public nonisolated static func makeState(variant: PreviewVariant, now: Date) -> AppState {
        PreviewBackend.initialState(variant: variant, now: now)
    }

    /// A ready-to-render model with a frozen clock and no side effects (snapshots).
    public static func makeModel(variant: PreviewVariant = .standard, now: Date = referenceDate()) -> AppModel {
        let model = AppModel(backend: makeBackend(variant: variant, now: now), initialState: makeState(variant: variant, now: now),
                             environment: .fixed(now: now))
        for (id, excerpt) in PreviewBackend.logExcerpts(now: now) {
            model.seedLogExcerpt(excerpt, checkID: id)
        }
        return model
    }

    /// The connect-account sheet on its own (snapshots).
    public static func connectAccountSheet(model: AppModel, kind: ProviderKind) -> some View {
        ConnectAccountSheet(model: model, kind: kind)
    }

    /// The approval sheet for `preview` on its own (snapshots).
    public static func approvalSheet(model: AppModel, preview: ActionPreview) -> some View {
        ApprovalSheet(model: model, preview: preview)
    }

    /// Today at 13:45 local time: the frozen "now" of snapshots (so "Rate limited until 14:05" reads naturally).
    public nonisolated static func referenceDate(calendar: Calendar = .current) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28)) ?? Date(timeIntervalSince1970: 1_790_000_000)
        return calendar.date(bySettingHour: 13, minute: 45, second: 0, of: base) ?? base
    }
}
