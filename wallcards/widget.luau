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

local function getWaywallenDb(): string
  local candidates = {
    "~/.var/app/org.waywallen.waywallen/data/waywallen/waywallen-v2.db",
    "~/.local/share/waywallen/waywallen-v2.db",
    "~/.config/waywallen/waywallen-v2.db",
  }
  for _, candidate in ipairs(candidates) do
    local path = noctalia.expandPath(candidate)
    if path and noctalia.fileExists(path) then return path end
  end
  return noctalia.expandPath(candidates[1])
end

-- The layer-shell client only shows the wallpaper that the Waywallen daemon has
-- active. Selecting a scene therefore means resolving its library id and calling
-- daemon.ApplyById before starting the client.
local function buildEngineApplyCommand(pkgPath: string): string
  local bin = getWaywallenBin()
  local db = getWaywallenDb()
  local workshopId = pkgPath:match("/431960/([^/]+)")
  local key = workshopId and ("431960/" .. workshopId) or pkgPath
  return table.concat({
    "set -u",
    "db=" .. shellQuote(db),
    "key=" .. shellQuote(key),
    "id=''",
    "if [ -f \"$db\" ]; then",
    "  if command -v python3 >/dev/null 2>&1; then",
    "    id=$(python3 - \"$db\" \"$key\" <<'PY'",
    "import sqlite3, sys",
    "db, key = sys.argv[1], sys.argv[2]",
    "try:",
    "    con = sqlite3.connect('file:' + db + '?mode=ro', uri=True)",
    "    row = con.execute(\"SELECT id FROM item WHERE path LIKE ? LIMIT 1\", ('%' + key + '%',)).fetchone()",
    "    print(row[0] if row else '')",
    "except Exception as exc:",
    "    print('ERROR:' + str(exc))",
    "PY",
    "    )",
    "  elif command -v sqlite3 >/dev/null 2>&1; then",
    "    id=$(sqlite3 \"file:$db?mode=ro\" \"SELECT id FROM item WHERE path LIKE '%$key%' LIMIT 1\" 2>/dev/null || true)",
    "  fi",
    "fi",
    "case \"$id\" in",
    "  ''|ERROR:*) echo \"NOT_FOUND${id:+:$id}\" ;;",
    "  *) if busctl --user call org.waywallen.waywallen.Daemon /org/waywallen/waywallen/Daemon org.waywallen.waywallen.Daemon1 ApplyById s \"$id\" >/dev/null 2>&1; then",
    "       pkill -9 gslapper 2>/dev/null || true",
    "       echo \"OK:$id\"",
    "     else",
    "       echo \"DBUS_ERROR\"",
    "     fi ;;",
    "esac",
    "if ! pidof waywallen-layer-shell >/dev/null 2>&1; then",
    "  setsid -f " .. shellQuote(bin) .. " >/tmp/waywallen.log 2>&1 </dev/null || true",
    "fi",
  }, "\n")
end

local function resumeLastVideoWallpaper()
  noctalia.runAsync({"bash", "-c", "echo WIDGET_RESUME_TRIGGERED >> /tmp/widget_resume.log"}, function() end)
  if not noctalia.fileExists(LAST_VIDEO_FILE) then return end
  local content = noctalia.readFile(LAST_VIDEO_FILE)
  if not content or content == "" then return end
  local videoPath = content:match("^%s*(.-)%s*$")
  if not videoPath or videoPath == "" or not noctalia.fileExists(videoPath) then return end

  noctalia.runAsync({"bash", "-c", "pkill -9 gslapper 2>/dev/null || true; pkill -9 -f waywallen-layer-shell 2>/dev/null || true"}, function()
    local thumbPath = getThumbPathFor(videoPath)
    if noctalia.fileExists(thumbPath) then noctalia.setWallpaper(thumbPath) end
    local cmd = "gslapper -f -o 'no-audio loop' '*' " .. shellQuote(videoPath)
    noctalia.runAsync({"bash", "-c", cmd}, function()
      noctalia.runAsync({"bash", "-c", "sleep 2.5"}, function() noctalia.setWallpaperEnabled("", false) end)
    end)
  end)
end

local function resumeLastEngineWallpaper()
  if not noctalia.fileExists(LAST_ENGINE_FILE) then return end
  local file_content = noctalia.readFile(LAST_ENGINE_FILE)
  if not file_content or file_content == "" then return end
  local pkgPath = file_content:match("^%s*(.-)%s*$")
  if not pkgPath or pkgPath == "" or not noctalia.fileExists(pkgPath) then return end

  local thumbPath = getThumbPathFor(pkgPath)
  if noctalia.fileExists(thumbPath) then noctalia.setWallpaper(thumbPath) end
  noctalia.runAsync({"bash", "-c", buildEngineApplyCommand(pkgPath)}, function(result)
    local output = ""
    if type(result) == "string" then output = result
    elseif type(result) == "table" and result.stdout then output = result.stdout end
    if output:match("^OK:%d+") then
      noctalia.runAsync({"bash", "-c", "sleep 1.2"}, function() noctalia.setWallpaperEnabled("", false) end)
    end
  end, 15000)
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
