cask "tradestickies" do
  version "0.2.0"
  sha256 "2bab8384b0a8655b7edcaa540409a7e218c773f7db8b14d1c6562315e7a36196"

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
