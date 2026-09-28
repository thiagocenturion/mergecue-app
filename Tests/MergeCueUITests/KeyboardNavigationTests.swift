import Foundation
import MergeCueCore
import Testing
@testable import MergeCueUI

/// Keyboard operation of the popover and the window's lists, window titles and the global shortcut presets.
@Suite("Keyboard navigation")
@MainActor
struct KeyboardNavigationTests {
    @Test func steppingClampsAndStartsAtTheEnds() {
        let ids = ["a", "b", "c"]
        #expect(KeyboardSelection.step(ids, from: nil, by: 1) == "a")
        #expect(KeyboardSelection.step(ids, from: nil, by: -1) == "c")
        #expect(KeyboardSelection.step(ids, from: "b", by: 1) == "c")
        #expect(KeyboardSelection.step(ids, from: "c", by: 1) == "c")
        #expect(KeyboardSelection.step(ids, from: "a", by: -1) == "a")
        #expect(KeyboardSelection.step(ids, from: "gone", by: 1) == "a")
        #expect(KeyboardSelection.step([String](), from: nil, by: 1) == nil)
    }

    @Test func popoverReturnOpensDetailsAndCommandReturnRunsThePrimaryAction() async throws {
        let model = await makeModel()
        var opened = 0
        model.openMainWindowHandler = { opened += 1 }
        let first = try #require(model.popoverRows.first)
        model.popoverSelection = first.id

        // Return / Space: the row's details in the main window, like a click — no task is created.
        model.openPopoverSelection()
        #expect(opened == 1)
        #expect(model.screen == .inbox)
        #expect(model.selectedAttentionID == first.attentionID)
        #expect(model.handoffOffer == nil)

        // ⌘↩: the primary action ("Fix with AI").
        await model.activatePopoverSelection()
        #expect(model.handoffOffer != nil)
    }

    @Test func eachPopoverShowResetsSelectionAndFocus() async {
        let model = await makeModel()
        model.movePopoverSelection(by: 2)
        let count = model.popoverPresentationCount
        model.popoverWillShow(fromKeyboard: false)
        #expect(model.popoverSelection == nil)
        #expect(model.popoverPresentationCount == count + 1)
        // Opened with the global shortcut: the first row is selected so ↑/↓/Return work at once.
        model.popoverWillShow(fromKeyboard: true)
        #expect(model.popoverSelection == model.popoverRows.first?.id)
        #expect(model.popoverPresentationCount == count + 2)
    }

    @Test func unreadIsSpokenNotOnlyColoured() async throws {
        let model = await makeModel()
        let unread = try #require(model.popoverRows.first { $0.isUnread })
        #expect(unread.accessibilityLabel(now: testNow).hasPrefix("Unread. "))
        var read = unread
        read.isUnread = false
        #expect(!read.accessibilityLabel(now: testNow).contains("Unread"))
    }

    @Test func inboxArrowKeysFollowTheListOrder() async throws {
        let model = await makeModel()
        let order = model.inboxKeyboardOrder
        #expect(order.count >= 3)
        model.selectedAttentionID = nil
        model.moveInboxSelection(by: 1)
        #expect(model.selectedAttentionID == order[0])
        model.moveInboxSelection(by: 1)
        #expect(model.selectedAttentionID == order[1])
        model.changeRequestTab = .files
        model.moveInboxSelection(by: -1)
        #expect(model.selectedAttentionID == order[0])
        #expect(model.changeRequestTab == .conversation, "a new selection starts on its conversation")
        model.moveInboxSelection(by: -5)
        #expect(model.selectedAttentionID == order[0])
    }

    @Test func inboxReturnMarksReadAndCommandReturnRunsFixWithAI() async throws {
        let model = await makeModel()
        let item = try #require(model.state.attention(.github, number: 42, reason: .changesRequested))
        #expect(model.activeTask(for: item) == nil)
        model.selectedAttentionID = item.id
        var opened = 0
        model.openMainWindowHandler = { opened += 1 }
        await model.performInboxPrimaryAction()
        #expect(model.screen == .tasks, "⌘↩ creates the task and opens its handoff screen")
        let task = try #require(model.task(model.selectedTaskID))
        #expect(task.task.origin.attentionItemID == item.id)
        #expect(task.task.state == .waitingForAgent)

        // With an active task, ⌘↩ opens that task instead of creating another.
        model.screen = .inbox
        model.selectedAttentionID = item.id
        let tasks = model.state.tasks.count
        await model.performInboxPrimaryAction()
        #expect(model.state.tasks.count == tasks)
        #expect(model.selectedTaskID == task.id)
    }

    @Test func changeRequestAndRuleListsMoveWithArrowKeys() async throws {
        let model = await makeModel()
        let prs = model.changeRequestKeyboardOrder
        #expect(prs.count >= 2)
        model.moveChangeRequestSelection(by: 1)
        #expect(model.selectedChangeRequestID == prs[0])
        model.moveChangeRequestSelection(by: 1)
        #expect(model.selectedChangeRequestID == prs[1])

        let rules = model.ruleKeyboardOrder
        #expect(!rules.isEmpty)
        model.moveRuleSelection(by: 1)
        #expect(model.selectedRuleID == rules[0])
        #expect(model.ruleEditor == nil)
        model.performRulePrimaryAction()
        #expect(model.ruleEditor != nil, "⌘↩ on a rule opens the editor")
    }

    @Test func windowTitleFollowsTheScreen() async throws {
        let model = await makeModel()
        model.screen = .inbox
        model.selectedAttentionID = nil
        #expect(model.windowTitle.title == "Inbox")
        #expect(model.windowTitle.subtitle == "MergeCue · Preview data")
        let item = try #require(model.state.attention(.github, number: 42, reason: .changesRequested))
        model.selectedAttentionID = item.id
        #expect(model.windowTitle.title == "Inbox — \(item.repoFullPath) #42")
        model.screen = .settings
        model.settingsTab = .notifications
        #expect(model.windowTitle.title == "Settings — Notifications")
        model.screen = .tasks
        model.selectedTaskID = nil
        #expect(model.windowTitle.title == "Tasks")
        let ready = try #require(model.state.task(in: .readyForReview))
        model.selectedTaskID = ready.id
        #expect(model.windowTitle.title == "Task \(ready.id.rawValue) — Ready")
    }

    @Test func hotKeyPresetsAreCarbonCombinations() {
        #expect(HotKeyPreset.defaultPreset == .controlOptionCommandM)
        #expect(HotKeyPreset.controlOptionCommandM.keyCode == 0x2E)
        #expect(HotKeyPreset.controlOptionCommandM.carbonModifiers == 0x1000 | 0x800 | 0x100)
        #expect(HotKeyPreset.off.keyCode == nil)
        for preset in HotKeyPreset.allCases where preset != .off {
            #expect(preset.keyCode != nil)
            #expect(preset.carbonModifiers & 0x100 != 0 || preset.carbonModifiers & 0x1000 != 0,
                    "\(preset.displayName) needs ⌘ or ⌃ so it can't collide with typing")
        }
    }

    @Test func textSizeAndShortcutPersist() async {
        let store = PreferenceStore.inMemory()
        var environment = AppEnvironment.fixed(now: testNow)
        environment.preferences = store
        let model = AppModel(backend: MergeCuePreview.makeBackend(variant: .standard, now: testNow), environment: environment)
        #expect(model.textSize == .standard)
        #expect(model.globalHotKey == .defaultPreset)
        model.textSize = .larger
        model.globalHotKey = .off
        #expect(store.load(UIPreferenceKeys.textSize) == "larger")

        let relaunched = AppModel(backend: MergeCuePreview.makeBackend(variant: .standard, now: testNow), environment: environment)
        #expect(relaunched.textSize == .larger)
        #expect(relaunched.globalHotKey == .off)
    }
}
