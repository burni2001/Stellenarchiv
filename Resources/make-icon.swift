// Zeichnet das App-Icon (1024 px) im Stil der Bewerbungs-CD.
// Aufruf: swift Resources/make-icon.swift <ausgabe.png>
import AppKit

func c(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Koordinaten: Ursprung unten links

// macOS-Icon-Raster: 824er Fläche, 100 px Rand
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// leichter Schatten
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.28))
ctx.addPath(tilePath); ctx.setFillColor(c(0x446230)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.setFillColor(c(0x446230)); ctx.fill(tile)
// Diagonal-Keil unten rechts (forest-700)
ctx.move(to: CGPoint(x: 360, y: 100))
ctx.addLine(to: CGPoint(x: 924, y: 640))
ctx.addLine(to: CGPoint(x: 924, y: 100))
ctx.closePath()
ctx.setFillColor(c(0x33511F)); ctx.fillPath()
ctx.restoreGState()

// Weisses Blatt (A4-Proportion) mit Eselsohr
let pw: CGFloat = 400, ph: CGFloat = 520
let px: CGFloat = 512 - pw / 2, py: CGFloat = 512 - ph / 2 + 10
let fold: CGFloat = 90
let sheet = CGMutablePath()
sheet.move(to: CGPoint(x: px, y: py))
sheet.addLine(to: CGPoint(x: px + pw, y: py))
sheet.addLine(to: CGPoint(x: px + pw, y: py + ph - fold))
sheet.addLine(to: CGPoint(x: px + pw - fold, y: py + ph))
sheet.addLine(to: CGPoint(x: px, y: py + ph))
sheet.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: CGColor(gray: 0, alpha: 0.30))
ctx.addPath(sheet); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
ctx.restoreGState()
let left = px + 48
// Kopfband oben auf dem Blatt (auf Blattform beschnitten)
ctx.saveGState()
ctx.addPath(sheet); ctx.clip()
ctx.setFillColor(c(0x446230))
ctx.fill(CGRect(x: px, y: py + ph - 160, width: pw, height: 160))
ctx.restoreGState()
// Eselsohr
ctx.move(to: CGPoint(x: px + pw - fold, y: py + ph))
ctx.addLine(to: CGPoint(x: px + pw - fold, y: py + ph - fold))
ctx.addLine(to: CGPoint(x: px + pw, y: py + ph - fold))
ctx.closePath()
ctx.setFillColor(c(0xD9E2D1)); ctx.fillPath()
// Name-Balken und Pille im Kopfband
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
ctx.fill(CGRect(x: left, y: py + ph - 72, width: 200, height: 28))
let pill = CGRect(x: left, y: py + ph - 132, width: 140, height: 36)
ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 18, cornerHeight: 18, transform: nil))
ctx.setFillColor(c(0x2E4A1F)); ctx.fillPath()

// Abschnittstitel + 2pt-Linie + Textzeilen
func section(top: CGFloat, lines: [CGFloat]) {
    ctx.setFillColor(c(0x2E4A1F))
    ctx.fill(CGRect(x: left, y: top - 20, width: 130, height: 20))
    ctx.setFillColor(c(0x3B5527))
    ctx.fill(CGRect(x: left, y: top - 38, width: pw - 96, height: 7))
    var y = top - 70
    for w in lines {
        ctx.setFillColor(c(0x9CA3AF))
        ctx.fill(CGRect(x: left, y: y, width: (pw - 96) * w, height: 13))
        y -= 30
    }
}
section(top: py + ph - 200, lines: [1.0, 0.86, 0.93])
section(top: py + ph - 365, lines: [0.9, 0.7])

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
