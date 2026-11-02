import AppKit
import QuartzCore

enum ScreenLightMode: String, CaseIterable, Sendable {
    case off, dark, always

    var title: LocalizedStringResource {
        switch self {
        case .off: "Off"
        case .dark: "In the Dark"
        case .always: "Always"
        }
    }
}

/// Lighting the hand with the screen: bright strips along the left, bottom and right edges of the built-in display,
/// fading toward the middle of the screen. The top edge stays dark so the menu bar isn't flooded; clicks pass through.
/// The light uses extended dynamic range (EDR): on an XDR display the strips are brighter than regular white even when
/// the screen brightness is turned down in the dark.
@MainActor
final class ScreenLight {
    private enum Side: CaseIterable {
        case left, bottom, right
    }

    private struct Strip {
        let side: Side
        let light: CALayer
        let mask: CAGradientLayer
    }

    private var window: NSWindow?
    private var strips: [Strip] = []
    private var shownStrength: Double?
    private var shownHeadroom: CGFloat?
    private var lastCheck = ContinuousClock.now

    /// Called with every state snapshot, so without changes it does nothing.
    func update(visible: Bool, strength: Double) {
        guard visible else {
            if window?.isVisible == true { window?.orderOut(nil) }
            return
        }
        // The screen and brightness headroom change rarely, while snapshots come 30 times a second: check once a second.
        let now = ContinuousClock.now
        if window?.isVisible == true, strength == shownStrength, now - lastCheck < .seconds(1) { return }
        lastCheck = now
        guard let screen = Self.builtInScreen() else { return }
        let window = window ?? makeWindow()
        self.window = window
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: false)
            layout(in: screen.frame.size)
        }
        // Headroom above white depends on the screen brightness: the dimmer the screen, the bigger the headroom.
        let headroom = max(1, screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        if strength != shownStrength || headroom != shownHeadroom {
            shownStrength = strength
            shownHeadroom = headroom
            let color = Self.lightColor(headroom: headroom, strength: strength)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for strip in strips {
                strip.light.backgroundColor = color
            }
            CATransaction.commit()
        }
        if !window.isVisible { window.orderFrontRegardless() }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // Above regular windows, but below the mini window, the Dock and the menu bar.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let root = CALayer()
        strips = Side.allCases.map { side in
            let mask = Self.falloff(from: side)
            let light = CALayer()
            light.mask = mask
            // A color with headroom above 1 is drawn in extended range instead of being clipped to white.
            light.preferredDynamicRange = .high
            root.addSublayer(light)
            return Strip(side: side, light: light, mask: mask)
        }
        let view = NSView()
        view.layer = root
        view.wantsLayer = true
        window.contentView = view
        return window
    }

    private func layout(in size: CGSize) {
        let thickness = (size.height * 0.07).rounded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for strip in strips {
            let frame = switch strip.side {
            case .left: CGRect(x: 0, y: 0, width: thickness, height: size.height)
            case .bottom: CGRect(x: 0, y: 0, width: size.width, height: thickness)
            case .right: CGRect(x: size.width - thickness, y: 0, width: thickness, height: size.height)
            }
            strip.light.frame = frame
            strip.mask.frame = CGRect(origin: .zero, size: frame.size)
        }
        CATransaction.commit()
    }

    /// Full light at the screen edge, fading toward the middle. In macOS layers, the point (0, 0) is the bottom-left corner.
    private static func falloff(from side: Side) -> CAGradientLayer {
        let mask = CAGradientLayer()
        let opaque = CGColor(gray: 0, alpha: 1)
        mask.colors = [opaque, opaque, CGColor(gray: 0, alpha: 0)]
        mask.locations = [0, 0.3, 1]
        let (start, end): (CGPoint, CGPoint) = switch side {
        case .left: (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))
        case .bottom: (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1))
        case .right: (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))
        }
        mask.startPoint = start
        mask.endPoint = end
        return mask
    }

    /// Strength 0 gives regular white, 1 the brightest white the screen can show right now beyond regular.
    private static func lightColor(headroom: CGFloat, strength: Double) -> CGColor {
        let value = 1 + (headroom - 1) * CGFloat(strength)
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let color = CGColor(headroom: Float(value), colorSpace: space, red: value, green: value, blue: value, alpha: 1)
        else { return CGColor(gray: 1, alpha: 1) }
        return color
    }

    /// The camera sits above the built-in display: that's the one to light with, even if the main display is external.
    private static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number.map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
        } ?? NSScreen.main
    }
}
