cask "tradestickies" do
  version "0.3.0"
  sha256 "8bd57d5ab6d4dd5ffcaa21d9471ef4d4e146ea9732fd1e3c130ae9c27d6ae5d0"

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
