#!/usr/bin/env swift
// Draws HiveWarden's app icon: the agent mascot (as in MascotView, "working" mood)
// on a dark macOS-style rounded square. Writes a 1024×1024 PNG.
//   swift scripts/make-icon.swift assets/AppIcon.png
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "assets/AppIcon.png"
let size = 1024
let S = CGFloat(size)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
// Work in top-left coordinates, like SwiftUI.
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

// Background: Apple icon grid (824pt square, 100pt margin), dark like the panel.
let bg = CGRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = CGPath(roundedRect: bg, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(bgPath); ctx.setFillColor(rgb(0x1D1D1F)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bgPath); ctx.clip()
let grad = CGGradient(colorsSpace: cs, colors: [rgb(0x34343A), rgb(0x16161A)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: bg.minY), end: CGPoint(x: 0, y: bg.maxY), options: [])
ctx.restoreGState()

// Mascot, in MascotView units (44×56 frame), scaled up and centred.
let k: CGFloat = 12.5
let ox = (S - 44 * k) / 2
let oy = (S - 59 * k) / 2 + 6          // 56 frame + 3 shadow overhang
func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: ox + x * k, y: oy + y * k, width: w * k, height: h * k)
}
func fillRound(_ rect: CGRect, _ radius: CGFloat, _ color: CGColor) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius * k, cornerHeight: radius * k, transform: nil))
    ctx.setFillColor(color); ctx.fillPath()
}

let body = rgb(0x5B8DEF)                 // first agent colour (AgentPalette)
let ink = rgb(0x1B1B1D)

// Ground shadow
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 1.2 * k, color: rgb(0x000000, 0.55))
ctx.setFillColor(rgb(0x000000, 0.45))
ctx.fillEllipse(in: r(9, 54, 26, 5))
ctx.restoreGState()

// Legs: 5×7 showing, 11 apart, tucked under the body so only the bottom corners round.
for lx in [11.5, 27.5] as [CGFloat] {
    fillRound(r(lx, 46, 5, 9), 2, body)
    ctx.setFillColor(body); ctx.fill(r(lx, 42, 5, 8))   // square top, flush with the body's corner curve
}
// Body: 28×38, radius 6
fillRound(r(8, 10, 28, 38), 6, body)
// Soft top highlight on the body
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: r(8, 10, 28, 38), cornerWidth: 6 * k, cornerHeight: 6 * k, transform: nil))
ctx.clip()
let hl = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(hl, start: CGPoint(x: 0, y: oy + 10 * k), end: CGPoint(x: 0, y: oy + 29 * k), options: [])
ctx.restoreGState()

// Face: eyes 4.5×6.5 (8 apart), mouth 8×2 capsule 7 below.
fillRound(r(8 + 5.5, 10 + 10.25, 4.5, 6.5), 1.5, ink)
fillRound(r(8 + 18, 10 + 10.25, 4.5, 6.5), 1.5, ink)
fillRound(r(8 + 10, 10 + 23.75, 8, 2), 1, ink)

guard let img = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { exit(1) }
try FileManager.default.createDirectory(at: URL(fileURLWithPath: out).deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try png.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
