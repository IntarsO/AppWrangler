//
//  render-widget.swift — render the widget's views to PNGs, for checking the
//  layout without adding it to the desktop. Used by scripts/render-widget.sh.
//  SPDX-License-Identifier: GPL-2.0-only
//

import SwiftUI

@main
struct RenderWidget {
	@MainActor static func main() {
		let out = CommandLine.arguments.dropFirst().first ?? "."
		let snapshot = WidgetSnapshot.read() ?? .sample
		func render<V: View>(_ view: V, _ size: CGSize, _ name: String, dark: Bool) {
			let content = view
				.padding(14)
				.frame(width: size.width, height: size.height)
				.background(dark ? Color(white: 0.17) : Color(white: 0.95))
				.environment(\.colorScheme, dark ? .dark : .light)
			let renderer = ImageRenderer(content: content)
			renderer.scale = 2
			guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
				  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
			try? png.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
		}
		for dark in [false, true] {
			let suffix = dark ? "-dark" : ""
			render(SmallView(s: snapshot), CGSize(width: 170, height: 170), "widget-small\(suffix).png", dark: dark)
			render(MediumView(s: snapshot), CGSize(width: 364, height: 170), "widget-medium\(suffix).png", dark: dark)
			render(LargeView(s: snapshot), CGSize(width: 364, height: 382), "widget-large\(suffix).png", dark: dark)
		}
		render(NotRunning(), CGSize(width: 170, height: 170), "widget-not-running.png", dark: false)
	}
}
