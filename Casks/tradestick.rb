cask "tradestick" do
  version "0.4.0"
  sha256 "18d012382f1d032b85737610fd4b3df61816b63ca57f774a7dc8f02e759f519c"

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
