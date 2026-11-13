# Pergola

A notch app for macOS. It turns the MacBook notch into a small, quiet control surface: music,
calendar, weather, a files tray, live progress from your apps and AI tools, and system overlays
that drop down from under the notch.

Pergola is a personal project. It is not signed or notarised for distribution, so for now you
build it yourself.

## What it does

- **Media**: album art, title, scrubber and controls for Music and Spotify, a live waveform drawn
  from the player's own audio, synced lyrics, and a large album-art view. YouTube, SoundCloud and
  other players in your browser show up too, with play, pause, skip and the progress bar.
- **Picture in picture**: drag the art down out of the notch and it stretches, then pinches off like
  a drop of water into a floating window playing the browser's video (or the album art for music).
  Drag it back up and it melts into the notch. Click the art to play the video inside the open notch.
- **Calendar**: a week strip you can tap through, with each day's events and a Join button for
  Zoom, Meet, Teams, Webex and FaceTime links.
- **Weather**: current conditions and the next hours, from your location or a city you type.
- **Files tray**: drag files onto the notch to park them, drag them back out later.
- **Live activities**: any app, script or AI agent on your Mac can show a task and its progress.
  Claude Code, ChatGPT / Codex, Gemini, Cursor and others each get their own mark. Click a task to
  jump to its app. See [INTEGRATIONS.md](INTEGRATIONS.md).
- **Timers and calls**: like the Dynamic Island, the closed notch shows the time left on a timer
  (Clock's, or one you start with `Pergola --timer 5m`) and how long you have been on a call, in an
  app or in the browser (Google Meet and others). Open the notch during a call for a Call page with
  the running time, a button that mutes your Mac's microphone, and one that brings the call forward.
- **Goal rings**: an app can share up to four goals, drawn as rings on their own page.
- **Overlays**: volume, brightness, battery (with time until full), AirPods, sound output, Focus,
  VPN, Personal Hotspot and display connections, song changes and task updates each appear as one
  line under the notch.
- **Lock screen**: a player and widgets on the lock screen.

Swipe left or right across the open notch to move between pages:
**Calendar ← Files ← Media → Weather**. During a call a Call page sits just left of Media.

## Requirements

- macOS 26 or later, on a Mac with a notch (it also runs without one, as a pill under the menu bar)
- Xcode 26 or the Swift 6.2 toolchain, to build

## Build and install

```bash
./build.sh            # builds build/Pergola.app, renders its icon, signs it
./build.sh --install  # …and installs it to /Applications
open /Applications/Pergola.app
```

`build.sh` signs with your Apple Development certificate when one is installed, so macOS remembers
Pergola's permissions across rebuilds; otherwise it signs ad hoc. Set `SIGN_ID` to choose an identity.

Pergola opens at login (Settings › General › Open at Login, on by default). macOS only allows that
for the copy in Applications, so install it there; the switch offers to move it if it isn't.

## Permissions

Each is asked for only when a feature needs it, and every feature can be switched off in Settings.

| Permission | Used for |
|---|---|
| Automation (Music / Spotify) | Reading what's playing, play/pause/skip |
| Automation (your browser) | Only while the browser uses the microphone: checking whether a tab is on a call site. For picture in picture: finding where the video sits on the page (also needs the browser's "Allow JavaScript from Apple Events") |
| Screen & System Audio Recording | Live waveform (only the music app, only while playing); picture in picture (only the browser's video, only while shown) |
| Accessibility | Taking over the volume and brightness keys |
| Full Disk Access | Reading Focus mode names |
| Bluetooth | AirPods battery |
| Location | Local weather (or type a city in Settings) |
| Calendars | The Calendar page |

## Privacy

Pergola has no account, no analytics and no server of its own. It talks to the network for three
things only:

- [Open-Meteo](https://open-meteo.com) for weather (your approximate location or chosen city)
- [LRCLIB](https://lrclib.net) for lyrics (the song's title, artist, album and length)
- Apple's iTunes Search for album art when the player doesn't supply any

The activity API listens on `127.0.0.1` only, refuses requests from web pages, and can be switched
off in Settings › Integrations.

## Good to know

- The lock screen widgets and the brightness overlay use private macOS frameworks (SkyLight and
  DisplayServices). They can break with a macOS update, and they rule out the Mac App Store.
- Browser music comes from macOS's private MediaRemote framework, through
  [MediaRemote Adapter](https://github.com/ungive/mediaremote-adapter) running inside `/usr/bin/perl`
  (macOS only answers its own programs). If an update closes that route, browser music simply stops
  appearing; Music and Spotify are unaffected. Switch it off in Settings › Media.
- Connecting Claude Code (Settings › Integrations) adds hooks to `~/.claude/settings.json`, only
  when you click Connect, and keeps a backup of the file as it was.

## Debug switches (environment variables)

| Variable | Effect |
|---|---|
| `PERGOLA_PIN_EXPANDED=1` | Keep the notch open (`PERGOLA_TAB=player|weather|tray|calendar`) |
| `PERGOLA_PEEK=volume|brightness|focus|output|airpods|charging|vpn|hotspot|coin` | Show that overlay for 60 s |
| `PERGOLA_LOCK_PREVIEW=1` | Show the lock-screen layout over the desktop |
| `PERGOLA_SETTINGS_PAGE=<page>` | Open Settings on a page |
| `PERGOLA_STRESS=<cycles>` | Run the animation stress test that many times and print frame timings |

Launch with `open -n --env NAME=value build/Pergola.app` (launching the binary directly from a
shell makes macOS attribute its permission requests to the shell).

## Credits

- Weather: [Open-Meteo](https://open-meteo.com) (free, no key)
- Lyrics: [LRCLIB](https://lrclib.net) (free, community-maintained)
- Browser now-playing: [MediaRemote Adapter](https://github.com/ungive/mediaremote-adapter) by Jonas
  van den Berg and contributors, BSD 3-Clause, included in `ThirdParty/` with its licence

## Licence

Pergola is free software under the [GNU General Public License v3.0](LICENSE). You can use, study
and change it; if you distribute a version of it, that version must be open source under the same
licence.

Copyright © 2026 Maddax Silver.
