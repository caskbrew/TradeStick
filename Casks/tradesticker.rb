cask "tradesticker" do
  version "0.1.0"
  sha256 "18f06f3294f73c2f419f75fefb7e1dbdc4806fad362800a7e055b5a6b079bac2"

  # TODO: replace OWNER/REPO with the real GitHub repository.
  url "https://github.com/OWNER/REPO/releases/download/v#{version}/TradeSticker-#{version}.zip"
  name "TradeSticker"
  desc "Floating sticker windows with live PnL for your crypto trades"
  homepage "https://github.com/OWNER/REPO"

  depends_on macos: ">= :sequoia"

  app "TradeSticker.app"

  # The app is ad-hoc signed, not notarized: drop the quarantine flag so Gatekeeper lets it start.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/TradeSticker.app"]
  end

  zap trash: "~/Library/Application Support/TradeSticker"
end
