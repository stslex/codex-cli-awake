import AppKit

enum StatusIconFactory {
    static func make(assertionActive: Bool, remoteConnected: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }

            let white = NSColor.white
            let terminalFrame = NSBezierPath(
                roundedRect: NSRect(x: 1.2, y: 2.0, width: 16.2, height: 12.3),
                xRadius: 2.6,
                yRadius: 2.6
            )
            terminalFrame.lineWidth = 1.45
            if assertionActive {
                white.withAlphaComponent(0.22).setFill()
                terminalFrame.fill()
            }
            white.setStroke()
            terminalFrame.stroke()

            let prompt = NSBezierPath()
            prompt.move(to: NSPoint(x: 4.2, y: 10.5))
            prompt.line(to: NSPoint(x: 6.8, y: 8.2))
            prompt.line(to: NSPoint(x: 4.2, y: 5.9))
            prompt.lineWidth = 1.55
            prompt.lineCapStyle = .round
            prompt.lineJoinStyle = .round
            prompt.stroke()

            let cursor = NSBezierPath()
            cursor.move(to: NSPoint(x: 8.5, y: 5.9))
            cursor.line(to: NSPoint(x: 12.5, y: 5.9))
            cursor.lineWidth = 1.45
            cursor.lineCapStyle = .round
            cursor.stroke()

            let nodes = [
                NSPoint(x: 13.0, y: 14.3),
                NSPoint(x: 15.5, y: 16.4),
                NSPoint(x: 18.1, y: 14.2),
                NSPoint(x: 15.8, y: 12.1)
            ]
            let network = NSBezierPath()
            for index in nodes.indices {
                network.move(to: nodes[index])
                network.line(to: nodes[(index + 1) % nodes.count])
            }
            network.lineWidth = 1.05
            network.lineCapStyle = .round
            white.setStroke()
            network.stroke()

            for node in nodes {
                let dot = NSBezierPath(ovalIn: NSRect(x: node.x - 1.05, y: node.y - 1.05, width: 2.1, height: 2.1))
                if remoteConnected {
                    white.setFill()
                    dot.fill()
                } else {
                    dot.lineWidth = 0.95
                    white.setStroke()
                    dot.stroke()
                }
            }

            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Codex Awake"
        return image
    }
}
