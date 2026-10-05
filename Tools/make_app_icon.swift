#!/usr/bin/env swift
// Renders FlightGlance's app icon (light and dark variants) with CoreGraphics.
// Usage: swift Tools/make_app_icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let outputDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("FlightGlance/Resources/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Quadratic Bézier point and tangent.
func bezier(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> (CGPoint, CGVector) {
    let u = 1 - t
    let point = CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x,
                        y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y)
    let tangent = CGVector(dx: 2 * u * (c.x - p0.x) + 2 * t * (p1.x - c.x),
                           dy: 2 * u * (c.y - p0.y) + 2 * t * (p1.y - c.y))
    return (point, tangent)
}

func render(dark: Bool) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let s = CGFloat(size)

    // Background gradient (CoreGraphics origin is bottom-left).
    let top = dark ? color(0x0A1A2A) : color(0x0F5C70)
    let bottom = dark ? color(0x02070D) : color(0x07243A)
    let gradient = CGGradient(colorsSpace: space, colors: [bottom, top] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: s), options: [])

    // Globe with a faint graticule.
    let center = CGPoint(x: s * 0.5, y: s * 0.47)
    let radius = s * 0.34
    let globe = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    ctx.setFillColor(dark ? color(0x0F2638) : color(0x0B3B55))
    ctx.fillEllipse(in: globe)
    ctx.saveGState()
    ctx.addEllipse(in: globe)
    ctx.clip()
    ctx.setStrokeColor(color(0xFFFFFF, 0.13))
    ctx.setLineWidth(5)
    for fraction in stride(from: -0.75, through: 0.75, by: 0.375) {
        let w = radius * CGFloat(abs(cos(fraction * .pi / 2)))
        ctx.strokeEllipse(in: CGRect(x: center.x - w, y: center.y - radius, width: w * 2, height: radius * 2))
    }
    for fraction in stride(from: -0.66, through: 0.67, by: 0.33) {
        let y = center.y + radius * CGFloat(fraction)
        ctx.move(to: CGPoint(x: center.x - radius, y: y))
        ctx.addLine(to: CGPoint(x: center.x + radius, y: y))
    }
    ctx.strokePath()
    ctx.restoreGState()
    ctx.setStrokeColor(color(0xFFFFFF, 0.22))
    ctx.setLineWidth(6)
    ctx.strokeEllipse(in: globe)

    // Great-circle reference arc (dashed) and the flown track (solid teal).
    let start = CGPoint(x: s * 0.2, y: s * 0.33)
    let end = CGPoint(x: s * 0.8, y: s * 0.42)
    let control = CGPoint(x: s * 0.5, y: s * 0.86)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0xFFFFFF, 0.55))
    ctx.setLineWidth(12)
    ctx.setLineDash(phase: 0, lengths: [26, 26])
    ctx.move(to: start)
    ctx.addQuadCurve(to: end, control: control)
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    let progress: CGFloat = 0.6
    ctx.setStrokeColor(color(0x5CCFC4))
    ctx.setLineWidth(26)
    ctx.move(to: start)
    for step in 1...60 {
        ctx.addLine(to: bezier(start, control, end, progress * CGFloat(step) / 60).0)
    }
    ctx.strokePath()

    // Airport markers.
    for (point, filled) in [(start, false), (end, true)] {
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fillEllipse(in: CGRect(x: point.x - 30, y: point.y - 30, width: 60, height: 60))
        ctx.setFillColor(dark ? color(0x0F2638) : color(0x0B3B55))
        let inner: CGFloat = filled ? 10 : 16
        ctx.fillEllipse(in: CGRect(x: point.x - inner, y: point.y - inner, width: inner * 2, height: inner * 2))
    }

    // Aircraft at the head of the track, aligned with the arc.
    let (planePoint, tangent) = bezier(start, control, end, progress)
    let upper: [CGPoint] = [
        CGPoint(x: 1.0, y: 0), CGPoint(x: 0.86, y: 0.09), CGPoint(x: 0.22, y: 0.11),
        CGPoint(x: -0.28, y: 0.92), CGPoint(x: -0.44, y: 0.92), CGPoint(x: -0.16, y: 0.11),
        CGPoint(x: -0.64, y: 0.10), CGPoint(x: -0.86, y: 0.40), CGPoint(x: -0.98, y: 0.40),
        CGPoint(x: -0.88, y: 0.05), CGPoint(x: -1.0, y: 0),
    ]
    let outline = upper + upper.dropFirst().dropLast().reversed().map { CGPoint(x: $0.x, y: -$0.y) }
    ctx.saveGState()
    ctx.translateBy(x: planePoint.x, y: planePoint.y)
    ctx.rotate(by: atan2(tangent.dy, tangent.dx))
    ctx.scaleBy(x: 120, y: 120)
    ctx.addLines(between: outline)
    ctx.closePath()
    ctx.setShadow(offset: .zero, blur: 30, color: color(0x000000, 0.45))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

for (name, dark) in [("AppIcon.png", false), ("AppIcon-Dark.png", true)] {
    let url = outputDirectory.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, render(dark: dark), nil)
    CGImageDestinationFinalize(destination)
    print("wrote \(url.path)")
}
