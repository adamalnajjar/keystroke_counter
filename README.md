# KeystrokeCounter

A step counter for your keyboard.

KeystrokeCounter is a macOS menu-bar app that tracks how much you type and click — without ever recording *what* you type. It runs quietly in the background, counts keystrokes and mouse clicks, and shows you the totals whenever you want them.

## What it is

KeystrokeCounter sits in your menu bar and keeps a running tally of your keyboard and mouse activity: how many keys you've pressed, how many times you've clicked, which keys you use most, and which apps you're most active in — broken down by day, week, month, and lifetime.

It's for anyone curious about their own computer-use habits: writers who want to see their output in a different unit, programmers who like a number going up, or anyone who's ever wondered just how much typing a working day actually involves.

There's no setup beyond granting one macOS permission (more on that below). Once it's running, it just works in the background — no dashboards to check, no accounts to create.

## Features

- **Stats at a glance** — keystroke and click totals for Today, This Week, This Month, and Lifetime
- **Records** — your best previous day/week/month, shown as a target to beat
- **History charts** — a 7- or 30-day view of daily keystrokes vs. clicks
- **Most-used keys and apps** — frequency breakdowns per time scope
- **Live typing speed** — a rolling keys-per-minute / words-per-minute readout
- **Daily goals** — set a combined keystrokes-plus-clicks target, with a progress bar and an optional notification when you hit it
- **Milestones** — a notification every 100,000 lifetime events
- **Launch at login**
- **Optional sync across your Macs** — through a small server you host yourself (see [Sync](#sync))
- **Everything stored locally** — nothing leaves your Mac unless you turn on sync (see [Privacy](#privacy))

## Screenshots

<!-- Screenshot: menu-bar panel showing Today's stats, goal progress, and typing speed -->

<!-- Screenshot: history chart (7/30-day keystrokes vs. clicks) -->

<!-- Screenshot: most-used keys and top apps sections -->

*(Screenshots coming soon — the panel is a single SwiftUI view, so these are easy to add once captured.)*

## Privacy

Privacy is the whole point of this app, so here's the direct version:

KeystrokeCounter needs **Accessibility permission** to do its job. On macOS, that permission is required for *any* app that wants to observe keyboard or mouse events happening in other apps — there's no lighter-weight permission for "just count, don't read." Granting it is what makes the counting possible at all, so it's worth being precise about what happens once you do:

- It **counts** key presses and clicks. It does not record the sequence of characters you type, so it can't reconstruct words, sentences, or passwords.
- For each key press it stores a short label (like `a`, `space`, or `return`) purely to build a frequency tally — never an ordered log of what was pressed.
- It notes which app was frontmost when an event happened (by app name), so it can show "most active apps" — it never reads window titles, on-screen content, or clipboard contents.
- It makes **no network requests unless you turn on sync**, which is off by default. With sync on, it sends the same per-day counts it stores locally — only to the server URL you enter, never anywhere else.
- All statistics live in a single file on your Mac, in your local Application Support folder. That file stays the source of truth even with sync on.
- There is no analytics SDK, no crash reporter, no third-party library of any kind in this project.

For the full, detailed breakdown — including exactly what happens if you deny the permission, and how to fully erase your data — see [PRIVACY.md](PRIVACY.md).

This isn't a claim that the app is "unhackable" or "100% secure" — no software is. It's a description of what the code actually does, and the code is public so you can check it yourself.

## Installation

There is currently **no downloadable release** — KeystrokeCounter is source-only for now. The only way to run it today is to build it yourself:

### Building from source

1. Clone the repository:
   ```
   git clone https://github.com/adamalnajjar/keystroke_counter.git
   ```
2. Open `keystroke_counter.xcodeproj` in Xcode.
3. Select the `keystroke_counter` scheme and build/run (`⌘R`).
4. On first launch, macOS will prompt for Accessibility permission — grant it in **System Settings → Privacy & Security → Accessibility** for keystrokes and clicks to be counted.

A signed, notarized downloadable build is planned but not available yet (see [Roadmap](#roadmap)).

## Requirements

- macOS 26.5 or later, as currently configured in the Xcode project
- Accessibility permission (required — the app cannot count events without it)
- Notification permission (optional — only needed for goal and milestone alerts)

## How it works

The app is a small, single-target SwiftUI project with no external dependencies:

- **`EventMonitor`** installs global `NSEvent` monitors for key-down and mouse-down events and forwards a key label, an event type, and the frontmost app's name to the store.
- **`StatsStore`** is the single source of truth: an `@Observable` model that keeps lifetime totals and a per-day history, debounces disk writes, and computes the derived values (scoped totals, records, top keys/apps, typing speed) the UI reads.
- **`ContentView`** is the dropdown panel shown from the menu bar; **`StatsChartView`** renders the history chart with Swift Charts.
- **`NotificationManager`** posts local notifications for milestones and daily goals — nothing more.
- **`SyncClient`** (opt-in) uploads this Mac's per-day counts to your sync server and fetches the other Macs' totals. Idle unless sync is enabled.

## Data storage

Statistics are written to a single JSON file at:

```
~/Library/Application Support/com.adamalnajjar.keystroke-counter/stats.json
```

This file contains your lifetime and per-day counts, key- and app-frequency tallies, your daily goal setting, and milestone bookkeeping. Writes are debounced (coalesced every few seconds of activity, and flushed on quit) rather than happening on every keystroke. A few UI preferences (like which panel sections are expanded) are stored separately via standard macOS app preferences. Unless you turn on sync, nothing is stored anywhere other than your own Mac.

## Sync

Sync is optional and off by default. It adds up your counts across several Macs using a small server you run yourself. The server is in [`server/`](server/): one Python file using only the standard library, plus SQLite.

**Server:** on any Docker host, `cd server`, create `.env` with `SYNC_TOKEN=<a long random string>` (e.g. `openssl rand -hex 32`), then `docker compose up -d --build`. It listens on `127.0.0.1:8085`, so put it behind HTTPS (a Cloudflare tunnel or reverse proxy).

**App:** Settings → *Sync across Macs* → enter the server's `https://` URL and the token. The token is stored in your Keychain. Do the same on each Mac.

How it works:

- Each Mac uploads its own per-day rows and lifetime counters every 5 minutes and whenever you open the panel. Uploads replace that Mac's previous rows rather than adding to them, so retries can't double-count.
- The server returns the sum of the *other* Macs' data. The app adds that to its own numbers everywhere: totals, records, charts, top keys and apps.
- If the server is unreachable the app keeps counting normally and catches up later. The last server response is cached in `remote.json` next to `stats.json`, so combined numbers still show offline.
- **Reset** only zeroes this Mac's lifetime counters. Other Macs' totals are unaffected.
- Daily goal setting and notifications are per Mac. If two Macs both cross the goal, each will notify once.

## Open source

The full source is in this repository, including the exact code that requests Accessibility permission, handles every keyboard and mouse event, and writes statistics to disk. Given the sensitivity of the permission this app requests, being able to read that code yourself — rather than take a privacy claim on faith — is the point of keeping it open.

## Contributing

This is a small, solo-maintained project. Bug reports and suggestions are welcome as [GitHub issues](https://github.com/adamalnajjar/keystroke_counter/issues). If you'd like to contribute code, feel free to open a pull request — for anything non-trivial, opening an issue first to discuss the approach is appreciated.

## License

KeystrokeCounter is released under the [MIT License](LICENSE).

## Roadmap

A short list of known gaps, not a feature wishlist:

- A signed, notarized downloadable build
- A dedicated app icon (the app currently ships with the Xcode default)
- Screenshots in this README
