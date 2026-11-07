import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Rasterize the native app's exported PDF without changing its page content.
let arguments = CommandLine.arguments
guard arguments.count == 3,
      let document = CGPDFDocument(URL(fileURLWithPath: arguments[1]) as CFURL),
      let page = document.page(at: 1) else {
    fatalError("Usage: swift raster-pdf.swift report.pdf page.png")
}
let bounds = page.getBoxRect(.mediaBox)
let scale: CGFloat = 2
let width = Int(ceil(bounds.width * scale))
let height = Int(ceil(bounds.height * scale))
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
context.scaleBy(x: scale, y: scale)
context.drawPDFPage(page)
let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil
)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Failed to write PDF page") }
print("Exported original PDF page at \(width) × \(height)")
