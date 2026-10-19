# TradeStickies

A macOS menu-bar app: a floating sticker window per crypto trade with live price and PnL (Binance, Bybit, Poloniex).

## Install

```sh
brew install --cask caskbrew/tap/tradestickies
```

That taps `caskbrew/homebrew-tap` automatically. To tap explicitly first:

```sh
brew tap caskbrew/tap
brew install --cask tradestickies
```

Update and remove:

```sh
brew update && brew upgrade --cask tradestickies
brew uninstall --cask tradestickies          # keeps your data
brew uninstall --zap --cask tradestickies    # also deletes ~/Library/Application Support/TradeStickies
```

Requires macOS 15 (Sequoia) or newer. The app is not notarized; the cask removes the quarantine flag so it starts normally.

## Data

Your trades live in `~/Library/Application Support/TradeStickies/tradestickies.sqlite`.
Builds that are not the installed app (`swift run`, `.build/…`) use `TradeStickies-Dev/` instead and never touch it.

## Build from source

```sh
swift build -c release
swift test
scripts/package.sh 0.1.0   # dist/TradeStickies-0.1.0.zip + sha256 for the cask
```

## Dev vs installed

The installed app (`/Applications/TradeStickies.app`, bundle id `com.caskbrew.tradestickies`) and a dev build never share anything:

- data: `~/Library/Application Support/TradeStickies/` vs `TradeStickies-Dev/`; a dev build refuses to open the installed folder even via `TRADESTICKIES_DB`;
- settings: separate `UserDefaults` domains; the dev instance shows "DEV" in the menu bar;
- processes: run and restart dev only with `scripts/dev.sh`, which stops just the process started from `.build/`. Never `pkill TradeStickies`;
- `.claude/settings.json` denies Claude Code `pkill`/`killall`/`kill` and any access to the installed app's data folder.
