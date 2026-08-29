import AppKit
import XCTest
@testable import CodexAwake

final class AppIconFactoryTests: XCTestCase {
    func testApplicationIconRendersAtRequestedSize() {
        let image = AppIconFactory.make(size: NSSize(width: 256, height: 256))

        XCTAssertEqual(image.size, NSSize(width: 256, height: 256))
        XCTAssertFalse(image.isTemplate)
        XCTAssertNotNil(image.tiffRepresentation)
    }

    func testApplicationIconWritesPixelSizedPNG() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAwakeIcon-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: destination) }

        try AppIconFactory.writePNG(to: destination, pixelSize: 128)

        let data = try Data(contentsOf: destination)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(representation.pixelsWide, 128)
        XCTAssertEqual(representation.pixelsHigh, 128)
    }

    func testStatusIconUsesTheMenuBarCanvas() {
        let image = StatusIconFactory.make(assertionActive: true, remoteConnected: true)

        XCTAssertEqual(image.size, NSSize(width: 20, height: 18))
        XCTAssertFalse(image.isTemplate)
        XCTAssertNotNil(image.tiffRepresentation)
    }
}
