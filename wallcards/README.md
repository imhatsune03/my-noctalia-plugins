# Wallcards Plugin for Noctalia v5

A high-performance wallpaper manager and carousel for **Noctalia v5** supporting both **Static Images** and **Live Video Wallpapers** (via `gslapper`).

## Features

- 🖼️ **Dual Mode Wallpapers**:
  - **Imágenes**: Seamlessly sets static wallpapers and dynamically adapts Noctalia's shell palette to the wallpaper's dominant colors.
  - **Vídeos**: Plays animated video wallpapers using `gslapper` with automatic shell surface takeover.
- ⚡ **Non-blocking Asynchronous Thumbnails**:
  - Zero UI freezing: thumbnails and paused video frames are extracted in parallel using `noctalia.runAsync` with `ffmpeg` and `imagemagick`.
  - Cached in `~/.cache/noctalia/wallcards/` for instant subsequent loads.
- 🔄 **Auto-Refresh Watchdog**:
  - Automatically detects when new images or videos are added/deleted from wallpaper directories.
- 🎛️ **Signature Card Deck UI (walls.png)**:
  - Floating top navigation pill with live counters, tab switchers, shuffle, and live preview toggle.
  - Centered hero card with title and format badges flanked by 8 slim thumbnail strips.

## Dependencies

- `imagemagick` (`magick` or `convert`): For fast thumbnailing and color extraction.
- `ffmpeg`: For extracting paused thumbnail frames from video wallpapers.
- `gslapper`: For animated video wallpaper playback on Wayland shell surfaces.

## Controls & Shortcuts

| Key | Action |
| --- | --- |
| `←` / `→` / `J` / `K` | Navigate between wallpapers |
| `H` / `L` | Page back / Page forward |
| `Enter` | Apply wallpaper and close panel |
| `Space` | Apply wallpaper (keep panel open) |
| `I` / `1` | Switch to **Imágenes** tab |
| `V` / `2` | Switch to **Vídeos** tab |
| `P` | Toggle **Live Preview** |
| `R` | **Shuffle** random wallpaper |
| `Esc` / `Q` | Close panel |

# How to run
In panel will spawn a icon of wallpaper on panel only click and plugin opens
or you run a plugin with a terminal
```noctalia msg panel-toggle tonigineer/wallcards:main```
