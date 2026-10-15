cask "tradestickies" do
  version "0.1.1"
  sha256 "c5db11fbc9520f8c19620d9c75783104ee3c16de163987608ec05f752c6be4de"

  url "https://github.com/caskbrew/TradeStickies/releases/download/v#{version}/TradeStickies-#{version}.zip"
  name "TradeStickies"
  desc "Floating sticker windows with live PnL for your crypto trades"
  homepage "https://github.com/caskbrew/TradeStickies"

  depends_on macos: :sequoia

  app "TradeStickies.app"

  # The app is ad-hoc signed, not notarized: drop the quarantine flag so Gatekeeper lets it start.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/TradeStickies.app"]
  end

  zap trash: "~/Library/Application Support/TradeStickies"
end
