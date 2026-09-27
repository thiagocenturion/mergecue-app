import MergeCueCore
import SwiftUI

/// Inbox list: filters (Mine/Reviewing/All, provider, account, repository, status, search, collapse read) and
/// items grouped per provider-qualified change request.
struct InboxList: View {
    @Bindable var model: AppModel

    var body: some View {
        let result = InboxQuery.run(state: model.state, filter: model.inboxFilter, now: model.now, showRead: model.showReadInInbox)
        VStack(spacing: 0) {
            InboxFilterBar(model: model)
            Divider()
            if result.groups.isEmpty {
                emptyState(result)
            } else {
                List(selection: $model.selectedAttentionID) {
                    ForEach(result.groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                InboxItemRow(model: model, item: item)
                                    .tag(item.id as String?)
                            }
                        } header: {
                            InboxGroupHeader(group: group)
                        }
                    }
                    if result.hiddenReadCount > 0 {
                        Button {
                            model.showReadInInbox = true
                        } label: {
                            Label("Show \(result.hiddenReadCount) read item\(result.hiddenReadCount == 1 ? "" : "s")", systemImage: "chevron.down.circle")
                                .font(.callout)
                        }
                        .buttonStyle(.link)
                        .padding(.vertical, 4)
                    } else if model.showReadInInbox && model.inboxFilter.collapseRead {
                        Button {
                            model.showReadInInbox = false
                        } label: {
                            Label("Collapse read items", systemImage: "chevron.up.circle")
                                .font(.callout)
                        }
                        .buttonStyle(.link)
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .navigationTitle("Inbox")
    }

    @ViewBuilder
    private func emptyState(_ result: InboxResult) -> some View {
        if model.state.accounts.isEmpty {
            NothingSelected(title: "No accounts", symbol: "person.crop.circle.badge.plus",
                            message: "Connect GitHub, GitLab or Bitbucket Cloud in Settings › Accounts.")
        } else if model.inboxFilter.isNarrowed {
            ContentUnavailableView {
                Label("No matching items", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Nothing matches these filters.")
            } actions: {
                Button("Clear Filters") { model.inboxFilter = InboxFilter(collapseRead: model.inboxFilter.collapseRead) }
            }
        } else if result.hiddenReadCount > 0 {
            ContentUnavailableView {
                Label("No new activity", systemImage: "checkmark.circle")
            } description: {
                Text("You're all caught up. \(result.hiddenReadCount) read item\(result.hiddenReadCount == 1 ? " is" : "s are") collapsed.")
            } actions: {
                Button("Show Read Items") { model.showReadInInbox = true }
            }
        } else {
            NothingSelected(title: "No new activity", symbol: "checkmark.circle", message: "You're all caught up.")
        }
    }
}

struct InboxFilterBar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Scope", selection: $model.inboxFilter.scope) {
                    ForEach(InboxScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 4)
                Toggle("Hide read", isOn: $model.inboxFilter.collapseRead)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .fixedSize()
                    .help("Collapse already-read activity")
            }
            SearchField(text: $model.inboxFilter.searchText, prompt: "Search title, repo, #42…")
            HStack(spacing: 6) {
                FilterMenu(title: model.inboxFilter.provider?.displayName ?? "Provider", isActive: model.inboxFilter.provider != nil) {
                    Button("Any Provider") { model.inboxFilter.provider = nil }
                    Divider()
                    ForEach(ProviderKind.allCases, id: \.self) { kind in
                        Button(kind.displayName) { model.inboxFilter.provider = kind }
                    }
                }
                FilterMenu(title: model.inboxFilter.account.map { model.accountTitle($0) } ?? "Account", isActive: model.inboxFilter.account != nil) {
                    Button("Any Account") { model.inboxFilter.account = nil }
                    Divider()
                    ForEach(model.state.accounts) { account in
                        Button(model.accountTitle(account.id)) { model.inboxFilter.account = account.id }
                    }
                }
                FilterMenu(title: repoTitle, isActive: model.inboxFilter.repo != nil) {
                    Button("Any Repository") { model.inboxFilter.repo = nil }
                    Divider()
                    ForEach(model.knownRepositories, id: \.key) { repo in
                        Button("\(repo.fullPath) · \(repo.providerKind.displayName)") { model.inboxFilter.repo = repo.key }
                    }
                }
                FilterMenu(title: model.inboxFilter.status == .all ? "Status" : model.inboxFilter.status.title, isActive: model.inboxFilter.status != .all) {
                    ForEach(InboxStatusFilter.allCases) { status in
                        Button(status.title) { model.inboxFilter.status = status }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var repoTitle: String {
        guard let key = model.inboxFilter.repo,
              let repo = model.knownRepositories.first(where: { $0.key == key }) else { return "Repository" }
        return repo.name
    }
}

/// A compact pull-down used by filter bars.
struct FilterMenu<Content: View>: View {
    var title: String
    var isActive: Bool
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Text(title)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isActive ? Theme.accent : nil)
        .fixedSize()
        .accessibilityLabel("\(title) filter")
    }
}

/// Rounded search field with a magnifying glass (kept inside the content so snapshots show it).
struct SearchField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

struct InboxGroupHeader: View {
    let group: InboxGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ChangeRequestRefLabel(kind: group.providerKind, repoFullPath: group.repoFullPath, number: group.changeRequest.number,
                                  font: .caption, glyphSize: 13)
            Text(group.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textCase(nil)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}

struct InboxItemRow: View {
    let model: AppModel
    let item: AttentionItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(item.isUnread ? Theme.accent : Color.clear)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
                .accessibilityHidden(true)
            Image(systemName: item.reason.symbolName)
                .font(.callout)
                .foregroundStyle(Theme.color(item.reason.tone))
                .frame(width: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.reason.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.color(item.reason.tone))
                    Spacer(minLength: 4)
                    Text(UIFormat.compactAge(from: item.updatedAt, now: model.now))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(item.summary)
                    .font(.callout.weight(item.isUnread ? .semibold : .regular))
                    .lineLimit(2)
                statusLine
            }
        }
        .padding(.vertical, 3)
        .opacity(item.isActionable(now: model.now) || item.isUnread ? 1 : 0.72)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.isUnread ? "Unread. " : "")\(item.reason.displayName): \(item.summary). \(item.providerKind.displayName) \(item.repoFullPath) \(item.providerKind.formattedNumber(item.number))")
    }

    @ViewBuilder
    private var statusLine: some View {
        let task = model.task(item.linkedTaskID)
        let chips = HStack(spacing: 4) {
            if let task {
                Chip(text: "\(task.id.rawValue) · \(task.task.state.displayName)", symbol: task.task.state.symbolName, tone: task.task.state.tone)
            }
            switch item.disposition {
            case .snoozed(let until) where until > model.now:
                Chip(text: "Snoozed until \(UIFormat.time(until))", symbol: "moon.zzz")
            case .acknowledged:
                Chip(text: "Acknowledged", symbol: "checkmark")
            case .resolved:
                Chip(text: "Resolved", symbol: "checkmark.circle", tone: .success)
            case .dismissed:
                Chip(text: "Dismissed", symbol: "archivebox")
            default:
                EmptyView()
            }
        }
        if task != nil || item.disposition != .open { chips }
    }
}
