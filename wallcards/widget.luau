-- Wallcards bar widget for Noctalia v5
-- Displays an icon on the Noctalia bar/panel. Clicking it opens/toggles Wallcards.
-- Also resumes the last video or Wallpaper Engine wallpaper on shell startup.

local bar = barWidget or widget

local CACHE_BASE = noctalia.expandPath("~/.cache/noctalia/wallcards")
local LAST_VIDEO_FILE = CACHE_BASE .. "/last_video.txt"
local LAST_ENGINE_FILE = CACHE_BASE .. "/last_engine.txt"
local THUMB_DIR = CACHE_BASE .. "/thumbnails"

local function shellQuote(s: string): string
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function getThumbPathFor(wallpaperPath: string): string
  return THUMB_DIR .. "/" .. wallpaperPath:gsub("[^%w]", "_") .. ".jpg"
end

local function getWaywallenBin(): string
  local configured = noctalia.getConfig("waywallen_bin")
  local bin = "~/.local/bin/waywallen-layer-shell"
  if configured and configured ~= "" then bin = configured end
  return noctalia.expandPath(bin)
end

local function resumeLastVideoWallpaper()
  noctalia.runAsync("echo WIDGET_RESUME_TRIGGERED >> /tmp/widget_resume.log", function() end)
  if not noctalia.fileExists(LAST_VIDEO_FILE) then return end
  local content = noctalia.readFile(LAST_VIDEO_FILE)
  if not content or content == "" then return end
  local videoPath = content:match("^%s*(.-)%s*$")
  if not videoPath or videoPath == "" or not noctalia.fileExists(videoPath) then return end

  noctalia.runAsync("pkill -9 gslapper 2>/dev/null || true; pkill -9 -f waywallen-layer-shell 2>/dev/null || true", function()
    local thumbPath = getThumbPathFor(videoPath)
    if noctalia.fileExists(thumbPath) then noctalia.setWallpaper(thumbPath) end
    local cmd = "gslapper -f -o 'no-audio loop' '*' " .. shellQuote(videoPath)
    noctalia.runAsync(cmd, function()
      noctalia.runAsync("sleep 2.5", function() noctalia.setWallpaperEnabled("", false) end)
    end, 5000)
  end, 2000)
end

local function resumeLastEngineWallpaper()
  if not noctalia.fileExists(LAST_ENGINE_FILE) then return end
  local file_content = noctalia.readFile(LAST_ENGINE_FILE)
  if not file_content or file_content == "" then return end
  local pkgPath = file_content:match("^%s*(.-)%s*$")
  if not pkgPath or pkgPath == "" or not noctalia.fileExists(pkgPath) then return end

  noctalia.runAsync("pkill -9 gslapper 2>/dev/null || true", function()
    local thumbPath = getThumbPathFor(pkgPath)
    if noctalia.fileExists(thumbPath) then noctalia.setWallpaper(thumbPath) end
    local bin = getWaywallenBin()
    
    local db_cmd = [[
      pkg_path=]] .. shellQuote(pkgPath) .. [[
      rel_path=$(echo "$pkg_path" | grep -o "431960/.*" || true)
      if [ -n "$rel_path" ]; then
        wp_id=$(sqlite3 ~/.var/app/org.waywallen.waywallen/data/waywallen/waywallen-v2.db "SELECT id FROM item WHERE path LIKE '%$rel_path%' LIMIT 1" || true)
        if [ -n "$wp_id" ]; then
          busctl --user call org.waywallen.waywallen.Daemon /org/waywallen/waywallen/Daemon org.waywallen.waywallen.Daemon1 ApplyById s "$wp_id" || true
        fi
      fi
      pkill -9 -f waywallen-layer-shell 2>/dev/null || true
      ]] .. shellQuote(bin) .. [[ >/tmp/waywallen.log 2>&1 &
    ]]
    
    noctalia.runAsync(db_cmd, function()
      noctalia.runAsync("sleep 2.5", function() noctalia.setWallpaperEnabled("", false) end)
    end, 5000)
  end, 2000)
end

local function updateWidget()
  if not bar then return end
  local iconColor = noctalia.getConfig("icon_color")
  if iconColor and iconColor ~= "" and iconColor ~= "none" and bar.setGlyphColor then bar.setGlyphColor(iconColor) end
  if bar.setGlyph then bar.setGlyph("cards") end
  if bar.setTooltip then bar.setTooltip(noctalia.tr("widget.tooltip")) end
  if bar.setVisible then bar.setVisible(true) end
end

function init()
  updateWidget()
  local engineContent = noctalia.fileExists(LAST_ENGINE_FILE) and noctalia.readFile(LAST_ENGINE_FILE) or ""
  local videoContent = noctalia.fileExists(LAST_VIDEO_FILE) and noctalia.readFile(LAST_VIDEO_FILE) or ""
  local hasEngine = engineContent and engineContent:match("^%s*(.-)%s*$") ~= ""
  local hasVideo = videoContent and videoContent:match("^%s*(.-)%s*$") ~= ""

  if hasEngine then resumeLastEngineWallpaper()
  elseif hasVideo then resumeLastVideoWallpaper() end
end

function update() updateWidget() end
function onClick() noctalia.togglePanel("imhatsune/wallcards:main") end
function onActivate() noctalia.togglePanel("imhatsune/wallcards:main") end
function onRightClick() noctalia.openSettings() end
function onConfigChanged() updateWidget() end

init()
