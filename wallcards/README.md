# 🎴 Wallcards for Noctalia v5

A high-performance, aesthetically crafted wallpaper manager and carousel for **[Noctalia](https://github.com/noctalia-dev/noctalia)** supporting both **Static Images** and **Live Video Wallpapers** (via `gslapper`) with dynamic shell color extraction.

# Preview
![Preview](assets/wallcard.png)

<video src="assets/preview.mp4" width="100%" controls></video>
---

## ✨ Features

- 🖼️ **Dual Wallpaper Engine**:
  - **Imágenes (Static)**: Instantly sets static wallpapers (`.png`, `.jpg`, `.jpeg`, `.webp`, `.bmp`, `.avif`, `.gif`) and extracts dominant colors so the Noctalia shell automatically adapts its color palette.
  - **Vídeos (Animated)**: Plays live video wallpapers (`.mp4`, `.mkv`, `.webm`, `.avi`, `.mov`) seamlessly on Wayland shell surfaces via `gslapper`.
  - **Engine**: Browsable Wallpaper Engine library. Selecting a card tells the Waywallen daemon to activate that exact scene through DBus and paints it with `waywallen-layer-shell`. The converted preview is also sent to Noctalia so the shell palette follows the scene colors, while the static image stays hidden. Newly downloaded Workshop items are indexed into Waywallen automatically when you open the Engine tab. A speaker button in the top bar mutes or unmutes the scene audio without leaving the panel.
- ⚡ **Zero UI Freezing (Async Pipeline)**:
  - Video and high-res image thumbnails are extracted in the background via `ffmpeg` & `imagemagick` with a concurrent worker queue.
  - Thumbnails and metadata (resolution, frame rate, dominant color) are cached in `~/.cache/noctalia/wallcards/` for instant subsequent loads.
  - Instant synchronous directory scanning on panel open, recursing into subdirectories so grouped wallpapers still show up in the carousel.
- 🔁 **Auto-Resume Video Wallpapers**:
  - Automatically resumes your last active video wallpaper upon starting a new Noctalia session.
- 🗂️ **Tab Filtering**:
  - Quick tab switching between **Imágenes** (Images) and **Vídeos** (Videos) with live badge counts and keyboard hotkeys.
- 🎯 **Seamless Apply**:
  - Press `Enter` or `Space` to apply any static or video wallpaper directly without interrupting your workflow.
- 🔄 **Quick Refresh**:
  - Dedicated Refresh button and `F5` shortcut to immediately detect newly added or deleted wallpapers. Opening the Engine tab also asks Waywallen to reindex new Workshop downloads automatically, without polling.
- 🎨 **Signature Deck Carousel Interface**:
  - Smooth centered hero card displaying resolution badge and format tags, flanked by sleek thumbnail preview strips.
- 🎞️ **Animated Transitions**:
  - The deck performs a directional focus morph while you browse with `J`/`K`, arrows, page jumps, or strip clicks.
  - Switching between **Imágenes**, **Vídeos**, and **Engine** fades the section through a soft focus bloom instead of snapping.
  - Opening the panel adds a short entrance fade, so the interface settles in rather than appearing abruptly.

---

## 📦 Dependencies

Ensure the following tools are installed on your Linux system:

| Package | Command | Purpose |
| --- | --- | --- |
| **ImageMagick** | `magick` or `convert` | Fast image thumbnailing and dominant color palette extraction |
| **FFmpeg** | `ffmpeg` | Frame extraction and metadata probing for video wallpapers |
| **gSlapper** | `gslapper` | High-performance Wayland video wallpaper daemon ([gSlapper GitHub](https://github.com/Nomadcxx/gSlapper)) |
| **Waywallen** | `waywallen-layer-shell` | Wallpaper Engine renderer. The Waywallen app/daemon must be running so the plugin can select the scene through DBus |
| **Python 3** | `python3` | Reads the Waywallen library DB to resolve the selected scene id (falls back to `sqlite3` when Python is unavailable) |

### Installing Dependencies

- **Arch Linux / Manjaro**:
  ```bash
  sudo pacman -S imagemagick ffmpeg
  # Install gslapper from AUR:
  yay -S gslapper-bin # or build from https://github.com/Nomadcxx/gSlapper
  ```
- **Fedora**:
  ```bash
  sudo dnf install ImageMagick ffmpeg
  ```
- **Ubuntu / Debian**:
  ```bash
  sudo apt install imagemagick ffmpeg
  ```

---

## 🚀 Installation

Clone this repository into your Noctalia plugins folder:

```bash
mkdir -p ~/.local/share/noctalia/plugins
git clone https://github.com/Imhatsune/wallcards.git ~/.local/share/noctalia/plugins/wallcards
```

Then reload or enable the plugin in Noctalia:

```bash
noctalia msg plugins enable imhatsune/wallcards
```

Or enable it via **Noctalia Settings > Plugins > Wallcards**.

---

## ⌨️ Controls & Keybindings

When the Wallcards panel is open:

| Key | Action |
| --- | --- |
| `Enter` / `Space` | **Apply wallpaper** (keeps panel open) |
| `←` / `→` or `J` / `K` | Navigate between cards (previous / next) |
| `H` / `L` | Fast jump (4 cards back / 4 cards forward) |
| `1` | Switch to **Imágenes** tab |
| `2` | Switch to **Vídeos** tab |
| `3` | Switch to **Engine** tab |
| `R` | **Shuffle** (random wallpaper) |
| `F5` | **Refresh** wallpaper list |
| `Esc` / `Q` | Close panel |

When the **Engine** tab is active, the top bar also shows a speaker button to mute/unmute the Waywallen scene audio. The icon reflects the current Waywallen `manual_muted` setting.

---

## 🔋 Resource usage

- Switching Engine cards sends a **single `ApplyById` DBus call**. Item ids are preloaded in one batch per scan, so no `python3`/`sqlite3` process is spawned for each selection.
- **Engine → Engine switches only update Noctalia's palette source** with the new converted preview; the static wallpaper surface stays hidden, so the scene is never covered. Noctalia regenerates the shell colors once per scene change.
- `waywallen-layer-shell` runs as **one persistent process** and is not restarted when changing scenes.
- For the lowest CPU/RAM usage, close the **Waywallen UI window** when you are done browsing: the daemon and the wallpaper keep running headless. Keeping the renderer `fps` between 24 and 30 also helps.

## ⚙️ Configuration

You can customize Wallcards in **Noctalia Settings > Plugins > Wallcards**:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `wallpaper_dir` | Folder | `~/Imágenes/Wallpapers` | Directory where your images and video wallpapers are stored (subdirectories are scanned recursively) |
| `engine_wallpaper_dir` | Folder | `~/.steam/steam/steamapps/workshop/content/431960` | Steam Workshop folder with Wallpaper Engine items |
| `waywallen_bin` | Text | `~/.local/bin/waywallen-layer-shell` | Waywallen layer-shell display client |
| `card_height` | Integer | `230` (180–340px) | Height of the carousel cards |
| `icon_color` | Color | `none` | Custom accent color for the top bar widget icon |

---

## 📂 File Structure

```text
wallcards/
├── assets/
│   └── preview.png          # UI preview screenshot
├── translations/            # Localization files (16 languages)
│   ├── en.json
│   ├── es.json
│   └── ...
├── panel.luau               # Main carousel interface & wallpaper applier
├── widget.luau              # Top bar widget & startup video auto-resume
├── shortcut.luau            # Control Center quick toggle tile
├── plugin.toml              # Noctalia plugin manifest
├── README.md                # Documentation
└── LICENSE                  # MIT License
```

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
