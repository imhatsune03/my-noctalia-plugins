--!nonstrict
-- Wallcards Panel for Noctalia v5
-- Unified wallpaper manager with tabs (Images / Videos / Engine),
-- dynamic shell palette theming, resolution & frame rate badges,
-- manual Enter-to-apply (without closing), centered card carousel,
-- and auto-play last video/engine wallpaper on session start.
-- Engine tab uses open-wallpaper-engine via waywallen-display layer_shell.

local HOME = noctalia.getenv("HOME") or ""
local CACHE_BASE = (noctalia.getenv("XDG_CACHE_HOME") or (HOME .. "/.cache")) .. "/noctalia/wallcards"
local CACHE_DIR = CACHE_BASE .. "/thumbnails"
local INDEX_FILE = CACHE_BASE .. "/index.json"
local LAST_VIDEO_FILE = CACHE_BASE .. "/last_video.txt"
local LAST_ENGINE_FILE = CACHE_BASE .. "/last_engine.txt"

local THUMB_MAX_CONCURRENT = 2
local BATCH_SIZE = 40

local IMAGE_EXTS = { png = true, jpg = true, jpeg = true, webp = true, bmp = true, avif = true, gif = true }
local VIDEO_EXTS = { mp4 = true, mkv = true, webm = true, avi = true, mov = true }
local ENGINE_EXTS = { pkg = true }

local TAB_ORDER = { images = 1, videos = 2, engine = 3 }
local TAB_SPLIT = 0.38

local state = {
  allWallpapers = {},
  engineWallpapers = {},
  wallpapers = {},
  imageCount = 0,
  videoCount = 0,
  engineCount = 0,
  selectedIndex = 1,
  cardHeight = 230,
  wallpaperDir = "",
  engineDir = "",
  statusMessage = "",
  activeTab = "images",
  engineActive = false,
  engineMuted = false,
  anim = {
    active = false,
    elapsed = 0,
    duration = 240,
    direction = 0,
    mode = "carousel",
    pendingTab = nil,
    tabCommitted = false,
  },
}

local thumbCache = {}
local thumbPending = {}
local thumbQueue = {}
local thumbQueued = {}
local thumbActive = 0
local indexDirty = false
local tickCount = 0

-- Resolved Waywallen item ids, keyed by wallpaper path. Filled in one batch at
-- scan time so switching scenes only costs a single DBus call.
local engineIdCache = {}
local engineIdsPreloaded = false
local engineIdsReady = false
local engineKnownWorkshopIds = {}
local engineAutoIndexing = false
local engineMuteBusy = false
local lastEngineRescan = 0

local renderUI
local pumpThumbQueue
local scanWallpapers
local applyFilteredView
local refreshEngineList
local maybeAutoIndexEngine

local function shellQuote(s: string): string
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function getExtension(path: string): string
  local ext = path:match("%.([^%.]+)$")
  return ext and ext:lower() or ""
end

local function getBaseNameWithoutExt(name: string): string
  local base = name:match("^(.-)%.[^%.]+$")
  return base or name
end

local function getWallpaperDir(): string
  local configured = noctalia.getConfig("wallpaper_dir")
  if configured and configured ~= "" then return noctalia.expandPath(configured) end
  local wpDir = noctalia.expandPath("~/Imágenes/Wallpapers")
  if wpDir and noctalia.fileExists(wpDir) then return wpDir end
  local picWallpapers = noctalia.expandPath("~/Pictures/Wallpapers")
  if picWallpapers and noctalia.fileExists(picWallpapers) then return picWallpapers end
  local picturesDir = noctalia.expandPath("~/Pictures")
  if picturesDir and noctalia.fileExists(picturesDir) then return picturesDir end
  return noctalia.expandPath("~/Imágenes")
end

local function getEngineDir(): string
  local configured = noctalia.getConfig("engine_wallpaper_dir")
  if configured and configured ~= "" then return noctalia.expandPath(configured) end
  local steamWE = noctalia.expandPath("~/.steam/steam/steamapps/workshop/content/431960")
  if steamWE and noctalia.fileExists(steamWE) then return steamWE end
  local flatpakWE = noctalia.expandPath("~/.var/app/com.valvesoftware.Steam/data/Steam/steamapps/workshop/content/431960")
  if flatpakWE and noctalia.fileExists(flatpakWE) then return flatpakWE end
  return noctalia.expandPath("~/Wallpapers/WallpaperEngine")
end

local function getWaywallenBin(): string
  local configured = noctalia.getConfig("waywallen_bin")
  local bin = "~/.local/bin/waywallen-layer-shell"
  if configured and configured ~= "" then bin = configured end
  return noctalia.expandPath(bin)
end

-- Waywallen keeps its library in a SQLite DB owned by the Flatpak sandbox.
-- The layer-shell binary is only a display client: it paints whatever wallpaper
-- the daemon has active, so the requested scene must first be selected with
-- daemon.ApplyById(<item id>). The id is resolved from the DB without requiring
-- the `sqlite3` CLI (python3's stdlib sqlite3 is used when available).
local WAYWALLEN_DBUS_NAME = "org.waywallen.waywallen.Daemon"
local WAYWALLEN_DBUS_PATH = "/org/waywallen/waywallen/Daemon"
local WAYWALLEN_DBUS_IFACE = "org.waywallen.waywallen.Daemon1"

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

-- Waywallen persists its manual mute state in config.toml. There is no
-- Muted property on the DBus interface, so read the setting to keep the
-- Engine button in sync with the tray/UI toggle.
local function getWaywallenConfig(): string
  local candidates = {
    "~/.var/app/org.waywallen.waywallen/config/waywallen/config.toml",
    "~/.config/waywallen/config.toml",
  }
  local xdgConfig = noctalia.getenv("XDG_CONFIG_HOME")
  if xdgConfig and xdgConfig ~= "" then
    table.insert(candidates, 1, xdgConfig .. "/waywallen/config.toml")
  end
  for _, candidate in ipairs(candidates) do
    local path = noctalia.expandPath(candidate)
    if path and noctalia.fileExists(path) then return path end
  end
  return ""
end

local function readEngineMuted(): boolean
  local path = getWaywallenConfig()
  if path == "" then return state.engineMuted end
  local content = noctalia.readFile(path)
  if not content then return state.engineMuted end
  local value = content:match("manual_muted%s*=%s*(%a+)")
  if value == "true" then return true end
  if value == "false" then return false end
  return state.engineMuted
end

local function getEngineKey(path: string): string
  local workshopId = path:match("/431960/([^/]+)")
  -- The DB stores Steam paths relative to the Steam root, so the workshop id is
  -- the most reliable key across ~/.steam, ~/.local/share/Steam and Flatpak Steam.
  return workshopId and ("431960/" .. workshopId) or path
end

-- Cheap snapshot (stat only) of the workshop folders that contain a usable
-- Wallpaper Engine item. Used to detect newly downloaded items without polling.
local function collectEngineWorkshopIds()
  local ids = {}
  local dir = state.engineDir
  if not dir or dir == "" then return ids end
  local entries = noctalia.listDir(dir)
  if not entries or type(entries) ~= "table" then return ids end
  for _, name in ipairs(entries) do
    if name ~= "." and name ~= ".." and not name:match("^%.") then
      local fullPath = dir .. "/" .. name
      local info = noctalia.fileInfo(fullPath)
      if info and info.isDir
        and (noctalia.fileExists(fullPath .. "/scene.pkg") or noctalia.fileExists(fullPath .. "/project.json")) then
        ids[name] = true
      end
    end
  end
  return ids
end

-- One DB read per scan fills the id map for every engine item. Subsequent
-- selections then avoid spawning python/sqlite entirely.
local function preloadEngineIds()
  if engineIdsPreloaded then return end
  engineIdsPreloaded = true
  if #state.engineWallpapers == 0 then engineIdsReady = true return end
  local db = getWaywallenDb()
  if not db or not noctalia.fileExists(db) then engineIdsReady = true return end
  local script = table.concat({
    "db=" .. shellQuote(db),
    "python3 - \"$db\" <<'PY'",
    "import sqlite3, sys",
    "try:",
    "    con = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)",
    "    for item_id, path in con.execute(\"SELECT id, path FROM item WHERE path LIKE '%431960%'\"):",
    "        print(str(item_id) + '\\t' + path)",
    "except Exception:",
    "    pass",
    "PY",
  }, "\n")
  noctalia.runAsync({"bash", "-c", script}, function(result)
    local out = ""
    if type(result) == "string" then out = result
    elseif type(result) == "table" and result.stdout then out = result.stdout end
    if out ~= "" then
      local byKey = {}
      for id, rel in out:gmatch("(%d+)\t([^\r\n]+)") do
        local workshopId = rel:match("431960/([^/]+)")
        if workshopId then byKey["431960/" .. workshopId] = id end
      end
      for _, item in ipairs(state.engineWallpapers) do
        local id = byKey[getEngineKey(item.path)]
        if id then engineIdCache[item.path] = id end
      end
    end
    engineIdsReady = true
  end, 10000)
end

local function buildEngineApplyCommand(item, cachedId): string
  local bin = getWaywallenBin()
  local db = getWaywallenDb()
  local key = getEngineKey(item.path)
  return table.concat({
    "set -u",
    "db=" .. shellQuote(db),
    "key=" .. shellQuote(key),
    "title=" .. shellQuote(item.baseName or item.name or ""),
    "id=" .. shellQuote(cachedId and tostring(cachedId) or ""),
    "if [ -z \"$id\" ] && [ -f \"$db\" ]; then",
    "  if command -v python3 >/dev/null 2>&1; then",
    "    id=$(python3 - \"$db\" \"$key\" \"$title\" <<'PY'",
    "import sqlite3, sys",
    "db, key, title = sys.argv[1], sys.argv[2], sys.argv[3]",
    "try:",
    "    con = sqlite3.connect('file:' + db + '?mode=ro', uri=True)",
    "    row = con.execute(\"SELECT id FROM item WHERE path LIKE ? LIMIT 1\", ('%' + key + '%',)).fetchone()",
    "    if not row and title:",
    "        row = con.execute(\"SELECT id FROM item WHERE display_name = ? LIMIT 1\", (title,)).fetchone()",
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
    "  *) if out=$(busctl --user call " .. WAYWALLEN_DBUS_NAME .. " " .. WAYWALLEN_DBUS_PATH .. " " .. WAYWALLEN_DBUS_IFACE .. " ApplyById s \"$id\" 2>&1); then",
    "       pkill -9 gslapper 2>/dev/null || true",
    "       echo \"OK:$id\"",
    "     else",
    "       echo \"DBUS_ERROR:$out\"",
    "     fi ;;",
    "esac",
    "if ! pidof waywallen-layer-shell >/dev/null 2>&1; then",
    "  setsid -f " .. shellQuote(bin) .. " >/tmp/waywallen.log 2>&1 </dev/null || true",
    "fi",
  }, "\n")
end

local function loadThumbnailIndex()
  if noctalia.fileExists(INDEX_FILE) then
    local content = noctalia.readFile(INDEX_FILE)
    if content and content ~= "" and noctalia.json and noctalia.json.decode then
      local ok, decoded = pcall(noctalia.json.decode, content)
      if ok and type(decoded) == "table" then thumbCache = decoded end
    end
  end
end

local function saveThumbnailIndex()
  if not indexDirty or not noctalia.json or not noctalia.json.encode then return end
  indexDirty = false
  local ok, encoded = pcall(noctalia.json.encode, thumbCache)
  if ok and encoded then noctalia.writeFile(INDEX_FILE, encoded) end
end

local function getThumbPathFor(wallpaperPath: string): string
  return CACHE_DIR .. "/" .. wallpaperPath:gsub("[^%w]", "_") .. ".jpg"
end

local function safeImagePath(item): string
  if item.thumbPath ~= "" then return item.thumbPath end
  return ""
end

local function isItemVisible(path: string): boolean
  local list = state.wallpapers
  local total = #list
  if total == 0 then return false end
  for offset = -4, 4 do
    local wrapped = ((state.selectedIndex + offset - 1) % total) + 1
    if list[wrapped] and list[wrapped].path == path then return true end
  end
  return false
end

function pumpThumbQueue()
  while thumbActive < THUMB_MAX_CONCURRENT and #thumbQueue > 0 do
    local item = table.remove(thumbQueue, 1)
    local path = item.path
    thumbQueued[path] = nil
    if not thumbPending[path] then
      local dest = getThumbPathFor(path)
      local cached = thumbCache[path]
      if cached and cached.res and cached.thumbPath then
        item.thumbPath = cached.thumbPath
        item.colorHex = cached.colorHex or item.colorHex
        item.res = cached.res or item.res
        item.fps = cached.fps or item.fps
      else
        thumbPending[path] = true
        thumbActive += 1
        local cmd
        if item.isEngine then
          local dir = path
          if path:match("%.pkg$") or path:match("%.mp4$") then dir = path:match("^(.*)/[^/]+$") or path end
          local bash_cmd = [[
            d=]] .. shellQuote(dir) .. [[
            dst=]] .. shellQuote(dest) .. [[
            src=""
            if [ -f "$d/preview.jpg" ]; then src="$d/preview.jpg"
            elif [ -f "$d/preview.png" ]; then src="$d/preview.png"
            elif [ -f "$d/preview.gif" ]; then src="$d/preview.gif[0]"
            fi
            if [ -n "$src" ]; then
              magick "$src" -thumbnail 480x270^ -gravity center -extent 480x270 -quality 82 "$dst" 2>/dev/null &&               magick "$dst" -resize 1x1 -format ' #%[hex:u.p{0,0}]' info: 2>/dev/null
            else
              magick -size 480x270 xc:#0F0620 -fill '#4C1D95' -draw 'rectangle 200,120 280,150' "$dst" 2>/dev/null
            fi
            exit 0
          ]]
          cmd = bash_cmd
        elseif item.isVideo then
          -- IMPORTANT: noctalia spawns runAsync children in a background process group
          -- that still owns the controlling terminal (fd 0 = tty). ffmpeg detects a tty
          -- on stdin, enables its interactive keyboard reader and read()s the tty, which
          -- raises SIGTTIN and stops the process until the runAsync timeout kills it
          -- (exit 137 -> no thumbnail). `-nostdin` plus redirecting the whole chain's
          -- stdin from /dev/null prevents ffmpeg from ever touching the terminal.
          cmd = "( ffmpeg -nostdin -y -ss 00:00:01 -i " .. shellQuote(path) .. " -vframes 1 -vf 'scale=480:-1' -q:v 3 " .. shellQuote(dest) .. " 2>/dev/null && ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=s=x:p=0 " .. shellQuote(path) .. " 2>/dev/null && magick " .. shellQuote(dest) .. " -resize 1x1 -format ' #%[hex:u.p{0,0}]' info: 2>/dev/null ) </dev/null || true"
        else
          cmd = "magick " .. shellQuote(path) .. " -thumbnail 480x270^ -gravity center -extent 480x270 -quality 82 " .. shellQuote(dest) .. " 2>/dev/null && magick identify -format '%wx%h' " .. shellQuote(path) .. " 2>/dev/null && magick " .. shellQuote(dest) .. " -resize 1x1 -format ' #%[hex:u.p{0,0}]' info: 2>/dev/null || true"
        end
        noctalia.runAsync({"bash", "-c", cmd}, function(result)
          thumbActive -= 1
          thumbPending[path] = nil
          if noctalia.fileExists(dest) then
            item.thumbPath = dest
            local outStr = ""
            if type(result) == "string" then outStr = result
            elseif type(result) == "table" and result.stdout then outStr = result.stdout end
            local hex = outStr:match("#(%x%x%x%x%x%x)")
            if hex then item.colorHex = "#" .. hex end
            if item.isEngine then
              item.res = "WE"; item.fps = "Engine"
            elseif item.isVideo then
              local w, h, num, den = outStr:match("(%d+)x(%d+)x(%d+)/(%d+)")
              if w and h then
                item.res = w .. "x" .. h
                item.fps = math.floor((tonumber(num) / tonumber(den)) + 0.5) .. " fps"
              else
                local w2, h2 = outStr:match("(%d+)x(%d+)")
                if w2 and h2 then item.res = w2 .. "x" .. h2 end
              end
            else
              local w, h = outStr:match("(%d+)x(%d+)")
              if w and h then item.res = w .. "x" .. h end
              item.fps = "Static"
            end
            thumbCache[path] = { thumbPath = dest, colorHex = item.colorHex, res = item.res, fps = item.fps }
            indexDirty = true
            saveThumbnailIndex()
            if isItemVisible(path) then renderUI() end
          end
          pumpThumbQueue()
        end, 15000)
      end
    end
  end
end

local function queueThumbnail(item)
  if not item or (item.thumbPath ~= "" and item.res and item.res ~= "") then return end
  local cached = thumbCache[item.path]
  if cached and cached.res and cached.thumbPath then
    item.thumbPath = cached.thumbPath
    item.colorHex = cached.colorHex or item.colorHex
    item.res = cached.res or item.res
    item.fps = cached.fps or item.fps
    return
  end
  if not thumbPending[item.path] and not thumbQueued[item.path] then
    thumbQueued[item.path] = true
    table.insert(thumbQueue, item)
    pumpThumbQueue()
  end
end

local function saveLastVideoPath(videoPath: string)
  noctalia.mkdirAll(CACHE_BASE)
  noctalia.writeFile(LAST_VIDEO_FILE, videoPath)
end

local function clearLastVideoPath()
  if noctalia.fileExists(LAST_VIDEO_FILE) then noctalia.writeFile(LAST_VIDEO_FILE, "") end
end

local function saveLastEnginePath(pkgPath: string)
  noctalia.mkdirAll(CACHE_BASE)
  noctalia.writeFile(LAST_ENGINE_FILE, pkgPath)
end

local function clearLastEnginePath()
  if noctalia.fileExists(LAST_ENGINE_FILE) then noctalia.writeFile(LAST_ENGINE_FILE, "") end
end

local function applyVideoWallpaper(item)
  if not item then return end
  state.engineActive = false
  if item.thumbPath ~= "" and noctalia.fileExists(item.thumbPath) then
    noctalia.setWallpaper(item.thumbPath)
  end
  clearLastEnginePath()
  saveLastVideoPath(item.path)
  noctalia.runAsync({"bash", "-c", "pkill -9 gslapper 2>/dev/null || true; pkill -9 -f waywallen-layer-shell 2>/dev/null || true"}, function()
    local cmd = "gslapper -f -o 'no-audio loop' '*' " .. shellQuote(item.path)
    noctalia.runAsync({"bash", "-c", cmd}, function()
      noctalia.runAsync({"bash", "-c", "sleep 0.4"}, function() noctalia.setWallpaperEnabled("", false) end)
    end)
    state.statusMessage = "Vídeo aplicado: " .. item.name
    renderUI()
  end)
end

local function applyStaticWallpaper(item)
  if not item then return end
  state.engineActive = false
  clearLastVideoPath()
  clearLastEnginePath()
  noctalia.runAsync({"bash", "-c", "pkill -9 gslapper 2>/dev/null || true; pkill -9 -f waywallen-layer-shell 2>/dev/null || true"}, function()
    noctalia.setWallpaperEnabled("", true)
    noctalia.setWallpaper(item.path)
    state.statusMessage = "Wallpaper aplicado: " .. item.name
    renderUI()
  end)
end

-- Palette sequence guard: if the user switches Engine items quickly, only the
-- thumbnail of the last applied item may update Noctalia's palette.
local enginePaletteSeq = 0

-- Hand Noctalia the converted preview so it can regenerate the shell palette.
-- The static image is hidden again below while Waywallen paints the scene.
local function pushEngineWallpaperImage(item)
  enginePaletteSeq += 1
  local seq = enginePaletteSeq
  if item.thumbPath ~= "" and noctalia.fileExists(item.thumbPath) then
    noctalia.setWallpaper(item.thumbPath)
    return
  end
  -- The card thumbnail may still be queued/generating. Wait for it without
  -- blocking the UI, then push it if this is still the selected Engine item.
  queueThumbnail(item)
  local expected = getThumbPathFor(item.path)
  noctalia.runAsync({
    "bash", "-c",
    "for i in $(seq 1 25); do [ -s " .. shellQuote(expected) .. " ] && sleep 0.15 && exit 0; sleep 0.2; done; exit 1",
  }, function(result)
    if seq ~= enginePaletteSeq then return end
    if noctalia.fileExists(expected) then
      item.thumbPath = expected
      noctalia.setWallpaper(expected)
    end
  end, 8000)
end

local function applyEngineWallpaper(item)
  if not item then return end
  -- Always push the new preview: Noctalia regenerates its palette from it.
  -- Keeping the old guard (only on entering Engine mode) left the colors from
  -- the previous Engine wallpaper when switching Engine -> Engine.
  local entering = not state.engineActive
  pushEngineWallpaperImage(item)
  clearLastVideoPath()
  saveLastEnginePath(item.path)
  state.statusMessage = "Aplicando Engine: " .. item.name

  local cachedId = engineIdCache[item.path]
  noctalia.runAsync({"bash", "-c", buildEngineApplyCommand(item, cachedId)}, function(result)
    local output = ""
    if type(result) == "string" then output = result
    elseif type(result) == "table" and result.stdout then output = result.stdout end
    output = output:gsub("%s+$", "")
    local id = output:match("^OK:(%d+)")
    if id then
      engineIdCache[item.path] = id
      state.engineActive = true
      state.statusMessage = "Engine aplicado: " .. (item.baseName or item.name) .. " (id " .. id .. ")"
      if entering then
        noctalia.runAsync({"bash", "-c", "sleep 0.8"}, function() noctalia.setWallpaperEnabled("", false) end)
      end
    elseif output:match("^NOT_FOUND") then
      state.statusMessage = "Engine: no está indexado en Waywallen; reindexa en la app"
    else
      state.statusMessage = "Engine: error al aplicar " .. output:sub(1, 90)
    end
    renderUI()
  end, 15000)
end

local function applyWallpaper(item)
  if not item then return end
  if item.isEngine then applyEngineWallpaper(item)
  elseif item.isVideo then applyVideoWallpaper(item)
  else applyStaticWallpaper(item) end
end

-- Mute/unmute the Waywallen scene audio. The daemon has separate Mute and
-- Unmute methods; no argument is needed.
local function toggleEngineMute()
  if engineMuteBusy then return end
  engineMuteBusy = true
  local muted = not state.engineMuted
  state.engineMuted = muted
  state.statusMessage = muted and "Sonido de Engine silenciado" or "Sonido de Engine activado"
  renderUI()
  local started = noctalia.runAsync({
    "busctl", "--user", "call",
    WAYWALLEN_DBUS_NAME, WAYWALLEN_DBUS_PATH, WAYWALLEN_DBUS_IFACE,
    muted and "Mute" or "Unmute",
  }, function(result)
    engineMuteBusy = false
    if type(result) == "table" and result.exitCode and result.exitCode ~= 0 then
      state.engineMuted = not muted
      state.statusMessage = "Engine: no se pudo cambiar el audio"
      renderUI()
    end
  end, 8000)
  if not started then
    engineMuteBusy = false
    state.engineMuted = not muted
    state.statusMessage = "Engine: no se pudo cambiar el audio"
    renderUI()
  end
end

function applyFilteredView()
  local tab = state.activeTab
  local filtered = {}
  if tab == "engine" then
    for _, item in ipairs(state.engineWallpapers) do table.insert(filtered, item) end
  else
    for _, item in ipairs(state.allWallpapers) do
      if tab == "images" and not item.isVideo then table.insert(filtered, item)
      elseif tab == "videos" and item.isVideo then table.insert(filtered, item) end
    end
  end
  state.wallpapers = filtered
  if #state.wallpapers == 0 then state.selectedIndex = 1
  elseif state.selectedIndex > #state.wallpapers then state.selectedIndex = #state.wallpapers
  elseif state.selectedIndex < 1 then state.selectedIndex = 1 end
end

local function commitPendingTab()
  if state.anim.mode ~= "tab" or state.anim.tabCommitted then return end
  local tab = state.anim.pendingTab
  if not tab then return end
  state.activeTab = tab
  state.selectedIndex = 1
  applyFilteredView()
  local total = #state.wallpapers
  if total > 0 then
    for off = -4, 4 do
      local idx = ((state.selectedIndex + off - 1) % total) + 1
      queueThumbnail(state.wallpapers[idx])
    end
  end
  state.anim.tabCommitted = true
  if tab == "engine" then maybeAutoIndexEngine() end
end

local function startCarouselAnimation(direction)
  if not panel or not panel.setNeedsFrameTick then return end
  state.anim.active = true
  state.anim.elapsed = 0
  state.anim.duration = 240
  state.anim.direction = direction or 0
  state.anim.mode = "carousel"
  state.anim.pendingTab = nil
  state.anim.tabCommitted = false
  panel.setNeedsFrameTick(true)
end

local function startTabAnimation(tab: string, direction: number)
  state.anim.mode = "tab"
  state.anim.pendingTab = tab
  state.anim.tabCommitted = false
  state.anim.direction = direction or 0
  state.anim.elapsed = 0
  state.anim.duration = 300
  if not panel or not panel.setNeedsFrameTick then
    commitPendingTab()
    state.anim.active = false
    return
  end
  state.anim.active = true
  panel.setNeedsFrameTick(true)
end

local function stopCarouselAnimation()
  if state.anim.active and state.anim.mode == "tab" then commitPendingTab() end
  state.anim.active = false
  state.anim.elapsed = state.anim.duration
  state.anim.direction = 0
  state.anim.mode = "carousel"
  state.anim.pendingTab = nil
  state.anim.tabCommitted = false
  if panel and panel.setNeedsFrameTick then panel.setNeedsFrameTick(false) end
end

local function selectIndex(newIndex: number, direction)
  if state.anim.active and state.anim.mode == "tab" then
    commitPendingTab()
    stopCarouselAnimation()
  end
  local list = state.wallpapers
  if #list == 0 then return end
  if newIndex > #list then newIndex = 1
  elseif newIndex < 1 then newIndex = #list end
  local oldIndex = state.selectedIndex
  state.selectedIndex = newIndex
  local current = list[state.selectedIndex]
  if current then
    queueThumbnail(current)
    local total = #list
    for _, off in ipairs({ -1, 1, -2, 2, -3, 3, -4, 4 }) do
      local idx = ((state.selectedIndex + off - 1) % total) + 1
      queueThumbnail(list[idx])
    end
  end
  if oldIndex ~= newIndex and #list > 1 then
    startCarouselAnimation(direction or (newIndex > oldIndex and 1 or -1))
  end
  renderUI()
end

local function selectNext() selectIndex(state.selectedIndex + 1, 1) end
local function selectPrev() selectIndex(state.selectedIndex - 1, -1) end
local function selectPageForward() selectIndex(state.selectedIndex + 4, 1) end
local function selectPageBack() selectIndex(state.selectedIndex - 4, -1) end

local function shuffle()
  local list = state.wallpapers
  if #list <= 1 then return end
  local nextIdx = math.random(1, #list)
  if nextIdx == state.selectedIndex then nextIdx = (nextIdx % #list) + 1 end
  selectIndex(nextIdx, nextIdx > state.selectedIndex and 1 or -1)
end

local function switchTab(tab: string)
  if state.activeTab == tab then return end
  if state.anim.active then
    if state.anim.mode == "tab" then commitPendingTab() end
    stopCarouselAnimation()
  end
  local direction = (TAB_ORDER[tab] or 0) - (TAB_ORDER[state.activeTab] or 0)
  state.activeTab = tab
  startTabAnimation(tab, direction >= 0 and 1 or -1)
  renderUI()
end

-- Adds one entry (folder or engine file) to state.engineWallpapers. Used by the
-- full scan and by the incremental refresh after Waywallen reindexes.
local function addEngineEntry(dir, name, depth)
  if depth > 3 then return 0 end
  if name == "." or name == ".." or name:match("^%.") then return 0 end
  local added = 0
  local fullPath = dir .. "/" .. name
  local info = noctalia.fileInfo(fullPath)
  if info and info.isDir then
    local scenePkg = fullPath .. "/scene.pkg"
    local projectJson = fullPath .. "/project.json"
    if noctalia.fileExists(scenePkg) or noctalia.fileExists(projectJson) then
      local pkgPath = noctalia.fileExists(scenePkg) and scenePkg or fullPath
      local cached = thumbCache[pkgPath]
      local displayName = name
      if noctalia.fileExists(projectJson) then
        local projContent = noctalia.readFile(projectJson)
        if projContent and noctalia.json and noctalia.json.decode then
          local ok, proj = pcall(noctalia.json.decode, projContent)
          if ok and proj and proj.title then displayName = proj.title end
        end
      end
      table.insert(state.engineWallpapers, {
        name = name, baseName = displayName, path = pkgPath,
        thumbPath = (cached and cached.thumbPath) or "", isVideo = false, isEngine = true,
        ext = "PKG", res = (cached and cached.res) or "WE", fps = (cached and cached.fps) or "Engine",
        colorHex = (cached and cached.colorHex) or "#7C3AED",
      })
      added = 1
    else
      local entries = noctalia.listDir(fullPath)
      if entries and type(entries) == "table" then
        table.sort(entries, function(a, b) return a:lower() < b:lower() end)
        for _, child in ipairs(entries) do added += addEngineEntry(fullPath, child, depth + 1) end
      end
    end
  else
    local ext = getExtension(name)
    if ENGINE_EXTS[ext] then
      local cached = thumbCache[fullPath]
      table.insert(state.engineWallpapers, {
        name = name, baseName = getBaseNameWithoutExt(name), path = fullPath,
        thumbPath = (cached and cached.thumbPath) or "", isVideo = false, isEngine = true,
        ext = "PKG", res = (cached and cached.res) or "WE", fps = (cached and cached.fps) or "Engine",
        colorHex = (cached and cached.colorHex) or "#7C3AED",
      })
      added = 1
    end
  end
  return added
end

local function scanEngineWallpapers()
  state.engineDir = getEngineDir()
  state.engineWallpapers = {}
  state.engineCount = 0
  engineIdsPreloaded = false
  engineIdsReady = false
  engineIdCache = {}
  if not noctalia.fileExists(state.engineDir) then return end

  local entries = noctalia.listDir(state.engineDir)
  if entries and type(entries) == "table" then
    table.sort(entries, function(a, b) return a:lower() < b:lower() end)
    for _, name in ipairs(entries) do addEngineEntry(state.engineDir, name, 0) end
  end
  state.engineCount = #state.engineWallpapers
  engineKnownWorkshopIds = collectEngineWorkshopIds()
  preloadEngineIds()
end

-- Rebuild only the Engine section (used after the daemon reindexes). Only new
-- folders are decoded; re-reading every project.json here would exceed the
-- Luau callback CPU budget when the library is large.
function refreshEngineList()
  if state.anim.active then stopCarouselAnimation() end
  state.engineDir = getEngineDir()
  if state.engineDir and state.engineDir ~= "" and noctalia.fileExists(state.engineDir) then
    local known = {}
    for _, item in ipairs(state.engineWallpapers) do
      known[item.path] = true
      local workshopId = item.path:match("/431960/([^/]+)")
      if workshopId then known[workshopId] = true end
    end

    local entries = noctalia.listDir(state.engineDir)
    if entries and type(entries) == "table" then
      table.sort(entries, function(a, b) return a:lower() < b:lower() end)
      for _, name in ipairs(entries) do
        if name ~= "." and name ~= ".." and not name:match("^%.") then
          local fullPath = state.engineDir .. "/" .. name
          if not known[name] and not known[fullPath] then
            local added = addEngineEntry(state.engineDir, name, 0)
            if added > 0 then
              known[name] = true
              known[fullPath] = true
            end
          end
        end
      end
    end

    -- Drop entries whose files disappeared, without re-reading metadata.
    local kept = {}
    for _, item in ipairs(state.engineWallpapers) do
      if noctalia.fileExists(item.path) then table.insert(kept, item) end
    end
    state.engineWallpapers = kept
    state.engineCount = #kept

    engineIdsPreloaded = false
    engineIdsReady = false
    engineIdCache = {}
    engineKnownWorkshopIds = collectEngineWorkshopIds()
    preloadEngineIds()
  end

  applyFilteredView()
  local total = #state.wallpapers
  if total > 0 then
    for off = -4, 4 do
      local idx = ((state.selectedIndex + off - 1) % total) + 1
      queueThumbnail(state.wallpapers[idx])
    end
  end
  renderUI()
end

-- Ask the Waywallen daemon to reindex when a new workshop folder appears or
-- when an existing folder has no id in its library. No polling: this is called
-- when the Engine tab is opened/shown, or when the user presses F5.
function maybeAutoIndexEngine(force)
  if engineAutoIndexing then return end
  local now = os.time()

  local hasNewFolder = false
  local currentIds = collectEngineWorkshopIds()
  for workshopId in pairs(currentIds) do
    if not engineKnownWorkshopIds[workshopId] then
      hasNewFolder = true
      break
    end
  end

  local hasUnindexedItem = false
  if not hasNewFolder and engineIdsReady then
    for _, item in ipairs(state.engineWallpapers) do
      if not engineIdCache[item.path] then
        hasUnindexedItem = true
        break
      end
    end
  end

  if not force and not hasNewFolder then
    if not hasUnindexedItem then return end
    -- Avoid reindexing in a loop for items the daemon does not support.
    if now - lastEngineRescan < 120 then return end
  end

  engineAutoIndexing = true
  lastEngineRescan = now
  local started = noctalia.runAsync({
    "busctl", "--user", "call",
    WAYWALLEN_DBUS_NAME, WAYWALLEN_DBUS_PATH, WAYWALLEN_DBUS_IFACE,
    "Rescan", "u", "0",
  }, function(result)
    if type(result) == "table" and result.exitCode and result.exitCode ~= 0 then
      engineAutoIndexing = false
      state.statusMessage = "Engine: no se pudo reindexar Waywallen"
      renderUI()
      return
    end
    -- Give the daemon a moment to probe the new files before reading its DB.
    noctalia.runAsync({"bash", "-c", "sleep 1.5"}, function()
      engineAutoIndexing = false
      state.statusMessage = "Wallpaper Engine reindexado"
      refreshEngineList()
    end)
  end, 10000)
  if not started then engineAutoIndexing = false end
end

function scanWallpapers()
  if state.anim.active then stopCarouselAnimation() end
  state.wallpaperDir = getWallpaperDir()
  state.engineMuted = readEngineMuted()
  noctalia.mkdirAll(CACHE_DIR)
  
  state.allWallpapers = {}
  state.imageCount = 0
  state.videoCount = 0
  
  local function scanImagesRecursive(dir, depth)
    if depth > 4 then return end
    local entries = noctalia.listDir(dir)
    if not entries or type(entries) ~= "table" then return end
    table.sort(entries, function(a, b) return a:lower() < b:lower() end)
    for _, name in ipairs(entries) do
      if name ~= "." and name ~= ".." and not name:match("^%.") then
        local fullPath = dir .. "/" .. name
        local info = noctalia.fileInfo(fullPath)
        if info and info.isDir then
          scanImagesRecursive(fullPath, depth + 1)
        else
          local ext = getExtension(name)
          local isImg = IMAGE_EXTS[ext]
          local isVid = VIDEO_EXTS[ext]
          if isImg or isVid then
            local cached = thumbCache[fullPath]
            table.insert(state.allWallpapers, {
              name = name, baseName = getBaseNameWithoutExt(name), path = fullPath,
              thumbPath = (cached and cached.thumbPath) or "", isVideo = isVid, isEngine = false,
              ext = ext:upper(), res = (cached and cached.res) or (name:match("(%d+x%d+)") or ""),
              fps = (cached and cached.fps) or (isVid and "" or "Static"),
              colorHex = (cached and cached.colorHex) or (isVid and "#0A84FF" or "#2DD4BF"),
            })
            if isVid then state.videoCount += 1 else state.imageCount += 1 end
          end
        end
      end
    end
  end

  if noctalia.fileExists(state.wallpaperDir) then
    scanImagesRecursive(state.wallpaperDir, 0)
  end
  
  scanEngineWallpapers()
  applyFilteredView()
  local total = #state.wallpapers
  if total > 0 then
    for off = -4, 4 do
      local idx = ((state.selectedIndex + off - 1) % total) + 1
      queueThumbnail(state.wallpapers[idx])
    end
  end
  renderUI()
end

local function getWrappedItem(idx: number)
  local list = state.wallpapers
  local total = #list
  if total == 0 then return nil, 0 end
  local wrapped = ((idx - 1) % total) + 1
  return list[wrapped], wrapped
end

local function typeAccent(item)
  if item and item.isEngine then return "tertiary" end
  if item and item.isVideo then return "secondary" end
  return "primary"
end

local function typeIcon(item)
  if item and item.isEngine then return "sparkles" end
  if item and item.isVideo then return "player-play-filled" end
  return "photo"
end

local function typeLabel(item)
  if not item then return "—" end
  if item.isEngine then return "Wallpaper Engine" end
  if item.isVideo then return item.fps ~= "" and item.fps or "Vídeo" end
  return "Imagen estática"
end

-- Keep the extracted dominant color as an accent when it is bright enough;
-- very dark previews (common for Engine scenes) get the palette accent instead.
local function heroBorderColor(item, accent)
  local hex = item and item.colorHex or ""
  local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
  if r then
    local luminance = tonumber(r, 16) * 0.299 + tonumber(g, 16) * 0.587 + tonumber(b, 16) * 0.114
    if luminance >= 72 then return hex end
  end
  return accent .. "/0.82"
end

local function keycap(text, key, accent, active)
  return ui.row({
    key = key,
    fill = active and (accent .. "/0.16") or "on_surface/0.08",
    radius = 4,
    border = active and (accent .. "/0.42") or "outline/0.32",
    borderWidth = 1,
    paddingH = 5,
    paddingV = 1,
    align = "center",
  }, {
    ui.label({
      text = text,
      fontSize = 8,
      fontWeight = "bold",
      color = active and accent or "on_surface/0.70",
    }),
  })
end

local function shortcutRow(keys, label, key)
  return ui.row({ key = key, gap = 7, align = "center" }, {
    keycap(keys, key .. "_cap", "primary", false),
    ui.label({
      text = label,
      fontSize = 9,
      color = "on_surface/0.70",
      flexGrow = 1,
      maxLines = 1,
      textAlign = "end",
    }),
  })
end

local function sectionLabel(text, key)
  return ui.label({
    key = key,
    text = text,
    fontSize = 8,
    fontWeight = "bold",
    color = "on_surface/0.40",
  })
end

local function buildSidebar()
  local children = {
    ui.row({ key = "side_title", gap = 5, align = "center" }, {
      ui.glyph({ name = "keyboard", size = 11, color = "primary" }),
      ui.label({ text = "ATAJOS", fontSize = 10, fontWeight = "bold", color = "on_surface/0.62" }),
    }),
    sectionLabel("NAVEGAR", "side_header_nav"),
    shortcutRow("J / K", "Navegar", "side_nav"),
    shortcutRow("H / L", "Saltar 4", "side_jump"),
    shortcutRow("R", "Aleatorio", "side_shuffle"),
    ui.box({ key = "side_sep_1", height = 1, radius = 0.5, fill = "outline/0.16" }),
    sectionLabel("ACCIONES", "side_header_actions"),
    shortcutRow("ENTER", "Aplicar", "side_apply"),
    shortcutRow("SPACE", "Mantener abierto", "side_apply_keep"),
    shortcutRow("ESC / Q", "Cerrar", "side_close"),
    ui.box({ key = "side_sep_2", height = 1, radius = 0.5, fill = "outline/0.16" }),
    sectionLabel("VISTAS", "side_header_views"),
    shortcutRow("1 2 3", "Pestañas", "side_tabs"),
    shortcutRow("F5", "Actualizar", "side_refresh"),
  }
  return ui.column({
    key = "side_bar",
    width = 150,
    height = math.max(state.cardHeight, 220),
    fill = "surface_variant/0.32",
    radius = 12,
    border = "outline/0.24",
    borderWidth = 1,
    padding = 10,
    gap = 3,
    align = "stretch",
    justify = "center",
  }, children)
end

local function buildStripCard(item, idx, keyPrefix, offset, animProgress, animDirection, animStrength)
  local depth = math.abs(offset)
  local widths = { 70, 58, 48, 35 }
  local shrink = { 0, 10, 22, 34 }
  local opacities = { 0.94, 0.82, 0.70, 0.56 }
  local width = widths[depth] or 35
  local strength = animStrength or 0.30
  if animProgress and animProgress < 1 and animDirection ~= 0 and strength > 0 then
    local extra = animDirection * (1 - animProgress) * strength
    width = math.max(28, math.floor(width * (1 + (offset < 0 and extra or -extra)) + 0.5))
  end
  local height = math.max(96, state.cardHeight - (shrink[depth] or 0))
  local accent = typeAccent(item)
  local imgPath = safeImagePath(item)
  local innerWidth = width - 4
  local innerHeight = height - 4
  local content

  if imgPath ~= "" then
    content = ui.image({
      key = keyPrefix .. offset .. "_img_" .. idx,
      path = imgPath,
      width = innerWidth,
      height = innerHeight,
      radius = 7,
      fit = "cover",
    })
  else
    content = ui.column({
      key = keyPrefix .. offset .. "_placeholder_" .. idx,
      width = innerWidth,
      height = innerHeight,
      fill = "surface_variant/0.38",
      radius = 7,
      align = "center",
      justify = "center",
    }, {
      ui.glyph({ name = typeIcon(item), size = depth <= 2 and 18 or 11, color = accent .. "/0.55" }),
    })
  end

  return ui.column({
    key = keyPrefix .. offset .. "_" .. idx,
    width = width,
    height = height,
    fill = "surface/0.52",
    radius = 9,
    border = accent .. "/0.30",
    borderWidth = 1,
    padding = 2,
    align = "center",
    justify = "center",
    opacity = opacities[depth] or 0.5,
    onClick = function() selectIndex(idx, offset < 0 and -1 or 1) end,
  }, { content })
end

local function buildHeroCard(item, heroScale)
  local accent = typeAccent(item)
  local imgPath = safeImagePath(item)
  local scale = heroScale or 1
  local heroWidth = math.floor(416 * scale + 0.5)
  local heroHeight = math.floor(state.cardHeight * (1 - (1 - scale) * 0.5) + 0.5)
  local imageWidth = heroWidth - 8
  local imageHeight = math.max(60, heroHeight - 34)
  local resText = item.res
  if resText == "" or resText == "WE" then resText = item.ext ~= "" and item.ext or "—" end

  local header = ui.row({
    key = "hero_header",
    width = imageWidth,
    height = 22,
    align = "center",
    justify = "space_between",
  }, {
    ui.row({
      key = "hero_res",
      fill = "surface_variant/0.42",
      radius = 6,
      paddingH = 8,
      paddingV = 3,
      align = "center",
      gap = 5,
    }, {
      ui.glyph({ name = "aspect-ratio", size = 11, color = accent }),
      ui.label({ text = resText, fontSize = 10, fontWeight = "bold", color = "on_surface/0.88" }),
    }),
    ui.row({
      key = "hero_type",
      fill = accent .. "/0.14",
      radius = 6,
      paddingH = 8,
      paddingV = 3,
      align = "center",
      gap = 5,
    }, {
      ui.glyph({ name = typeIcon(item), size = 11, color = accent }),
      ui.label({ text = typeLabel(item), fontSize = 10, fontWeight = "bold", color = accent }),
    }),
  })

  local image
  if imgPath ~= "" then
    image = ui.image({
      key = "hero_img_" .. state.selectedIndex,
      path = imgPath,
      width = imageWidth,
      height = imageHeight,
      radius = 9,
      fit = "cover",
    })
  else
    local message = item.isEngine and "Cargando preview del Engine…" or "Generando preview…"
    image = ui.column({
      key = "hero_placeholder_" .. state.selectedIndex,
      width = imageWidth,
      height = imageHeight,
      fill = "surface_variant/0.38",
      radius = 9,
      align = "center",
      justify = "center",
      gap = 6,
    }, {
      ui.glyph({ name = typeIcon(item), size = 40, color = accent .. "/0.55" }),
      ui.label({ text = message, fontSize = 11, color = "on_surface/0.55" }),
    })
  end

  local borderColor = heroBorderColor(item, accent)
  return ui.column({
    key = "hero_card_" .. state.selectedIndex,
    width = heroWidth,
    height = heroHeight,
    fill = "surface/0.72",
    radius = 14,
    border = borderColor,
    borderWidth = 2,
    padding = 4,
    gap = 4,
    align = "center",
    justify = "center",
    onClick = function() applyWallpaper(item) end,
  }, { header, image })
end

function renderUI()
  if not panel or not panel.render then return end
  local list = state.wallpapers
  local total = #list
  local currentItem = list[state.selectedIndex]
  local currentAccent = currentItem and heroBorderColor(currentItem, typeAccent(currentItem)) or "primary"
  local animProgress = 1
  local animDirection = 0
  local animStrength = 0
  local deckOpacity = 1
  local metaOpacity = 1
  local heroScale = 1
  if state.anim.active then
    local t = math.min(state.anim.elapsed / state.anim.duration, 1)
    if state.anim.mode == "tab" then
      if t < TAB_SPLIT then
        local p = t / TAB_SPLIT
        local e = p * p * (3 - 2 * p)
        deckOpacity = 1 - 0.92 * e
        metaOpacity = 1 - 0.85 * e
        heroScale = 1 - 0.04 * e
        animProgress = 1 - e
        animDirection = -(state.anim.direction or 0)
        animStrength = 0.14
      else
        local p = (t - TAB_SPLIT) / (1 - TAB_SPLIT)
        local e = 1 - (1 - p) ^ 3
        deckOpacity = 0.08 + 0.92 * e
        metaOpacity = 0.15 + 0.85 * e
        heroScale = 0.96 + 0.04 * e
        animProgress = e
        animDirection = state.anim.direction or 0
        animStrength = 0.14
      end
    else
      local e = 1 - (1 - t) ^ 3
      deckOpacity = 0.72 + 0.28 * e
      animProgress = e
      animDirection = state.anim.direction or 0
      animStrength = 0.30
    end
  end

  local indexChip = ui.row({
    key = "index_chip",
    fill = "primary/0.12",
    radius = 9,
    paddingH = 10,
    paddingV = 5,
    align = "center",
    gap = 6,
    opacity = metaOpacity,
  }, {
    ui.box({ key = "index_dot", width = 6, height = 6, radius = 3, fill = "primary" }),
    ui.label({
      text = string.format("%02d / %02d", total > 0 and state.selectedIndex or 0, total),
      fontWeight = "bold",
      fontSize = 12,
      color = "on_surface",
    }),
  })
  local topLeft = ui.row({ key = "top_left", flexGrow = 1, align = "center", justify = "start" }, { indexChip })

  local function tabBtn(label, icon, accent, tabKey, count, hotkey)
    local isActive = state.activeTab == tabKey
    local props = {
      key = "tab_" .. tabKey,
      fill = isActive and (accent .. "/0.16") or "surface_variant/0.18",
      radius = 9,
      paddingH = 10,
      paddingV = 5,
      align = "center",
      gap = 6,
      onClick = function() switchTab(tabKey) end,
    }
    if isActive then
      props.border = accent .. "/0.50"
      props.borderWidth = 1
    end
    return ui.row(props, {
      ui.glyph({ name = icon, size = 13, color = isActive and accent or "on_surface/0.55" }),
      ui.label({ text = label, fontSize = 11, fontWeight = "bold", color = isActive and "on_surface" or "on_surface/0.68" }),
      ui.label({ text = tostring(count), fontSize = 10, fontWeight = "bold", color = isActive and accent or "on_surface/0.42" }),
      keycap(hotkey, "tabcap_" .. tabKey, accent, isActive),
    })
  end

  local tabs = ui.row({
    key = "tabs",
    fill = "surface_variant/0.30",
    radius = 13,
    padding = 3,
    gap = 4,
    align = "center",
    justify = "center",
  }, {
    tabBtn("Imágenes", "photo", "primary", "images", state.imageCount, "1"),
    tabBtn("Vídeos", "player-play-filled", "secondary", "videos", state.videoCount, "2"),
    tabBtn("Engine", "sparkles", "tertiary", "engine", state.engineCount, "3"),
  })

  local rightControls = {}
  if state.activeTab == "engine" then
    table.insert(rightControls, ui.button({
      key = "btn_engine_mute",
      glyph = state.engineMuted and "volume-off" or "volume",
      variant = "ghost",
      controlSize = "sm",
      tooltip = state.engineMuted and "Activar sonido de Engine" or "Silenciar sonido de Engine",
      onClick = toggleEngineMute,
    }))
  end
  table.insert(rightControls, ui.button({ key = "btn_refresh", glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = "Actualizar (F5)", onClick = function() scanWallpapers() end }))
  table.insert(rightControls, ui.button({ key = "btn_shuffle", text = "Shuffle", glyph = "arrows-shuffle", variant = "ghost", controlSize = "sm", tooltip = "Aleatorio (R)", onClick = shuffle }))
  table.insert(rightControls, ui.button({ key = "btn_close_panel", glyph = "x", variant = "ghost", controlSize = "sm", tooltip = "Cerrar (Esc)", onClick = function() if panel and panel.close then panel.close() end end }))
  local actions = ui.row({
    key = "top_actions",
    fill = "surface_variant/0.30",
    radius = 11,
    padding = 3,
    align = "center",
    gap = 2,
  }, rightControls)
  local topRight = ui.row({ key = "top_right", flexGrow = 1, align = "center", justify = "end" }, { actions })

  local topBar = ui.row({
    key = "top_bar",
    width = 1062,
    height = 48,
    gap = 8,
    paddingH = 10,
    paddingV = 5,
    align = "center",
    fill = "surface/0.72",
    radius = 14,
    border = "outline/0.24",
    borderWidth = 1,
  }, { topLeft, tabs, topRight })

  local carouselCards = {}
  if total > 0 then
    for _, offset in ipairs({ -4, -3, -2, -1 }) do
      local item, idx = getWrappedItem(state.selectedIndex + offset)
      if item then table.insert(carouselCards, buildStripCard(item, idx, "strip_l_", offset, animProgress, animDirection, animStrength)) end
    end
    if currentItem then table.insert(carouselCards, buildHeroCard(currentItem, heroScale)) end
    for _, offset in ipairs({ 1, 2, 3, 4 }) do
      local item, idx = getWrappedItem(state.selectedIndex + offset)
      if item then table.insert(carouselCards, buildStripCard(item, idx, "strip_r_", offset, animProgress, animDirection, animStrength)) end
    end
  else
    local emptyMsg = "No se encontraron wallpapers"
    local emptyIcon = "folder"
    local emptyAccent = "primary"
    if state.activeTab == "images" then emptyMsg = "No hay wallpapers estáticos en esta carpeta"
    elseif state.activeTab == "videos" then emptyMsg = "No hay wallpapers animados en esta carpeta"
    elseif state.activeTab == "engine" then
      emptyMsg = "No se encontraron .pkg de Wallpaper Engine"
      emptyIcon = "sparkles"
      emptyAccent = "tertiary"
    end
    local emptyDir = state.activeTab == "engine" and state.engineDir or state.wallpaperDir
    table.insert(carouselCards, ui.column({
      key = "empty_deck",
      gap = 7,
      align = "center",
      justify = "center",
      height = math.max(state.cardHeight, 220),
      width = 902,
      fill = "surface/0.42",
      radius = 14,
      border = "outline/0.22",
      borderWidth = 1,
    }, {
      ui.glyph({ name = emptyIcon, size = 44, color = emptyAccent .. "/0.65" }),
      ui.label({ text = emptyMsg, fontWeight = "bold", fontSize = 14, color = "on_surface/0.85" }),
      ui.label({ text = emptyDir, fontSize = 10, color = "on_surface/0.45", maxWidth = 700, maxLines = 2, textAlign = "center" }),
      ui.row({ key = "empty_hint", gap = 6, align = "center" }, {
        keycap("F5", "empty_refresh_cap", "primary", false),
        ui.label({ text = "Actualizar lista", fontSize = 9, color = "on_surface/0.50" }),
      }),
    }))
  end

  local carouselDeck = ui.row({
    key = "card_deck",
    width = 902,
    height = math.max(state.cardHeight, 220),
    gap = 8,
    align = "center",
    justify = "center",
    opacity = deckOpacity,
  }, carouselCards)

  local mainRow = ui.row({
    key = "main_row",
    width = 1062,
    height = math.max(state.cardHeight, 220),
    gap = 10,
    align = "center",
  }, { buildSidebar(), carouselDeck })

  local footerChildren = {}
  local pendingThumbs = thumbActive + #thumbQueue
  if state.statusMessage ~= "" then
    table.insert(footerChildren, ui.row({
      key = "footer_status",
      fill = "primary/0.10",
      radius = 7,
      paddingH = 8,
      paddingV = 3,
      align = "center",
      gap = 5,
    }, {
      ui.box({ key = "footer_status_dot", width = 5, height = 5, radius = 2.5, fill = "primary" }),
      ui.label({ text = state.statusMessage, fontSize = 10, color = "on_surface/0.80", maxWidth = 620, maxLines = 1 }),
    }))
  elseif pendingThumbs > 0 then
    table.insert(footerChildren, ui.row({ key = "footer_loading", gap = 5, align = "center" }, {
      ui.glyph({ name = "loader-2", size = 11, color = "primary" }),
      ui.label({ text = string.format("Generando miniaturas… %d en cola", pendingThumbs), fontSize = 10, color = "on_surface/0.62" }),
    }))
  elseif currentItem then
    table.insert(footerChildren, ui.row({ key = "footer_current", gap = 6, align = "center" }, {
      ui.glyph({ name = typeIcon(currentItem), size = 11, color = typeAccent(currentItem) }),
      ui.label({ text = currentItem.baseName or currentItem.name, fontSize = 10, color = "on_surface/0.62", maxWidth = 620, maxLines = 1 }),
    }))
  else
    table.insert(footerChildren, ui.label({ text = "Wallcards", fontSize = 10, color = "on_surface/0.45" }))
  end
  table.insert(footerChildren, ui.label({
    key = "footer_keys",
    text = "J/K Navegar   ·   Enter Aplicar   ·   R Aleatorio   ·   Esc Cerrar",
    fontSize = 10,
    color = "on_surface/0.45",
  }))
  local footerBar = ui.row({
    key = "footer_bar",
    width = 1062,
    height = 20,
    gap = 8,
    paddingH = 2,
    align = "center",
    justify = "space_between",
    opacity = metaOpacity,
  }, footerChildren)

  panel.render(ui.column({
    key = "wallcards_root",
    width = 1090,
    padding = 14,
    gap = 10,
    align = "center",
    fill = "surface/0.58",
    radius = 22,
    border = "outline/0.26",
    borderWidth = 1,
  }, { topBar, mainRow, footerBar }))
end

function onKey(chord: string, pressed: boolean)
  if not pressed then return end
  local key = chord:lower()
  if key ~= "escape" and key ~= "q"
    and state.anim.active and state.anim.mode == "tab" and not state.anim.tabCommitted then
    commitPendingTab()
    stopCarouselAnimation()
  end
  if key == "escape" or key == "q" then if panel and panel.close then panel.close() end
  elseif key == "j" or key == "right" or key == "down" then selectNext()
  elseif key == "k" or key == "left" or key == "up" then selectPrev()
  elseif key == "h" then selectPageBack()
  elseif key == "l" then selectPageForward()
  elseif key == "r" then shuffle()
  elseif key == "f5" then scanWallpapers(); maybeAutoIndexEngine(true)
  elseif key == "1" then switchTab("images")
  elseif key == "2" then switchTab("videos")
  elseif key == "3" then switchTab("engine")
  elseif key == "return" or key == "space" then
    local list = state.wallpapers
    if list[state.selectedIndex] then applyWallpaper(list[state.selectedIndex]) end
  end
end

function onOpen(_context)
  if state.anim.active then stopCarouselAnimation() end
  state.engineMuted = readEngineMuted()
  if state.activeTab == "engine" then maybeAutoIndexEngine() end
  if #state.wallpapers > 1 then
    startCarouselAnimation(0)
    renderUI()
  end
end

function onFrameTick(deltaMs)
  if not state.anim.active then return end
  local dt = tonumber(deltaMs) or 16
  state.anim.elapsed += math.max(1, math.min(dt, 64))
  if state.anim.mode == "tab" and not state.anim.tabCommitted
    and state.anim.elapsed >= state.anim.duration * TAB_SPLIT then
    commitPendingTab()
  end
  if state.anim.elapsed >= state.anim.duration then
    stopCarouselAnimation()
  end
  renderUI()
end

function onTick() end
function update() end

function onConfigChanged()
  state.cardHeight = noctalia.getConfig("card_height") or 230
  scanWallpapers()
end

function init()
  state.cardHeight = noctalia.getConfig("card_height") or 230
  loadThumbnailIndex()
  scanWallpapers()
end

init()
