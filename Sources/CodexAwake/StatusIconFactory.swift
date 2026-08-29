import AppKit

enum StatusIconFactory {
    static func make(assertionActive: Bool, remoteConnected: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }

            let white = NSColor.white
            let terminalFrame = NSBezierPath(
                roundedRect: NSRect(x: 1.15, y: 2.0, width: 15.7, height: 12.1),
                xRadius: 2.45,
                yRadius: 2.45
            )
            terminalFrame.lineWidth = 1.35
            if assertionActive {
                white.withAlphaComponent(0.22).setFill()
                terminalFrame.fill()
            }
            white.setStroke()
            terminalFrame.stroke()

            let prompt = NSBezierPath()
            prompt.move(to: NSPoint(x: 4.0, y: 10.3))
            prompt.line(to: NSPoint(x: 6.5, y: 8.1))
            prompt.line(to: NSPoint(x: 4.0, y: 5.9))
            prompt.lineWidth = 1.5
            prompt.lineCapStyle = .round
            prompt.lineJoinStyle = .round
            prompt.stroke()

            let cursor = NSBezierPath()
            cursor.move(to: NSPoint(x: 8.1, y: 5.9))
            cursor.line(to: NSPoint(x: 11.6, y: 5.9))
            cursor.lineWidth = 1.4
            cursor.lineCapStyle = .round
            cursor.stroke()

            BrandMarkDrawing.drawCloud(
                center: NSPoint(x: 15.6, y: 14.15),
                width: 5.9,
                height: 4.0,
                color: white.withAlphaComponent(remoteConnected ? 1.0 : 0.55),
                shadowColor: nil
            )

            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Codex Awake"
        return image
    }

    static func writePreviewPNG(
        to destination: URL,
        assertionActive: Bool,
        remoteConnected: Bool
    ) throws {
        let previewSize = NSSize(width: 400, height: 360)
        let preview = NSImage(size: previewSize, flipped: false) { rect in
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            rect.fill()
            make(
                assertionActive: assertionActive,
                remoteConnected: remoteConnected
            ).draw(
                in: rect.insetBy(dx: 20, dy: 18),
                from: NSRect(x: 0, y: 0, width: 20, height: 18),
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        try AppIconFactory.writePNG(image: preview, to: destination)
    }
}
