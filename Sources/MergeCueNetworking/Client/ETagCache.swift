import Foundation

/// A bounded LRU cache of `ETag` + response body per URL, used for conditional GETs (`If-None-Match`).
///
/// Use one cache per account/credential (the default for `APIClient`): the key is the full request URL only.
/// Bounded both by entry count and by total body bytes; bodies larger than the byte budget are not cached.
public actor ETagCache {
    /// A cached representation.
    public struct Entry: Sendable, Hashable {
        public var etag: String
        public var body: Data
        /// Lower-cased headers of the original `200` response (e.g. `link` for pagination).
        public var headers: [String: String]

        public init(etag: String, body: Data, headers: [String: String] = [:]) {
            self.etag = etag
            self.body = body
            self.headers = HTTPHeaders.lowercased(headers)
        }
    }

    public nonisolated let capacity: Int
    public nonisolated let maxTotalBytes: Int

    private var entries: [String: (entry: Entry, tick: UInt64)] = [:]
    private var tick: UInt64 = 0
    private var totalBytes = 0

    /// - Parameters:
    ///   - capacity: Maximum number of URLs (default 512, at least 1).
    ///   - maxTotalBytes: Maximum sum of cached body sizes (default 32 MiB).
    public init(capacity: Int = 512, maxTotalBytes: Int = 32 * 1024 * 1024) {
        self.capacity = max(1, capacity)
        self.maxTotalBytes = max(0, maxTotalBytes)
    }

    /// The cached ETag and body for `url`; marks the entry as recently used.
    public func get(_ url: URL) -> (etag: String, body: Data)? {
        entry(for: url).map { ($0.etag, $0.body) }
    }

    /// The full cached entry for `url`; marks it as recently used.
    public func entry(for url: URL) -> Entry? {
        let key = Self.key(url)
        guard let stored = entries[key] else { return nil }
        tick &+= 1
        entries[key] = (stored.entry, tick)
        return stored.entry
    }

    /// Stores (or replaces) the representation for `url`, evicting least-recently-used entries as needed.
    public func set(_ url: URL, etag: String, body: Data) {
        set(url, etag: etag, body: body, headers: [:])
    }

    /// Stores (or replaces) the representation for `url` with the headers of the original response.
    public func set(_ url: URL, etag: String, body: Data, headers: [String: String]) {
        let key = Self.key(url)
        remove(key: key)
        guard !etag.isEmpty, body.count <= maxTotalBytes else { return }
        tick &+= 1
        entries[key] = (Entry(etag: etag, body: body, headers: headers), tick)
        totalBytes += body.count
        evictIfNeeded()
    }

    /// Drops the entry for `url`.
    public func remove(_ url: URL) {
        remove(key: Self.key(url))
    }

    /// Drops every entry.
    public func removeAll() {
        entries.removeAll()
        totalBytes = 0
    }

    /// Number of cached URLs.
    public var count: Int { entries.count }

    /// Sum of cached body sizes.
    public var byteCount: Int { totalBytes }

    // MARK: Internals

    private static func key(_ url: URL) -> String {
        url.absoluteString
    }

    private func remove(key: String) {
        if let old = entries.removeValue(forKey: key) {
            totalBytes -= old.entry.body.count
        }
    }

    private func evictIfNeeded() {
        while entries.count > capacity || totalBytes > maxTotalBytes {
            guard let oldest = entries.min(by: { $0.value.tick < $1.value.tick })?.key else { return }
            remove(key: oldest)
        }
    }
}
