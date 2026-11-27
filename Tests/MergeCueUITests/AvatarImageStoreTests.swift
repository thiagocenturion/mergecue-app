import AppKit
import Foundation
import MergeCueCore
@testable import MergeCueUI
import Testing

/// Counts loads per URL; can hold every load until `release()` and fail on demand. Never touches the network.
private final class FakeAvatarLoader: AvatarImageLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [URL: Int] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var held: Bool
    var failing = false

    init(held: Bool = false) { self.held = held }

    func count(_ url: URL) -> Int { lock.withLock { counts[url] ?? 0 } }
    var pending: Int { lock.withLock { waiters.count } }

    func release() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            held = false
            defer { waiters.removeAll() }
            return waiters
        }
        resumed.forEach { $0.resume() }
    }

    func imageData(for url: URL) async throws -> Data {
        let (mustWait, shouldFail) = lock.withLock { () -> (Bool, Bool) in
            counts[url, default: 0] += 1
            return (held, failing)
        }
        if mustWait {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if !held { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return try #require(PreviewAvatarLoader.png(seed: url.lastPathComponent, pixels: 32))
    }
}

/// A mutable clock for expiry tests.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = testNow
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

@MainActor
@Suite("Avatar image cache (D58)")
struct AvatarImageStoreTests {
    let avatar = URL(string: "https://avatars.githubusercontent.com/u/700101?v=4")!

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "mergecue-avatars-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func missLoadsOnceThenHitsMemory() async {
        let loader = FakeAvatarLoader()
        let store = AvatarImageStore(directory: nil, loader: loader)
        #expect(store.cachedImage(for: avatar) == nil)
        let first = await store.image(for: avatar)
        let second = await store.image(for: avatar)
        #expect(first != nil)
        #expect(second === first)
        #expect(store.cachedImage(for: avatar) === first)
        #expect(loader.count(avatar) == 1)
    }

    @Test func concurrentRequestsShareOneDownload() async throws {
        let loader = FakeAvatarLoader(held: true)
        let store = AvatarImageStore(directory: nil, loader: loader)
        async let a = store.image(for: avatar)
        async let b = store.image(for: avatar)
        async let c = store.image(for: avatar)
        // Wait until the single download is parked in the loader, then let it finish.
        for _ in 0..<200 where loader.pending == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(loader.pending == 1)
        loader.release()
        let images = await [a, b, c]
        #expect(images.allSatisfy { $0 != nil })
        #expect(images[0] === images[1] && images[1] === images[2])
        #expect(loader.count(avatar) == 1)
    }

    @Test func diskCopySurvivesANewStoreAndServesOffline() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = FakeAvatarLoader()
        let first = AvatarImageStore(directory: directory, loader: loader)
        #expect(await first.image(for: avatar) != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(files.count == 1)
        #expect(files.first?.hasSuffix(".avatar") == true)

        // A fresh store (app relaunch) reads the disk copy without asking the loader, even offline.
        loader.failing = true
        let second = AvatarImageStore(directory: directory, loader: loader)
        #expect(await second.image(for: avatar) != nil)
        #expect(loader.count(avatar) == 1)
    }

    @Test func staleCopyIsRefreshedAndUsedWhenTheRefreshFails() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let loader = FakeAvatarLoader()
        let make = { AvatarImageStore(directory: directory, loader: loader, freshFor: 3600, keepFor: 7200, now: { clock.now }) }
        #expect(await make().image(for: avatar) != nil)

        clock.advance(5400) // stale but kept: refetched, and the stale copy covers a failed refetch
        loader.failing = true
        #expect(await make().image(for: avatar) != nil)
        #expect(loader.count(avatar) == 2)

        clock.advance(7200) // past keepFor: gone, so nothing to fall back on
        #expect(await make().image(for: avatar) == nil)
    }

    @Test func diskCacheStaysUnderItsCap() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let disk = AvatarDiskCache(directory: directory, maxBytes: 1000, freshFor: 3600, keepFor: 7200, now: { clock.now })
        for index in 0..<10 {
            clock.advance(1)
            await disk.write(Data(repeating: UInt8(index), count: 300), for: URL(string: "https://example.com/\(index).png")!)
        }
        #expect(await disk.totalSize() <= 1000)
        // The newest entry survives eviction, the oldest does not.
        #expect(await disk.read(URL(string: "https://example.com/9.png")!) != nil)
        #expect(await disk.read(URL(string: "https://example.com/0.png")!) == nil)
    }

    @Test func refusesNonHTTPSAndCredentialURLs() async {
        let loader = FakeAvatarLoader()
        let store = AvatarImageStore(directory: nil, loader: loader)
        for raw in ["http://avatars.example.com/a.png", "https://user:secret@avatars.example.com/a.png", "file:///etc/passwd"] {
            let url = URL(string: raw)!
            #expect(!AvatarImageStore.isAllowed(url))
            #expect(await store.image(for: url) == nil)
            #expect(loader.count(url) == 0)
        }
        #expect(AvatarImageStore.isAllowed(avatar))
    }

    @Test func failureFallsBackToInitialsAndIsNotRetriedRightAway() async {
        let loader = FakeAvatarLoader()
        loader.failing = true
        let store = AvatarImageStore(directory: nil, loader: loader)
        #expect(await store.image(for: avatar) == nil)
        #expect(await store.image(for: avatar) == nil)
        #expect(loader.count(avatar) == 1)
        #expect(store.cachedImage(for: avatar) == nil)
    }

    @Test func bytesThatAreNotAnImageAreRejected() async {
        struct TextLoader: AvatarImageLoading {
            func imageData(for url: URL) async throws -> Data { Data("<html>not found</html>".utf8) }
        }
        let store = AvatarImageStore(directory: nil, loader: TextLoader())
        #expect(await store.image(for: avatar) == nil)
    }

    @Test func initialsFallback() {
        #expect(InitialsAvatar.initial(of: "Roman Koval") == "R")
        #expect(InitialsAvatar.initial(of: "mona-dev") == "M")
        #expect(InitialsAvatar.initial(of: "") == "?")
        #expect(InitialsAvatar.paletteIndex(of: "Roman Koval") == InitialsAvatar.paletteIndex(of: "Roman Koval"))
    }

    @Test func cacheLivesUnderMergeCueHomeOrCachesNeverApplicationSupport() {
        let home = temporaryDirectory()
        let custom = AvatarImageStore.defaultDirectory(environment: [MergeCuePaths.homeEnvironmentKey: home.path(percentEncoded: false)])
        #expect(custom.path(percentEncoded: false).hasPrefix(home.path(percentEncoded: false)))
        #expect(custom.path(percentEncoded: false).hasSuffix("caches/avatars/"))
        let standard = AvatarImageStore.defaultDirectory(environment: [:]).path(percentEncoded: false)
        #expect(standard.contains("/Library/Caches/"))
        #expect(!standard.contains("Application Support"))
    }

    @Test func previewAvatarsStayInProcess() async throws {
        let model = await makeModel()
        #expect(model.mode == .preview)
        #expect(model.avatarImages === MergeCuePreview.avatarImages)
        let person = try #require(model.state.changeRequests.flatMap(\.reviewers).first?.person)
        #expect(person.avatarURL?.host() == "avatars.preview.invalid")
        // The preview loader refuses anything that isn't a synthetic preview URL.
        await #expect(throws: (any Error).self) { try await PreviewAvatarLoader().imageData(for: avatar) }
    }

    @Test func actorIsWhoTheHeadlineNames() async throws {
        let model = await makeModel()
        let item = try #require(model.state.attention(.github, number: 42, reason: .changesRequested))
        let snapshot = model.snapshot(item.changeRequest)
        let actor = try #require(Presentation.actor(item, snapshot: snapshot))
        #expect(Presentation.attentionText(item, snapshot: snapshot).headline.hasPrefix(Presentation.shortName(actor)))
        if let ci = model.state.attention.first(where: { $0.reason == .ciFailed }) {
            #expect(Presentation.actor(ci, snapshot: model.snapshot(ci.changeRequest)) == nil)
        }
    }
}
