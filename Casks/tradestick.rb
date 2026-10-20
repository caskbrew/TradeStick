cask "tradestick" do
  version "0.4.1"
  sha256 "40f2c3c4b3d7ee0bf2c1ac36f04312d944471996d34687afbe29244892d837c5"

  url "https://github.com/caskbrew/TradeStick/releases/download/v#{version}/TradeStick-#{version}.zip"
  name "TradeStick"
  desc "Floating sticker windows with live PnL for your crypto trades"
  homepage "https://github.com/caskbrew/TradeStick"

  depends_on macos: :sequoia

  app "TradeStick.app"

  # The app is ad-hoc signed, not notarized: drop the quarantine flag so Gatekeeper lets it start.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/TradeStick.app"]
  end

  zap trash: ["~/Library/Application Support/TradeStick", "~/Library/Application Support/TradeStickies"]
end
