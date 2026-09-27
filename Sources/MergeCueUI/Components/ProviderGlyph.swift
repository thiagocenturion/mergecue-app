import MergeCueCore
import SwiftUI

/// A small, original provider tag: shape + color + monogram differ per provider, so `acme/payments-api #42` on
/// GitHub, GitLab and Bitbucket stays distinguishable even in grayscale. No trademarked logos are used.
struct ProviderGlyph: View {
    var kind: ProviderKind
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            shape
                .fill(Self.color(kind).gradient)
            Text(Self.monogram(kind))
                .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .tracking(-0.3)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.displayName)
    }

    private var shape: AnyShape {
        switch kind {
        case .github: AnyShape(Circle())
        case .gitlab: AnyShape(Hexagon())
        case .bitbucketCloud: AnyShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        }
    }

    static func monogram(_ kind: ProviderKind) -> String {
        switch kind {
        case .github: "GH"
        case .gitlab: "GL"
        case .bitbucketCloud: "BB"
        }
    }

    static func color(_ kind: ProviderKind) -> Color {
        switch kind {
        case .github: Theme.adaptive(light: 0x24292F, dark: 0x6E7781)
        case .gitlab: Theme.adaptive(light: 0xE24329, dark: 0xFC6D26)
        case .bitbucketCloud: Theme.adaptive(light: 0x0C66E4, dark: 0x388BFF)
        }
    }
}

/// Pointy-top hexagon.
struct Hexagon: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.93, y: rect.minY + h * 0.25))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.93, y: rect.minY + h * 0.75))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.07, y: rect.minY + h * 0.75))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.07, y: rect.minY + h * 0.25))
        path.closeSubpath()
        return path
    }
}

/// Provider glyph + "namespace/repo #42" in one line.
struct ChangeRequestRefLabel: View {
    var kind: ProviderKind
    var repoFullPath: String
    var number: Int
    var font: Font = .subheadline
    var glyphSize: CGFloat = 14

    var body: some View {
        HStack(spacing: 5) {
            ProviderGlyph(kind: kind, size: glyphSize)
            Text("\(Text(repoFullPath).foregroundStyle(.secondary)) \(Text(kind.formattedNumber(number)).fontWeight(.semibold))")
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.displayName) \(kind.changeRequestNoun) \(repoFullPath) number \(number)")
    }
}
