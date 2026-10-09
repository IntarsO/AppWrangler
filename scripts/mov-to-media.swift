//
//  mov-to-media.swift — turn a screen recording into an MP4 (H.264) and a GIF,
//  with Apple's frameworks only (no ffmpeg). Used by scripts/record-demo.sh.
//    mov-to-media <in.mov> <out.mp4> <out.gif> [width=900] [fps=10] [start=0] [end=0 (=all)]
//  SPDX-License-Identifier: GPL-2.0-only
//

import AVFoundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: mov-to-media <in.mov> <out.mp4> <out.gif> [width] [fps] [start] [end]"); exit(2) }
let input = URL(fileURLWithPath: args[1]), mp4 = URL(fileURLWithPath: args[2]), gif = URL(fileURLWithPath: args[3])
let width = args.count > 4 ? Double(args[4]) ?? 900 : 900
let fps = args.count > 5 ? Double(args[5]) ?? 10 : 10
let start = args.count > 6 ? Double(args[6]) ?? 0 : 0
let asset = AVURLAsset(url: input)
let duration = CMTimeGetSeconds(asset.duration)
let end = args.count > 7 && (Double(args[7]) ?? 0) > 0 ? min(Double(args[7])!, duration) : duration
let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))

// MP4
try? FileManager.default.removeItem(at: mp4)
if let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) {
	export.outputURL = mp4
	export.outputFileType = .mp4
	export.timeRange = range
	export.shouldOptimizeForNetworkUse = true
	let done = DispatchSemaphore(value: 0)
	export.exportAsynchronously { done.signal() }
	done.wait()
	print(export.status == .completed ? "MP4: \(mp4.path)" : "MP4 failed: \(export.error?.localizedDescription ?? "?")")
}

// GIF: sample frames at `fps`, scaled to `width`, skipping frames identical to the previous one.
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
generator.maximumSize = CGSize(width: width, height: 10_000)
var frames: [(CGImage, Double)] = []
var t = start
var lastData: Data?
while t < end {
	if let image = try? generator.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
		let data = image.dataProvider?.data as Data?
		if let data, data == lastData, !frames.isEmpty {
			frames[frames.count - 1].1 += 1 / fps	// hold the previous frame longer
		} else {
			frames.append((image, 1 / fps))
			lastData = data
		}
	}
	t += 1 / fps
}
guard let dest = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { exit(1) }
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for (image, delay) in frames {
	CGImageDestinationAddImage(dest, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
																			  kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
}
CGImageDestinationFinalize(dest)
let size = (try? FileManager.default.attributesOfItem(atPath: gif.path)[.size] as? Int) ?? 0
print(String(format: "GIF: %@ (%d frames, %.1f MB)", gif.path, frames.count, Double(size) / 1_048_576))
