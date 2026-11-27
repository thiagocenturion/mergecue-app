import AppKit
import Foundation
import ImageIO
import MergeCueCore

/// Fetches the bytes of an avatar image. The app uses `AvatarHTTPLoader`; tests and previews inject their own.
public nonisolated protocol AvatarImageLoading: Sendable {
    func imageData(for url: URL) async throws -> Data
}

/// Avatars of the people MergeCue shows (authors, commenters, reviewers, approvers), from the URLs the provider
/// APIs already return (`Person.avatarURL`), never from extra API calls (D58).
///
/// Lookups go memory (`NSCache` of decoded, downsampled images) → disk (`AvatarDiskCache` under Caches) → loader.
/// Concurrent requests for one URL share a single download. Only plain `https` URLs without user info are
/// fetched; anything else, a failed download or bytes that aren't an image leave the caller on its initials.
public final class AvatarImageStore {
    /// The app's store: `~/Library/Caches/<bundle id>/Avatars`, or `<MERGECUE_HOME>/caches/avatars`.
    public static let shared = AvatarImageStore(directory: defaultDirectory(), loader: AvatarHTTPLoader())

    /// How long a downloaded avatar is used before it is fetched again.
    public nonisolated static let freshFor: TimeInterval = 3 * 24 * 3600
    /// How long a stale copy stays on disk as the offline fallback.
    public nonisolated static let keepFor: TimeInterval = 14 * 24 * 3600
    /// Disk cap for all avatars together.
    public nonisolated static let maxDiskBytes = 25 * 1024 * 1024
    /// Largest single image accepted.
    public nonisolated static let maxImageBytes = 2 * 1024 * 1024
    /// Longest side of the decoded image kept in memory (3× the largest avatar drawn).
    nonisolated static let maxPixelSize = 192
    /// A URL that failed is not retried for this long (rows re-render often).
    nonisolated static let failureCooldown: TimeInterval = 10 * 60

    private let loader: any AvatarImageLoading
    private let disk: AvatarDiskCache?
    private let now: @Sendable () -> Date
    private let memory = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private var failures: [URL: Date] = [:]

    /// `directory` nil keeps avatars in memory only (previews).
    public init(directory: URL?, loader: any AvatarImageLoading, maxDiskBytes: Int = AvatarImageStore.maxDiskBytes,
                freshFor: TimeInterval = AvatarImageStore.freshFor, keepFor: TimeInterval = AvatarImageStore.keepFor,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.loader = loader
        self.now = now
        self.disk = directory.map { AvatarDiskCache(directory: $0, maxBytes: maxDiskBytes, freshFor: freshFor, keepFor: keepFor, now: now) }
        memory.countLimit = 400
    }

    /// The decoded image if it is already in memory (synchronous, for the first frame of a view).
    public func cachedImage(for url: URL) -> NSImage? {
        memory.object(forKey: url as NSURL)
    }

    /// The avatar for `url`, from memory, disk or the loader; nil when it can't be had (show initials).
    public func image(for url: URL) async -> NSImage? {
        if let image = cachedImage(for: url) { return image }
        guard Self.isAllowed(url) else { return nil }
        if let failed = failures[url], now().timeIntervalSince(failed) < Self.failureCooldown { return nil }
        if let task = inFlight[url] { return await task.value }
        // The task does the bookkeeping, so every waiter sees the same result and the entry goes exactly once.
        let task = Task { () -> NSImage? in
            let image = await self.resolve(url)
            self.inFlight[url] = nil
            if let image {
                self.memory.setObject(image, forKey: url as NSURL)
                self.failures[url] = nil
            } else {
                self.failures[url] = self.now()
            }
            return image
        }
        inFlight[url] = task
        return await task.value
    }

    /// Forgets everything held in memory (tests; the disk copy stays).
    public func clearMemory() {
        memory.removeAllObjects()
        failures.removeAll()
    }

    /// Only `https` with a host and no `user:password@` part (that would be sent as credentials).
    public nonisolated static func isAllowed(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host() ?? "").isEmpty && url.user() == nil && url.password() == nil
    }

    /// `<MERGECUE_HOME>/caches/avatars` when set, else `~/Library/Caches/<bundle id or MergeCue>/Avatars`.
    public nonisolated static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                                    fileManager: FileManager = .default) -> URL {
        if let home = environment[MergeCuePaths.homeEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            return MergeCuePaths(environment: environment, fileManager: fileManager).root
                .appending(path: "caches/avatars", directoryHint: .isDirectory)
        }
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Caches", directoryHint: .isDirectory)
        let folder = Bundle.main.bundleIdentifier ?? "MergeCue"
        return caches.appending(path: folder, directoryHint: .isDirectory).appending(path: "Avatars", directoryHint: .isDirectory)
    }

    // MARK: Resolving

    private func resolve(_ url: URL) async -> NSImage? {
        let stored = await disk?.read(url)
        if let stored, stored.isFresh, let image = await Self.decode(stored.data) {
            return image
        }
        if let data = try? await loader.imageData(for: url), data.count <= Self.maxImageBytes, let image = await Self.decode(data) {
            await disk?.write(data, for: url)
            return image
        }
        // Offline or the URL stopped working: a stale copy beats initials.
        if let stored { return await Self.decode(stored.data) }
        return nil
    }

    /// Decodes and downsamples off the main thread; nil for anything that isn't an image.
    private nonisolated static func decode(_ data: Data) async -> NSImage? {
        let decoded: (CGImage, Int, Int)? = await Task.detached(priority: .utility) {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(source) > 0 else { return nil }
            let thumbnail = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail) else { return nil }
            return (image, image.width, image.height)
        }.value
        guard let (image, width, height) = decoded else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }
}

/// Downloads avatars with a session that carries no credentials: ephemeral, no cookies, no credential storage,
/// no URL cache, `https` redirects only and every authentication challenge cancelled. Provider tokens never
/// reach it; it only sees the image URL.
public nonisolated struct AvatarHTTPLoader: AvatarImageLoading {
    public enum LoadError: Error, Sendable { case notAllowed, badResponse(Int), notAnImage, tooLarge }

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["Accept": "image/*", "User-Agent": "MergeCue"]
        session = URLSession(configuration: configuration, delegate: AvatarSessionDelegate(), delegateQueue: nil)
    }

    public func imageData(for url: URL) async throws -> Data {
        guard AvatarImageStore.isAllowed(url) else { throw LoadError.notAllowed }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LoadError.badResponse(0) }
        guard (200..<300).contains(http.statusCode) else { throw LoadError.badResponse(http.statusCode) }
        if let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(), !type.hasPrefix("image/") {
            throw LoadError.notAnImage
        }
        guard data.count <= AvatarImageStore.maxImageBytes else { throw LoadError.tooLarge }
        return data
    }
}

/// Follows only `https` redirects without user info and refuses every credential prompt.
private nonisolated final class AvatarSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, AvatarImageStore.isAllowed(url) else { return nil }
        var request = request
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        return request
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            return (.performDefaultHandling, nil)
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}
