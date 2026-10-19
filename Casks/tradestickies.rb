cask "tradestickies" do
  version "0.3.1"
  sha256 "50bf2c6aa0cc577b46ece0511fbba310c4f2c46969836ff81685a40de81a75fc"

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
