#!/usr/bin/env swift
//
// make-icons.swift — draws AppWrangler's app icon (a lasso around a gauge) and menu bar icon.
//
//   swift scripts/make-icons.swift
//
// Writes Resources/AppIcon.iconset/*.png (turned into AppIcon.icns by build.sh)
// and Resources/status_icon.png / status_icon@2x.png (a template image).
// Shapes only — no fonts or SF Symbols — so the artwork is ours to license.
//

import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")

func render(_ pixels: Int, _ draw: (CGFloat) -> Void) -> Data {
	let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
							   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
							   bytesPerRow: 0, bitsPerPixel: 0)!
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
	NSGraphicsContext.current?.imageInterpolation = .high
	draw(CGFloat(pixels))
	NSGraphicsContext.restoreGraphicsState()
	return rep.representation(using: .png, properties: [:])!
}

/// A lasso: a rope loop with a tail trailing off to the lower right.
func drawLasso(center c: CGPoint, radius r: CGFloat, lineWidth w: CGFloat, color: NSColor, twist: NSColor?) {
	let loop = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r * 0.9, width: r * 2, height: r * 1.8))
	let tail = NSBezierPath()
	let start = CGPoint(x: c.x + r * 0.62, y: c.y - r * 0.68)
	tail.move(to: start)
	tail.curve(to: CGPoint(x: c.x + r * 1.18, y: c.y - r * 1.32),
			   controlPoint1: CGPoint(x: c.x + r * 0.95, y: c.y - r * 0.85),
			   controlPoint2: CGPoint(x: c.x + r * 0.75, y: c.y - r * 1.3))
	for path in [loop, tail] {
		path.lineWidth = w
		path.lineCapStyle = .round
		color.setStroke()
		path.stroke()
		if let twist {
			// Rope texture: short diagonal dashes along the strand.
			path.lineWidth = w * 0.35
			path.setLineDash([w * 0.5, w * 0.9], count: 2, phase: 0)
			twist.setStroke()
			path.stroke()
			path.setLineDash(nil, count: 0, phase: 0)
		}
	}
	// The knot (honda) where the tail leaves the loop.
	color.setFill()
	NSBezierPath(ovalIn: CGRect(x: start.x - w * 0.9, y: start.y - w * 0.9, width: w * 1.8, height: w * 1.8)).fill()
}

/// Gauge: a 240° arc with the needle at ~30%.
func drawGauge(center c: CGPoint, radius r: CGFloat, lineWidth: CGFloat, color: NSColor, accent: NSColor) {
	let track = NSBezierPath()
	track.appendArc(withCenter: c, radius: r, startAngle: 210, endAngle: -30, clockwise: true)
	track.lineWidth = lineWidth
	track.lineCapStyle = .round
	color.withAlphaComponent(0.45).setStroke()
	track.stroke()

	let filled = NSBezierPath()
	filled.appendArc(withCenter: c, radius: r, startAngle: 210, endAngle: 138, clockwise: true)
	filled.lineWidth = lineWidth
	filled.lineCapStyle = .round
	accent.setStroke()
	filled.stroke()

	let angle = 138 * CGFloat.pi / 180
	let needle = NSBezierPath()
	needle.move(to: c)
	needle.line(to: CGPoint(x: c.x + cos(angle) * r * 0.82, y: c.y + sin(angle) * r * 0.82))
	needle.lineWidth = lineWidth * 0.9
	needle.lineCapStyle = .round
	color.setStroke()
	needle.stroke()
	color.setFill()
	NSBezierPath(ovalIn: CGRect(x: c.x - lineWidth, y: c.y - lineWidth, width: lineWidth * 2, height: lineWidth * 2)).fill()
}

func appIcon(_ s: CGFloat) {
	// macOS icon grid: 824/1024 body with soft shadow.
	let inset = s * 100 / 1024
	let body = CGRect(x: inset, y: inset * 1.1, width: s - inset * 2, height: s - inset * 2)
	let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

	NSGraphicsContext.saveGraphicsState()
	let shadow = NSShadow()
	shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
	shadow.shadowBlurRadius = s * 0.025
	shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
	shadow.set()
	NSColor.black.setFill()
	shape.fill()
	NSGraphicsContext.restoreGraphicsState()

	// Warm dusk sky — a nod to the "wrangler" theme.
	NSGradient(colors: [NSColor(red: 0.42, green: 0.16, blue: 0.10, alpha: 1),
						NSColor(red: 0.93, green: 0.55, blue: 0.20, alpha: 1)])!.draw(in: shape, angle: 75)

	let center = CGPoint(x: body.midX - body.width * 0.04, y: body.midY + body.height * 0.05)
	let r = body.width * 0.3
	let rope = NSColor(red: 0.99, green: 0.93, blue: 0.80, alpha: 1)
	drawLasso(center: center, radius: r, lineWidth: s * 0.04, color: rope,
			  twist: NSColor(red: 0.72, green: 0.48, blue: 0.27, alpha: 1))
	drawGauge(center: CGPoint(x: center.x, y: center.y - r * 0.12), radius: r * 0.55, lineWidth: s * 0.032,
			  color: .white, accent: NSColor(red: 0.45, green: 0.95, blue: 0.7, alpha: 1))
}

func statusIcon(_ s: CGFloat) {
	// Template image: black on transparent; macOS tints it for the menu bar.
	// At 18 pt only the loop, tail and a needle stay legible.
	let center = CGPoint(x: s * 0.44, y: s * 0.56)
	let r = s * 0.36
	drawLasso(center: center, radius: r, lineWidth: s * 0.09, color: .black, twist: nil)
	let angle: CGFloat = 125 * .pi / 180
	let needle = NSBezierPath()
	needle.move(to: center)
	needle.line(to: CGPoint(x: center.x + cos(angle) * r * 0.62, y: center.y + sin(angle) * r * 0.62))
	needle.lineWidth = s * 0.09
	needle.lineCapStyle = .round
	NSColor.black.setStroke()
	needle.stroke()
	NSColor.black.setFill()
	NSBezierPath(ovalIn: CGRect(x: center.x - s * 0.08, y: center.y - s * 0.08, width: s * 0.16, height: s * 0.16)).fill()
}

let iconset = resources.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
	try render(size, appIcon).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
	try render(size * 2, appIcon).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(18, statusIcon).write(to: resources.appendingPathComponent("status_icon.png"))
try render(36, statusIcon).write(to: resources.appendingPathComponent("status_icon@2x.png"))
try render(1024, appIcon).write(to: root.appendingPathComponent("docs/images/icon.png"))
print("Icons written to \(resources.path)")
