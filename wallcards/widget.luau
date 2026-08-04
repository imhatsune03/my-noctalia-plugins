-- Wallcards bar widget for Noctalia v5
-- Displays an icon on the Noctalia bar/panel. Clicking it opens/toggles Wallcards.
-- Also resumes the last video wallpaper on shell startup via gslapper.

local bar = barWidget or widget

local HOME = noctalia.getenv("HOME") or ""
local CACHE_BASE = (noctalia.getenv("XDG_CACHE_HOME") or (HOME .. "/.cache")) .. "/noctalia/wallcards"
local LAST_VIDEO_FILE = CACHE_BASE .. "/last_video.txt"
local THUMB_DIR = CACHE_BASE .. "/thumbnails"

local function shellQuote(s: string): string
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function getThumbPathFor(wallpaperPath: string): string
  return THUMB_DIR .. "/" .. wallpaperPath:gsub("[^%w]", "_") .. ".jpg"
end

-- Resume the last video wallpaper if gslapper is not already running
local function resumeLastVideoWallpaper()
  if not noctalia.fileExists(LAST_VIDEO_FILE) then return end
  local content = noctalia.readFile(LAST_VIDEO_FILE)
  if not content or content == "" then return end

  local videoPath = content:match("^%s*(.-)%s*$")
  if not videoPath or videoPath == "" or not noctalia.fileExists(videoPath) then return end

  -- Check if gslapper is already running
  noctalia.runAsync("pgrep -x gslapper", function(result)
    local outStr = ""
    if type(result) == "string" then outStr = result
    elseif type(result) == "table" and result.stdout then outStr = result.stdout end

    -- Only resume if gslapper is NOT already running
    if outStr:match("^%s*$") or outStr == "" then
      -- Apply the thumbnail as wallpaper so the shell gets the correct palette
      local thumbPath = getThumbPathFor(videoPath)
      if noctalia.fileExists(thumbPath) then
        noctalia.setWallpaper(thumbPath)
      end
      -- Launch gslapper with the last video
      local cmd = "gslapper -f -o 'no-audio loop' '*' " .. shellQuote(videoPath)
      noctalia.runAsync(cmd, function()
        noctalia.runAsync("sleep 0.4", function()
          noctalia.setWallpaperEnabled("", false)
        end)
      end, 5000)
    end
  end, 2000)
end

local function updateWidget()
  if not bar then
    return
  end

  local iconColor = noctalia.getConfig("icon_color")
  if iconColor and iconColor ~= "" and iconColor ~= "none" and bar.setGlyphColor then
    bar.setGlyphColor(iconColor)
  end

  if bar.setGlyph then
    bar.setGlyph("cards")
  end

  if bar.setTooltip then
    bar.setTooltip(noctalia.tr("widget.tooltip"))
  end

  if bar.setVisible then
    bar.setVisible(true)
  end
end

function init()
  updateWidget()
  -- Resume last video wallpaper on shell startup
  resumeLastVideoWallpaper()
end

function update()
  updateWidget()
end

-- Primary click handler when clicking the icon on the panel/bar
function onClick()
  noctalia.togglePanel("imhatsune/wallcards:main")
end

-- Fallback activation hook
function onActivate()
  noctalia.togglePanel("imhatsune/wallcards:main")
end

-- Right click opens plugin settings
function onRightClick()
  noctalia.openSettings()
end

function onConfigChanged()
  updateWidget()
end

init()
