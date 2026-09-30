import Foundation
import Testing
import UIKit

@Suite struct AppIconTests {
    @MainActor @Test
    func primaryIconContainsArtwork() throws {
        let icons = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let primaryIcon = try #require(icons["CFBundlePrimaryIcon"] as? [String: Any])
        let name = try #require((primaryIcon["CFBundleIconFiles"] as? [String])?.first)
        let image = try #require(UIImage(named: name, in: .main, compatibleWith: nil)?.cgImage)
        let context = try #require(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let hasArtwork = withExtendedLifetime(context) {
            stride(from: 4, to: image.height * context.bytesPerRow, by: 4).contains { offset in
                pixels[offset] != pixels[0]
                    || pixels[offset + 1] != pixels[1]
                    || pixels[offset + 2] != pixels[2]
            }
        }
        #expect(hasArtwork, "The compiled primary icon must contain artwork, not a single-colour placeholder.")
    }
}
