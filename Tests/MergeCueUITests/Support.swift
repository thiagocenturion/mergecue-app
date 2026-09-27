import Foundation
import MergeCueCore
@testable import MergeCueUI

/// Frozen reference time for every UI test (13:45 local, like the snapshots).
let testNow = MergeCuePreview.referenceDate()

func previewState(_ variant: PreviewVariant = .standard) -> AppState {
    MergeCuePreview.makeState(variant: variant, now: testNow)
}

/// Records side effects of `AppEnvironment`.
@MainActor
final class EnvironmentRecorder {
    var copied: [String] = []
    var opened: [URL] = []

    var environment: AppEnvironment {
        AppEnvironment(now: { testNow }, copyToPasteboard: { [weak self] in self?.copied.append($0) },
                       openURL: { [weak self] in self?.opened.append($0) }, autoDismissBanners: false, tickInterval: nil)
    }
}

@MainActor
func makeModel(_ variant: PreviewVariant = .standard, recorder: EnvironmentRecorder = EnvironmentRecorder()) async -> AppModel {
    let model = AppModel(backend: MergeCuePreview.makeBackend(variant: variant, now: testNow), environment: recorder.environment)
    await model.reload()
    return model
}

extension AppState {
    func attention(_ kind: ProviderKind, number: Int, reason: AttentionReason) -> AttentionItem? {
        attention.first { $0.providerKind == kind && $0.number == number && $0.reason == reason }
    }

    func task(in state: TaskState) -> TaskRecord? {
        tasks.first { $0.task.state == state }
    }
}

extension PopoverItem {
    var attentionID: String? {
        if case .attention(let id) = source { return id }
        return nil
    }

    var taskID: TaskID? {
        if case .task(let id) = source { return id }
        return nil
    }
}
