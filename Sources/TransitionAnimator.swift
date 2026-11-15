import AppKit
import QuartzCore

enum TransitionAnimator {
    static func duration(for style: OfficialTransitionStyle) -> CFTimeInterval {
        switch style {
        case .dissolve: return 1.5
        case .horizontalWipe: return 1.9
        case .clockWipe: return 2.15
        case .circularWipe: return 2.0
        case .thoughtBubble: return 2.25
        case .sleepingDreamBubble: return 2.4
        }
    }

    static func reveal(
        incoming: CALayer,
        over outgoing: CALayer?,
        style: OfficialTransitionStyle,
        in bounds: CGRect,
        completion: @escaping () -> Void
    ) {
        guard let outgoing else {
            incoming.opacity = 0
            fade(incoming: incoming, outgoing: nil, completion: completion)
            return
        }
        switch style {
        case .dissolve: fade(incoming: incoming, outgoing: outgoing, completion: completion)
        case .horizontalWipe: maskReveal(incoming, paths: horizontalPaths(bounds), duration: duration(for: style), completion: completion)
        case .clockWipe: maskReveal(incoming, paths: clockPaths(bounds), duration: duration(for: style), completion: completion)
        case .circularWipe: maskReveal(incoming, paths: circularPaths(bounds), duration: duration(for: style), completion: completion)
        case .thoughtBubble: maskReveal(incoming, paths: bubblePaths(bounds, sleeping: false), duration: duration(for: style), completion: completion)
        case .sleepingDreamBubble: maskReveal(incoming, paths: bubblePaths(bounds, sleeping: true), duration: duration(for: style), completion: completion)
        }
    }

    static func finishReveal(_ layer: CALayer) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.mask = nil
        layer.removeAnimation(forKey: "snoopyFadeIn")
        layer.opacity = 1
        CATransaction.commit()
    }

    private static func fade(incoming: CALayer, outgoing: CALayer?, completion: @escaping () -> Void) {
        let interval = duration(for: .dissolve)
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0; fadeIn.toValue = 1; fadeIn.duration = interval
        fadeIn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = outgoing?.presentation()?.opacity ?? outgoing?.opacity ?? 1
        fadeOut.toValue = 0; fadeOut.duration = interval
        fadeOut.timingFunction = fadeIn.timingFunction
        CATransaction.begin(); CATransaction.setDisableActions(true)
        incoming.opacity = 1; outgoing?.opacity = 0
        incoming.add(fadeIn, forKey: "snoopyFadeIn"); outgoing?.add(fadeOut, forKey: "snoopyFadeOut")
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: completion)
    }

    private static func maskReveal(_ incoming: CALayer, paths: [CGPath], duration: CFTimeInterval, completion: @escaping () -> Void) {
        guard let first = paths.first, let last = paths.last else { completion(); return }
        incoming.opacity = 0
        let mask = CAShapeLayer(); mask.frame = incoming.bounds; mask.fillColor = NSColor.white.cgColor; mask.path = first
        incoming.mask = mask
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = paths; animation.keyTimes = (0..<paths.count).map { NSNumber(value: Double($0) / Double(max(1, paths.count - 1))) }
        animation.duration = duration; animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.fillMode = .both; animation.isRemovedOnCompletion = false
        // Install the first masked presentation before exposing the incoming
        // layer. A final model path set too early caused one full-frame flash.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mask.path = last
        mask.add(animation, forKey: "officialReveal")
        incoming.opacity = 1
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard incoming.mask === mask else { return }
            incoming.mask = nil; completion()
        }
    }

    private static func horizontalPaths(_ bounds: CGRect) -> [CGPath] {
        (0...12).map { step in
            let progress = CGFloat(step) / 12
            return CGPath(rect: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width * progress, height: bounds.height), transform: nil)
        }
    }

    private static func circularPaths(_ bounds: CGRect) -> [CGPath] {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = hypot(bounds.width, bounds.height) * 0.6
        return (0...14).map { step in
            let r = max(0.5, radius * CGFloat(step) / 14)
            return CGPath(ellipseIn: CGRect(x: center.x-r, y: center.y-r, width:2*r, height:2*r), transform:nil)
        }
    }

    private static func clockPaths(_ bounds: CGRect) -> [CGPath] {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = hypot(bounds.width, bounds.height)
        return (0...24).map { step in
            let end = -.pi / 2 + 2 * .pi * CGFloat(step) / 24
            let path = CGMutablePath(); path.move(to: center)
            path.addLine(to: CGPoint(x:center.x, y:center.y-radius))
            path.addArc(center:center, radius:radius, startAngle:-.pi/2, endAngle:end, clockwise:false)
            path.closeSubpath(); return path
        }
    }

    private static func bubblePaths(_ bounds: CGRect, sleeping: Bool) -> [CGPath] {
        let origin = sleeping
            ? CGPoint(x: bounds.maxX * 0.72, y: bounds.minY + bounds.height * 0.25)
            : CGPoint(x: bounds.minX + bounds.width * 0.28, y: bounds.minY + bounds.height * 0.28)
        let direction: CGFloat = sleeping ? -1 : 1
        let finalRadius = hypot(bounds.width, bounds.height)
        return (0...14).map { step in
            let progress = CGFloat(step) / 14
            let path = CGMutablePath()
            for index in 0..<4 {
                let t = min(1, max(0, progress * 1.8 - CGFloat(index) * 0.12))
                let r = (18 + CGFloat(index) * 18) * t
                let center = CGPoint(x: origin.x + direction * CGFloat(index) * bounds.width * 0.08,
                                     y: origin.y + CGFloat(index) * bounds.height * 0.09)
                path.addEllipse(in: CGRect(x:center.x-r, y:center.y-r, width:2*r, height:2*r))
            }
            if progress > 0.38 {
                let t = (progress - 0.38) / 0.62
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                let r = max(1, finalRadius * t)
                path.addEllipse(in: CGRect(x:center.x-r, y:center.y-r, width:2*r, height:2*r))
            }
            return path
        }
    }
}
