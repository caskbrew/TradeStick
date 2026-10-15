cask "tradesticker" do
  version "0"
  sha256 "f13eac0ca9da7685ec066067e21643d906bdf6fc2a5343de4c26af758dd75a4b"

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
