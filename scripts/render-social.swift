//
//  render-social.swift — the 1280×640 social preview image for GitHub and
//  link previews, rendered from the app icon and a neutral widget render.
//  Used by scripts/render-social.sh.
//  SPDX-License-Identifier: GPL-2.0-only
//

import AppKit
import SwiftUI

struct SocialCard: View {
	let icon: NSImage
	let widget: NSImage

	var body: some View {
		ZStack {
			LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.11), Color(red: 0.12, green: 0.15, blue: 0.22)],
						   startPoint: .topLeading, endPoint: .bottomTrailing)
			HStack(alignment: .center, spacing: 56) {
				VStack(alignment: .leading, spacing: 22) {
					HStack(spacing: 22) {
						Image(nsImage: icon).resizable().frame(width: 112, height: 112)
						Text("AppWrangler").font(.system(size: 68, weight: .bold, design: .rounded)).foregroundStyle(.white)
					}
					Text("Keep every app in check on your Apple Silicon Mac")
						.font(.system(size: 30, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
						.fixedSize(horizontal: false, vertical: true)
					VStack(alignment: .leading, spacing: 12) {
						bullet("wand.and.stars", "Full speed for the app you use, efficiency cores for the rest")
						bullet("snowflake", "Frees memory on 8 GB Macs by freezing apps you're not using")
						bullet("sparkles", "Free & open source · ask Claude to tune it (MCP)")
					}
					Text("github.com/IntarsO/AppWrangler")
						.font(.system(size: 22, weight: .medium, design: .monospaced)).foregroundStyle(Color(red: 0.45, green: 0.78, blue: 1))
						.padding(.top, 6)
				}
				.frame(width: 680, alignment: .leading)
				Image(nsImage: widget).resizable().aspectRatio(contentMode: .fit).frame(width: 380)
					.clipShape(RoundedRectangle(cornerRadius: 26))
					.shadow(color: .black.opacity(0.5), radius: 30, y: 12)
			}
			.padding(.horizontal, 64)
		}
		.frame(width: 1280, height: 640)
	}

	private func bullet(_ symbol: String, _ text: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 12) {
			Image(systemName: symbol).foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.75)).frame(width: 26)
			Text(text).foregroundStyle(.white.opacity(0.85))
		}
		.font(.system(size: 22))
	}
}

@main
struct RenderSocial {
	@MainActor static func main() {
		let args = CommandLine.arguments
		guard args.count == 4, let icon = NSImage(contentsOfFile: args[1]), let widget = NSImage(contentsOfFile: args[2]) else {
			print("usage: render-social <icon.png> <widget.png> <out.png>"); exit(2)
		}
		let renderer = ImageRenderer(content: SocialCard(icon: icon, widget: widget).environment(\.colorScheme, .dark))
		renderer.scale = 1
		guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
			  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(1) }
		try? png.write(to: URL(fileURLWithPath: args[3]))
		print(args[3])
	}
}
