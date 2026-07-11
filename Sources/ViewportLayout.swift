import Foundation
import QuartzCore

enum ViewportLayout {
    static let designSize = CGSize(width: 1920, height: 1080)

    /// Aspect-fit the official 16:9 coordinate space. Palette layers fill the
    /// host outside this rect, so non-16:9 displays never stretch or crop art.
    static func viewport(in host: CGRect) -> CGRect {
        guard host.width > 0, host.height > 0 else { return .zero }
        let scale = min(host.width / designSize.width, host.height / designSize.height)
        let size = CGSize(width: designSize.width * scale, height: designSize.height * scale)
        return CGRect(x: host.midX - size.width / 2, y: host.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func spriteFrame(
        _ sprite: SpriteDescriptor,
        in host: CGRect,
        sceneOffset: CGPoint = .zero
    ) -> CGRect {
        let viewport = viewport(in: host)
        let scale = viewport.width / designSize.width
        let size = CGSize(width: sprite.assetSize.width * scale, height: sprite.assetSize.height * scale)
        let origin: CGPoint
        switch sprite.alignment {
        case "bottom":
            origin = CGPoint(x: viewport.midX - size.width / 2, y: viewport.minY)
        case "top":
            origin = CGPoint(x: viewport.midX - size.width / 2, y: viewport.maxY - size.height)
        case "left":
            origin = CGPoint(x: viewport.minX, y: viewport.midY - size.height / 2)
        case "right":
            origin = CGPoint(x: viewport.maxX - size.width, y: viewport.midY - size.height / 2)
        default:
            origin = CGPoint(x: viewport.midX - size.width / 2, y: viewport.midY - size.height / 2)
        }
        return CGRect(x: origin.x + sceneOffset.x * scale, y: origin.y + sceneOffset.y * scale,
                      width: size.width, height: size.height)
    }
}
