import AppKit
import MergeCueCore
import SwiftUI

extension EnvironmentValues {
    /// Where avatar images come from (D58). nil draws initials only: tests, demo data (its fixture URLs point at
    /// real hosts) and anything that must not touch the network. The app sets `.shared` for live data; previews
    /// and snapshots set a store with synthetic images.
    @Entry public var avatarImages: AvatarImageStore?
}

/// A person's round avatar: the provider image from `Person.avatarURL` when the store has or can get it, otherwise
/// their initial. Never blocks rendering: the initial draws first and the image fades in when it arrives.
struct PersonAvatar: View {
    var person: Person
    var size: CGFloat = 22

    var body: some View {
        RemoteAvatar(url: person.avatarURL, size: size) {
            InitialsAvatar(name: person.displayLabel, size: size)
        }
    }
}

/// An image from the avatar store clipped to a circle over `placeholder` (shown while loading or on failure).
struct RemoteAvatar<Placeholder: View>: View {
    var url: URL?
    var size: CGFloat
    @ViewBuilder var placeholder: Placeholder
    @Environment(\.avatarImages) private var store
    @State private var loaded: (url: URL, image: NSImage)?

    var body: some View {
        let image = loaded.flatMap { $0.url == url ? $0.image : nil } ?? url.flatMap { store?.cachedImage(for: $0) }
        ZStack {
            placeholder
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.textPrimary.opacity(image == nil ? 0 : 0.08), lineWidth: 0.5))
        .task(id: url) {
            guard let url, let store, store.cachedImage(for: url) == nil else { return }
            guard let image = await store.image(for: url), !Task.isCancelled else { return }
            withAnimation(Motion.hover) { loaded = (url, image) }
        }
        .accessibilityHidden(true)
    }
}

/// Initial in a muted circle, the fallback when no avatar image is available.
struct InitialsAvatar: View {
    var name: String
    var size: CGFloat = 22

    var body: some View {
        Text(Self.initial(of: name))
            .scaledFont(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
            .frame(width: size, height: size)
            .background(Circle().fill(Self.palette[Self.paletteIndex(of: name)]))
            .accessibilityHidden(true)
    }

    static let palette: [Color] = [Color(hex: 0x6B5B95), Color(hex: 0x4F6D8F), Color(hex: 0x5B7A6E), Color(hex: 0x8A6A4F), Color(hex: 0x5E6478)]

    /// First letter of the first word ("mona-dev" → "M"), "?" when there is none.
    static func initial(of name: String) -> String {
        name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
            .first?.first.map { String($0).uppercased() } ?? "?"
    }

    /// A stable colour per name.
    static func paletteIndex(of name: String) -> Int {
        name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF } % palette.count
    }
}

/// Up to `limit` overlapping avatars ("facepile"), then "+N". Each one sits on a ring of `ring` so the overlap
/// reads on any surface.
struct AvatarStack: View {
    var people: [Person]
    var size: CGFloat = 18
    var limit = 3
    var ring: Color = Theme.surface

    var body: some View {
        let shown = Array(people.prefix(limit))
        HStack(spacing: -size * 0.3) {
            ForEach(Array(shown.enumerated()), id: \.element.remoteID) { index, person in
                PersonAvatar(person: person, size: size)
                    .padding(1.5)
                    .background(Circle().fill(ring))
                    .zIndex(Double(limit - index))
            }
            if people.count > limit {
                Text("+\(people.count - limit)")
                    .scaledFont(.system(size: size * 0.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.leading, size * 0.4)
            }
        }
        .fixedSize()
        .help(people.map(\.displayLabel).joined(separator: ", "))
        .accessibilityHidden(true)
    }
}

/// A small person avatar pinned to the bottom-trailing corner of a provider badge (who acted on the item).
struct AvatarCornerBadge: ViewModifier {
    var person: Person?
    var size: CGFloat
    var ring: Color

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if let person {
                PersonAvatar(person: person, size: size)
                    .padding(1.5)
                    .background(Circle().fill(ring))
                    .offset(x: size * 0.22, y: size * 0.22)
                    .help(person.displayLabel)
            }
        }
    }
}

extension View {
    /// Pins `person`'s avatar to the bottom-trailing corner (nothing when nil).
    func avatarBadge(_ person: Person?, size: CGFloat, ring: Color = Theme.surface) -> some View {
        modifier(AvatarCornerBadge(person: person, size: size, ring: ring))
    }
}
