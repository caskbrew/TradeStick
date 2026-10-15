cask "tradestickies" do
  version "0.1.0"
  sha256 "760a6e44ad7e3769d51c0f3bcc86e615f4baa4cf90e08093051098a883627cad"

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
