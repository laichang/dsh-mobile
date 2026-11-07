// Writes a copy of a PNG with no alpha channel (scripts/render-icon, the default app icon).
//   swift scripts/lib/flatten-png.swift <in.png> <out.png>
// Draws the image on an opaque RGB bitmap; transparent pixels become black.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3,
      let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("usage: flatten-png.swift <in.png> <out.png>\n".data(using: .utf8)!)
    exit(1)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                          bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
guard let flat = ctx.makeImage(),
      let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dst, flat, nil)
exit(CGImageDestinationFinalize(dst) ? 0 : 1)
