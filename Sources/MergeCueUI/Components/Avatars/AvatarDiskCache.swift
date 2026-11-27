import CryptoKit
import Foundation

/// Avatar image bytes on disk, one file per URL (`<sha256 of the URL>.avatar`), bounded by size and age (D58).
/// Entries younger than `freshFor` are used as is; older ones are refreshed but still serve as the offline copy
/// until they pass `keepFor` or the size cap evicts them (least recently written first).
actor AvatarDiskCache {
    nonisolated struct Entry: Sendable {
        var data: Data
        var isFresh: Bool
    }

    let directory: URL
    let maxBytes: Int
    let freshFor: TimeInterval
    let keepFor: TimeInterval
    private let now: @Sendable () -> Date
    private let fileManager = FileManager()
    /// Bytes on disk, measured on the first write and kept up to date after that.
    private var knownSize: Int?

    init(directory: URL, maxBytes: Int, freshFor: TimeInterval, keepFor: TimeInterval, now: @escaping @Sendable () -> Date) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.freshFor = freshFor
        self.keepFor = max(keepFor, freshFor)
        self.now = now
    }

    /// The stored bytes for `url`, nil when missing or past `keepFor` (then the file is removed).
    func read(_ url: URL) -> Entry? {
        let file = fileURL(for: url)
        guard let modified = modificationDate(file) else { return nil }
        let age = now().timeIntervalSince(modified)
        if age > keepFor {
            remove(file)
            return nil
        }
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        return Entry(data: data, isFresh: age <= freshFor)
    }

    /// Stores `data` for `url` (0600 file in a 0700 directory) and evicts the oldest entries over the size cap.
    func write(_ data: Data, for url: URL) {
        guard !data.isEmpty, data.count <= maxBytes else { return }
        do {
            try ensureDirectory()
            let file = fileURL(for: url)
            let previous = fileSize(file)
            try data.write(to: file, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600, .modificationDate: now()], ofItemAtPath: file.path(percentEncoded: false))
            let size = knownSize ?? measure()
            knownSize = size - previous + data.count
            if let knownSize, knownSize > maxBytes { evict() }
        } catch {
            // A cache that can't write just keeps working from memory and the network.
        }
    }

    /// Total bytes of cached files.
    func totalSize() -> Int { measure() }

    /// `<directory>/<sha256 hex of the absolute URL>.avatar`.
    nonisolated func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).avatar", directoryHint: .notDirectory)
    }

    // MARK: Internals

    private func ensureDirectory() throws {
        let path = directory.path(percentEncoded: false)
        if !fileManager.fileExists(atPath: path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    private func entries() -> [(url: URL, size: Int, modified: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension == "avatar" }.compactMap { file in
            let values = try? file.resourceValues(forKeys: Set(keys))
            return (file, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }
    }

    private func measure() -> Int { entries().reduce(0) { $0 + $1.size } }

    /// Removes expired files, then the oldest until the cache is at 80 % of its cap.
    private func evict() {
        var all = entries().sorted { $0.modified < $1.modified }
        let cutoff = now().addingTimeInterval(-keepFor)
        var total = all.reduce(0) { $0 + $1.size }
        let target = maxBytes * 8 / 10
        while let oldest = all.first, oldest.modified < cutoff || total > target {
            remove(oldest.url)
            total -= oldest.size
            all.removeFirst()
        }
        knownSize = total
    }

    private func modificationDate(_ file: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: file.path(percentEncoded: false)))?[.modificationDate] as? Date
    }

    private func fileSize(_ file: URL) -> Int {
        ((try? fileManager.attributesOfItem(atPath: file.path(percentEncoded: false)))?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func remove(_ file: URL) {
        try? fileManager.removeItem(at: file)
    }
}
