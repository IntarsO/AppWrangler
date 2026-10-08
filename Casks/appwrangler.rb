# Homebrew cask for AppWrangler.
#
#   brew tap intarso/appwrangler https://github.com/IntarsO/AppWrangler
#   brew install --cask appwrangler
#
# Updated for each release (version + sha256 of the release zip).
cask "appwrangler" do
  version "1.3.0"
  sha256 "1dd9fdb1b9823960e9e86a88316c5edfb37ac2c967c43591435697aa9379a8db"

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
