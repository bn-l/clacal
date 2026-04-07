# Clacal

<p align="center">
  <img src="assets/demo.webp" alt="Clacal menu bar widget demo" width="720" />
  <br>
  <sub>Animation created with <a href="https://github.com/ManimCommunity/manim">Manim</a> (Community Edition)</sub>
</p>

A macOS menu bar app that tracks your [Claude Code](https://docs.anthropic.com/en/docs/claude-code) usage in real time. It polls the Anthropic OAuth usage API and shows an at-a-glance icon so you can pace yourself across sessions and the weekly window.

## Features

- **Single Bar Mode** — a center-zero bar that goes green (on pace) to red (over/under-pacing), with arrow hints in the 15-50% deviation range
- **Dual Bar Mode** — left bar shows session deviation, right bar shows daily budget remaining (green = full, red = depleted)
- **Popover dashboard** — pace, session, weekly deviation gauges, daily budget, and session/weekly utilization bars
- **EWMA-based pacing engine** — session boundary detection, active-hours scheduling, daily budget tracking, and optimal rate calculation
- **Persistent data** — polls and session history stored locally (`~/.config/clacal/usage_data.json`)
- **Configurable** — active hours per day, poll interval, display mode (`~/.config/clacal/config.json`)

## Requirements

- macOS 15+
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) logged in (`claude login`)
- [just](https://github.com/casey/just) (task runner)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build & Run

```bash
just gen   # generate Xcode project from project.yml
just run   # build and open the app
```

## Install

```bash
brew install bn-l/tap/clacal
```

Or build from source:

```bash
just dmg   # creates build/Clacal.dmg
```

## How It Works

Clacal reads your OAuth token from the macOS Keychain (set up by `claude login`), polls `api.anthropic.com/api/oauth/usage` every 5 minutes, and feeds the utilization data into an EWMA-based optimiser that computes session and weekly pacing targets. The menu bar icon updates to reflect whether you should ease off or use more.
