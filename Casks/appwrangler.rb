# Homebrew cask for AppWrangler.
#
#   brew tap intarso/appwrangler https://github.com/IntarsO/AppWrangler
#   brew install --cask appwrangler
#
# Updated for each release (version + sha256 of the release zip).
cask "appwrangler" do
  version "1.4.1"
  sha256 "942f904d0eb3ff0e347b55b4b9375253a9f0d932c9ea868c449b85185a9febbd"

  url "https://github.com/IntarsO/AppWrangler/releases/download/v#{version}/AppWrangler-#{version}.zip"
  name "AppWrangler"
  desc "Per-app CPU, efficiency-core and memory limits for Apple Silicon"
  homepage "https://github.com/IntarsO/AppWrangler"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "AppWrangler.app"
  binary "#{appdir}/AppWrangler.app/Contents/MacOS/AppWrangler", target: "appwrangler"

  uninstall quit: "io.github.intarso.AppWrangler"

  zap trash: [
    "~/Library/Application Support/AppWrangler",
    "~/Library/Preferences/io.github.intarso.AppWrangler.plist",
  ]

  caveats <<~EOS
    AppWrangler is signed but not notarized by Apple. If macOS refuses to open it,
    right-click AppWrangler in Applications → Open, or run:
      xattr -dr com.apple.quarantine /Applications/AppWrangler.app

    Connect it to Claude Desktop, Claude Code or OpenAI Codex with:
      appwrangler mcp install
  EOS
end
