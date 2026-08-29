import AppKit
import Foundation

enum AppIconFactory {
    static func make(size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Codex Awake"
        return image
    }

    static func writePNG(to destination: URL, pixelSize: Int) throws {
        guard pixelSize > 0 else { throw AppIconRenderingError.invalidSize }
        let size = NSSize(width: pixelSize, height: pixelSize)
        try writePNG(image: make(size: size), to: destination)
    }

    static func writePNG(image: NSImage, to destination: URL) throws {
        guard let tiffData = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiffData),
              let pngData = representation.representation(using: .png, properties: [:]) else {
            throw AppIconRenderingError.renderingFailed
        }
        try pngData.write(to: destination, options: .atomic)
    }

    private static func draw(in rect: NSRect) {
        let side = min(rect.width, rect.height)
        let origin = NSPoint(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2
        )
        let iconRect = NSRect(origin: origin, size: NSSize(width: side, height: side))
        let inset = side * 0.055
        let backgroundRect = iconRect.insetBy(dx: inset, dy: inset)
        let background = NSBezierPath(
            roundedRect: backgroundRect,
            xRadius: side * 0.22,
            yRadius: side * 0.22
        )
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.105, green: 0.14, blue: 0.18, alpha: 1),
            NSColor(calibratedRed: 0.025, green: 0.035, blue: 0.055, alpha: 1)
        ])
        gradient?.draw(in: background, angle: -68)

        NSGraphicsContext.saveGraphicsState()
        background.addClip()
        let glow = NSBezierPath(
            ovalIn: NSRect(
                x: iconRect.minX + side * 0.45,
                y: iconRect.minY + side * 0.46,
                width: side * 0.52,
                height: side * 0.52
            )
        )
        NSColor(calibratedRed: 0.14, green: 0.76, blue: 0.67, alpha: 0.11).setFill()
        glow.fill()
        NSGraphicsContext.restoreGraphicsState()

        let terminalRect = NSRect(
            x: iconRect.minX + side * 0.15,
            y: iconRect.minY + side * 0.17,
            width: side * 0.70,
            height: side * 0.62
        )
        let terminal = NSBezierPath(
            roundedRect: terminalRect,
            xRadius: side * 0.09,
            yRadius: side * 0.09
        )
        NSColor.white.withAlphaComponent(0.045).setFill()
        terminal.fill()
        NSColor.white.withAlphaComponent(0.91).setStroke()
        terminal.lineWidth = side * 0.025
        terminal.stroke()

        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: terminalRect.minX, y: terminalRect.maxY - side * 0.14))
        divider.line(to: NSPoint(x: terminalRect.maxX, y: terminalRect.maxY - side * 0.14))
        divider.lineWidth = side * 0.015
        divider.stroke()

        NSColor.white.withAlphaComponent(0.58).setFill()
        for index in 0..<3 {
            let dot = NSBezierPath(
                ovalIn: NSRect(
                    x: terminalRect.minX + side * (0.07 + CGFloat(index) * 0.055),
                    y: terminalRect.maxY - side * 0.09,
                    width: side * 0.025,
                    height: side * 0.025
                )
            )
            dot.fill()
        }

        let prompt = NSBezierPath()
        prompt.move(to: NSPoint(x: iconRect.minX + side * 0.24, y: iconRect.minY + side * 0.50))
        prompt.line(to: NSPoint(x: iconRect.minX + side * 0.315, y: iconRect.minY + side * 0.43))
        prompt.line(to: NSPoint(x: iconRect.minX + side * 0.24, y: iconRect.minY + side * 0.36))
        prompt.lineWidth = side * 0.031
        prompt.lineCapStyle = .round
        prompt.lineJoinStyle = .round
        prompt.stroke()

        let cursor = NSBezierPath()
        cursor.move(to: NSPoint(x: iconRect.minX + side * 0.37, y: iconRect.minY + side * 0.36))
        cursor.line(to: NSPoint(x: iconRect.minX + side * 0.52, y: iconRect.minY + side * 0.36))
        cursor.lineWidth = side * 0.031
        cursor.lineCapStyle = .round
        cursor.stroke()

        let cloudCenter = NSPoint(
            x: iconRect.minX + side * 0.705,
            y: iconRect.minY + side * 0.685
        )
        BrandMarkDrawing.drawCloud(
            center: cloudCenter,
            width: side * 0.245,
            height: side * 0.165,
            color: .white,
            shadowColor: NSColor(calibratedRed: 0.035, green: 0.05, blue: 0.07, alpha: 0.78)
        )
    }
}

enum BrandMarkDrawing {
    static func drawCloud(
        center: NSPoint,
        width: CGFloat,
        height: CGFloat,
        color: NSColor,
        shadowColor: NSColor?
    ) {
        if let shadowColor {
            drawCloudShapes(
                center: NSPoint(x: center.x, y: center.y - height * 0.035),
                width: width * 1.08,
                height: height * 1.08,
                color: shadowColor
            )
        }
        drawCloudShapes(center: center, width: width, height: height, color: color)
    }

    private static func drawCloudShapes(
        center: NSPoint,
        width: CGFloat,
        height: CGFloat,
        color: NSColor
    ) {
        color.setFill()

        let base = NSBezierPath(
            roundedRect: NSRect(
                x: center.x - width * 0.48,
                y: center.y - height * 0.42,
                width: width * 0.96,
                height: height * 0.55
            ),
            xRadius: height * 0.26,
            yRadius: height * 0.26
        )
        base.fill()

        let lobes: [(x: CGFloat, y: CGFloat, diameter: CGFloat)] = [
            (-0.27, -0.01, 0.54),
            (-0.02, 0.16, 0.76),
            (0.28, 0.01, 0.57)
        ]
        for lobe in lobes {
            let diameter = height * lobe.diameter
            NSBezierPath(
                ovalIn: NSRect(
                    x: center.x + width * lobe.x - diameter / 2,
                    y: center.y + height * lobe.y - diameter / 2,
                    width: diameter,
                    height: diameter
                )
            ).fill()
        }
    }
}

private enum AppIconRenderingError: LocalizedError {
    case invalidSize
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .invalidSize:
            return "The requested icon size is invalid."
        case .renderingFailed:
            return "The application icon could not be rendered as PNG."
        }
    }
}
