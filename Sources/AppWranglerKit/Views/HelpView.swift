//
//  HelpView.swift
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  In-app Help: the User Manual, Getting Started, CLI, MCP and FAQ pages
//  bundled with the app (the same Markdown files as on GitHub, so they never
//  drift apart), searchable, and opened at the right section by the "?"
//  buttons around the app. Works offline.
//

import AppKit
import SwiftUI
import WebKit

enum HelpTopic: String, CaseIterable, Identifiable {
	case gettingStarted = "getting-started"
	case manual = "user-manual"
	case assistants = "mcp"
	case cli
	case faq
	case howItWorks = "how-it-works"

	var id: String { rawValue }
	var file: String { rawValue + ".md" }

	var title: String {
		switch self {
		case .gettingStarted: return L("Getting Started")
		case .manual: return L("User Manual")
		case .assistants: return L("AI Assistants (MCP)")
		case .cli: return L("Command Line")
		case .faq: return L("FAQ")
		case .howItWorks: return L("How It Works")
		}
	}

	var symbol: String {
		switch self {
		case .gettingStarted: return "flag.checkered"
		case .manual: return "book"
		case .assistants: return "sparkles"
		case .cli: return "terminal"
		case .faq: return "questionmark.bubble"
		case .howItWorks: return "gearshape.2"
		}
	}

	static func forFile(_ name: String) -> HelpTopic? {
		allCases.first { $0.file == name }
	}
}

/// The bundled documentation.
enum HelpLibrary {
	/// `Contents/Resources/Help` in the app; the repository's `docs/` folder when run from a build directory.
	static let directory: URL? = {
		let fm = FileManager.default
		if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Help"),
		   fm.fileExists(atPath: bundled.appendingPathComponent(HelpTopic.manual.file).path) {
			return bundled
		}
		let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
			.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs")
		return fm.fileExists(atPath: repo.appendingPathComponent(HelpTopic.manual.file).path) ? repo : nil
	}()

	private static var cache: [HelpTopic: String] = [:]

	static func markdown(_ topic: HelpTopic) -> String {
		if let cached = cache[topic] { return cached }
		let text = directory.flatMap { try? String(contentsOf: $0.appendingPathComponent(topic.file), encoding: .utf8) }
			?? "# \(topic.title)\n\n" + L("This page isn't included in this build. Read it online:") + " [GitHub](\(Links.repository.absoluteString)/blob/main/docs/\(topic.file))"
		cache[topic] = text
		return text
	}

	struct Hit: Identifiable, Hashable {
		var id: String { topic.rawValue + "#" + anchor }
		let topic: HelpTopic
		let title: String
		let anchor: String
		let snippet: String
	}

	/// Sections containing every word of `query`, headings first.
	static func search(_ query: String) -> [Hit] {
		let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
		guard !words.isEmpty else { return [] }
		var scored: [(Int, Hit)] = []
		for topic in HelpTopic.allCases {
			for section in Markdown.sections(markdown(topic)) {
				let title = section.title.lowercased()
				let body = section.text.lowercased()
				guard words.allSatisfy({ title.contains($0) || body.contains($0) }) else { continue }
				let score = words.filter { title.contains($0) }.count * 10 - section.level
				scored.append((score, Hit(topic: topic, title: section.title, anchor: section.anchor,
										  snippet: snippet(section.text, around: words.first!))))
			}
		}
		return scored.sorted { $0.0 > $1.0 }.prefix(60).map(\.1)
	}

	private static func snippet(_ text: String, around word: String) -> String {
		let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: " ")
			.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
		guard let r = flat.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else { return String(flat.prefix(110)) }
		let start = flat.index(r.lowerBound, offsetBy: -40, limitedBy: flat.startIndex) ?? flat.startIndex
		let end = flat.index(r.upperBound, offsetBy: 70, limitedBy: flat.endIndex) ?? flat.endIndex
		return (start > flat.startIndex ? "…" : "") + flat[start..<end].trimmingCharacters(in: .whitespaces) + (end < flat.endIndex ? "…" : "")
	}

	static func page(_ topic: HelpTopic) -> String {
		"""
		<!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
		<style>\(css)</style></head><body><article>
		\(Markdown.html(markdown(topic)))
		</article></body></html>
		"""
	}

	static let css = """
	:root { color-scheme: light dark; --fg:#1d1d1f; --muted:#6e6e73; --bg:#ffffff; --code:#f2f2f5; --line:#d9d9de; --link:#0a64d6; --quote:#f6f6f8; }
	@media (prefers-color-scheme: dark) { :root { --fg:#e8e8ed; --muted:#9a9aa0; --bg:#1e1e20; --code:#2c2c2f; --line:#3a3a3e; --link:#5aa7ff; --quote:#262629; } }
	html { background: var(--bg); }
	body { font: 14px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: var(--fg); background: var(--bg); margin: 0; }
	article { max-width: 780px; margin: 0 auto; padding: 18px 28px 60px; }
	h1 { font-size: 26px; margin: 8px 0 14px; } h2 { font-size: 20px; margin-top: 30px; padding-top: 6px; }
	h3 { font-size: 16px; margin-top: 22px; } h4 { font-size: 14px; }
	h1, h2, h3, h4 { scroll-margin-top: 12px; line-height: 1.25; }
	a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
	code { font: 12.5px ui-monospace, "SF Mono", Menlo, monospace; background: var(--code); padding: 1px 5px; border-radius: 4px; }
	pre { background: var(--code); padding: 10px 12px; border-radius: 8px; overflow-x: auto; }
	pre code { padding: 0; background: none; }
	table { border-collapse: collapse; margin: 12px 0; width: 100%; font-size: 13px; }
	th, td { border: 1px solid var(--line); padding: 6px 9px; text-align: left; vertical-align: top; overflow-wrap: anywhere; }
	td code { white-space: normal; }
	th { background: var(--code); }
	blockquote { margin: 12px 0; padding: 4px 14px; background: var(--quote); border-left: 3px solid var(--link); border-radius: 4px; }
	hr { border: none; border-top: 1px solid var(--line); margin: 26px 0; }
	ul, ol { padding-left: 22px; } li { margin: 3px 0; }
	img { max-width: 100%; }
	.flash { animation: flash 1.6s ease-out; border-radius: 4px; }
	@keyframes flash { from { background: rgba(255, 204, 0, .45); } to { background: transparent; } }
	"""
}

final class HelpState: ObservableObject {
	@Published var topic: HelpTopic = .manual
	@Published var anchor: String?
	/// Bumped on every request, so asking for the same section again scrolls again.
	@Published var request = 0
	@Published var query = ""

	func show(_ topic: HelpTopic, anchor: String?) {
		self.topic = topic
		self.anchor = anchor
		request += 1
	}
}

/// Opens the Help window from anywhere in the app.
enum HelpCenter {
	private(set) static var window: NSWindow?
	static let state = HelpState()

	static func open(_ topic: HelpTopic = .manual, anchor: String? = nil) {
		state.show(topic, anchor: anchor)
		if window == nil {
			let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
							 styleMask: [.titled, .closable, .miniaturizable, .resizable],
							 backing: .buffered, defer: false)
			w.title = L("AppWrangler Help")
			w.isReleasedWhenClosed = false
			w.contentViewController = NSHostingController(rootView: HelpView(state: state))
			w.setContentSize(NSSize(width: 980, height: 680))
			w.center()
			w.setFrameAutosaveName("AppWranglerHelp")
			window = w
		}
		#if DEBUG
		if UserDefaults.standard.string(forKey: "AWDebugSnapshotDir") != nil {
			window?.orderFront(nil)	// snapshots: don't take keyboard focus
			return
		}
		#endif
		NSApp.activate(ignoringOtherApps: true)
		window?.makeKeyAndOrderFront(nil)
	}
}

/// A small "?" button that opens the manual at a section.
struct HelpButton: View {
	var topic: HelpTopic = .manual
	var anchor: String?

	var body: some View {
		Button {
			HelpCenter.open(topic, anchor: anchor)
		} label: {
			Image(systemName: "questionmark.circle")
		}
		.buttonStyle(.borderless)
		.foregroundColor(.secondary)
		.help(L("Open Help for this"))
		.accessibilityLabel(L("Help"))
	}
}

struct HelpView: View {
	@ObservedObject var state: HelpState

	var body: some View {
		HStack(spacing: 0) {
			sidebar
				.frame(width: 250)
			Divider()
			HelpWebView(state: state)
		}
		.frame(minWidth: 720, minHeight: 460)
	}

	private var hits: [HelpLibrary.Hit] { HelpLibrary.search(state.query) }

	private var sidebar: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 6) {
				Image(systemName: "magnifyingglass").foregroundColor(.secondary)
				TextField(L("Search help"), text: $state.query)
					.textFieldStyle(.plain)
				if !state.query.isEmpty {
					Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill") }
						.buttonStyle(.borderless).foregroundColor(.secondary)
				}
			}
			.padding(7)
			.background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
			.padding([.horizontal, .top], 10)

			if state.query.trimmingCharacters(in: .whitespaces).isEmpty {
				List {
					ForEach(HelpTopic.allCases) { topic in
						Button {
							state.show(topic, anchor: nil)
						} label: {
							Label(topic.title, systemImage: topic.symbol)
								.frame(maxWidth: .infinity, alignment: .leading)
								.contentShape(Rectangle())
						}
						.buttonStyle(.plain)
						.padding(.vertical, 3)
						.listRowBackground(state.topic == topic ? Color.accentColor.opacity(0.18) : Color.clear)
					}
				}
				.listStyle(.sidebar)
			} else if hits.isEmpty {
				Text(L("No results"))
					.foregroundColor(.secondary)
					.padding(14)
				Spacer()
			} else {
				List {
					ForEach(hits) { hit in
						Button {
							state.show(hit.topic, anchor: hit.anchor)
						} label: {
							VStack(alignment: .leading, spacing: 2) {
								Text(hit.title).font(.system(size: 12.5, weight: .semibold))
								Text(hit.topic.title).font(.system(size: 10.5)).foregroundColor(.accentColor)
								Text(hit.snippet).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(3)
							}
							.frame(maxWidth: .infinity, alignment: .leading)
							.contentShape(Rectangle())
						}
						.buttonStyle(.plain)
						.padding(.vertical, 3)
					}
				}
				.listStyle(.sidebar)
			}

			Divider()
			Link(L("Read online on GitHub"), destination: URL(string: Links.repository.absoluteString + "/blob/main/docs/" + state.topic.file)!)
				.font(.system(size: 11))
				.padding([.horizontal, .bottom], 10)
		}
	}
}

struct HelpWebView: NSViewRepresentable {
	@ObservedObject var state: HelpState

	func makeCoordinator() -> Coordinator { Coordinator(state: state) }

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.websiteDataStore = .nonPersistent()
		let view = WKWebView(frame: .zero, configuration: config)
		view.navigationDelegate = context.coordinator
		view.setValue(false, forKey: "drawsBackground")
		return view
	}

	func updateNSView(_ view: WKWebView, context: Context) {
		context.coordinator.sync(view)
	}

	final class Coordinator: NSObject, WKNavigationDelegate {
		let state: HelpState
		private var loadedTopic: HelpTopic?
		private var handledRequest = -1
		private var loading = false

		init(state: HelpState) { self.state = state }

		func sync(_ view: WKWebView) {
			guard handledRequest != state.request || loadedTopic != state.topic else { return }
			handledRequest = state.request
			if loadedTopic != state.topic {
				loadedTopic = state.topic
				loading = true
				view.loadHTMLString(HelpLibrary.page(state.topic), baseURL: HelpLibrary.directory)
			} else if !loading {
				scroll(view)
			}
		}

		private func scroll(_ view: WKWebView) {
			guard let anchor = state.anchor, !anchor.isEmpty else {
				view.evaluateJavaScript("window.scrollTo(0, 0)")
				return
			}
			let id = anchor.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "'", with: "")
			view.evaluateJavaScript("""
			(function(){ var e = document.getElementById('\(id)'); if (!e) return;
			  e.scrollIntoView({block: 'start'}); e.classList.remove('flash'); void e.offsetWidth; e.classList.add('flash'); })()
			""")
		}

		func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
			loading = false
			scroll(view)
		}

		func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
					 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
			guard action.navigationType == .linkActivated, let url = action.request.url else {
				decisionHandler(.allow)
				return
			}
			if url.isFileURL {
				let name = url.lastPathComponent
				if let topic = HelpTopic.forFile(name) {
					decisionHandler(.cancel)
					DispatchQueue.main.async { self.state.show(topic, anchor: url.fragment) }
					return
				}
				if let dir = HelpLibrary.directory, url.path == dir.path || url.path == dir.path + "/" || name.isEmpty {
					// Same page: "#section".
					decisionHandler(.cancel)
					DispatchQueue.main.async { self.state.show(self.state.topic, anchor: url.fragment) }
					return
				}
				// Another file in the repository (README, CHANGELOG…): open it on GitHub.
				decisionHandler(.cancel)
				let inDocs = HelpLibrary.directory.map { url.path.hasPrefix($0.path + "/") } ?? false
				let path = (inDocs ? "docs/" : "") + name
				NSWorkspace.shared.open(URL(string: Links.repository.absoluteString + "/blob/main/" + path)!)
				return
			}
			decisionHandler(.cancel)
			if ["http", "https", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
		}
	}
}
