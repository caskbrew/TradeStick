cask "tradesticker" do
  version "0.1.0"
  sha256 "48d61aeb177f7e855b71927278420d945ac3670f99756fec7d501119eda019c3"

  url "https://github.com/caskbrew/TradeStickers/releases/download/v#{version}/TradeSticker-#{version}.zip"
  name "TradeSticker"
  desc "Floating sticker windows with live PnL for your crypto trades"
  homepage "https://github.com/caskbrew/TradeStickers"

  depends_on macos: ">= :sequoia"

  app "TradeSticker.app"

  # The app is ad-hoc signed, not notarized: drop the quarantine flag so Gatekeeper lets it start.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/TradeSticker.app"]
  end

  zap trash: "~/Library/Application Support/TradeSticker"
end
