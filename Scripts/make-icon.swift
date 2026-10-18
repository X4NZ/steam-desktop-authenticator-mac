#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Renders the app icon: a shield on the rounded-rect tile macOS expects.
// Run via Scripts/make-app.sh; writes a single 1024pt PNG that iconutil slices.

let size = 1024
let scale = CGFloat(size) / 1024.0

guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

context.scaleBy(x: scale, y: scale)

// Rounded-rect tile, inset to leave the standard icon margin.
let tile = CGRect(x: 90, y: 90, width: 844, height: 844)
let tilePath = CGPath(
    roundedRect: tile,
    cornerWidth: 190,
    cornerHeight: 190,
    transform: nil
)

context.saveGState()
context.addPath(tilePath)
context.clip()

let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [
        CGColor(red: 0.10, green: 0.16, blue: 0.27, alpha: 1.0),
        CGColor(red: 0.04, green: 0.07, blue: 0.13, alpha: 1.0),
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 90, y: 934),
    end: CGPoint(x: 934, y: 90),
    options: []
)
context.restoreGState()

// Shield outline.
let shield = CGMutablePath()
let cx: CGFloat = 512
let top: CGFloat = 755
let bottom: CGFloat = 275
let halfWidth: CGFloat = 185

shield.move(to: CGPoint(x: cx, y: top))
shield.addLine(to: CGPoint(x: cx - halfWidth, y: top - 95))
shield.addLine(to: CGPoint(x: cx - halfWidth, y: bottom + 185))
shield.addQuadCurve(
    to: CGPoint(x: cx, y: bottom),
    control: CGPoint(x: cx - halfWidth, y: bottom + 40)
)
shield.addQuadCurve(
    to: CGPoint(x: cx + halfWidth, y: bottom + 185),
    control: CGPoint(x: cx + halfWidth, y: bottom + 40)
)
shield.addLine(to: CGPoint(x: cx + halfWidth, y: top - 95))
shield.closeSubpath()

let shieldGradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [
        CGColor(red: 0.38, green: 0.72, blue: 0.98, alpha: 1.0),
        CGColor(red: 0.20, green: 0.48, blue: 0.86, alpha: 1.0),
    ] as CFArray,
    locations: [0, 1]
)!

context.saveGState()
context.addPath(shield)
context.clip()
context.drawLinearGradient(
    shieldGradient,
    start: CGPoint(x: cx, y: top),
    end: CGPoint(x: cx, y: bottom),
    options: []
)
context.restoreGState()

// Checkmark through the shield.
context.saveGState()
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
context.setLineWidth(58)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: cx - 88, y: 520))
context.addLine(to: CGPoint(x: cx - 18, y: 448))
context.addLine(to: CGPoint(x: cx + 105, y: 598))
context.strokePath()
context.restoreGState()

guard let image = context.makeImage() else { exit(1) }

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
let bitmap = NSBitmapImageRep(cgImage: image)
guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: output)
print("wrote \(output.path)")
