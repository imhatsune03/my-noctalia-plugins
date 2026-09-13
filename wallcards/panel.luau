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
}

local thumbCache = {}
local thumbPending = {}
local thumbQueue = {}
local thumbActive = 0
local indexDirty = false
local tickCount = 0

local renderUI
local pumpThumbQueue
local scanWallpapers
local applyFilteredView

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
          cmd = "bash -c " .. shellQuote(bash_cmd)
        elseif item.isVideo then
          cmd = "ffmpeg -y -ss 00:00:01 -i " .. shellQuote(path) .. " -vframes 1 -vf 'scale=480:-1' -q:v 3 " .. shellQuote(dest) .. " 2>/dev/null && ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=s=x:p=0 " .. shellQuote(path) .. " 2>/dev/null && magick " .. shellQuote(dest) .. " -resize 1x1 -format ' #%[hex:u.p{0,0}]' info: 2>/dev/null || true"
        else
          cmd = "magick " .. shellQuote(path) .. " -thumbnail 480x270^ -gravity center -extent 480x270 -quality 82 " .. shellQuote(dest) .. " 2>/dev/null && magick identify -format '%wx%h' " .. shellQuote(path) .. " 2>/dev/null && magick " .. shellQuote(dest) .. " -resize 1x1 -format ' #%[hex:u.p{0,0}]' info: 2>/dev/null || true"
        end
        noctalia.runAsync(cmd, function(result)
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
  if not thumbPending[item.path] then
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
  if item.thumbPath ~= "" and noctalia.fileExists(item.thumbPath) then
    noctalia.setWallpaper(item.thumbPath)
  end
  clearLastEnginePath()
  saveLastVideoPath(item.path)
  noctalia.runAsync("pkill -9 gslapper 2>/dev/null || true; pkill -9 -f waywallen-layer-shell 2>/dev/null || true", function()
    local cmd = "gslapper -f -o 'no-audio loop' '*' " .. shellQuote(item.path)
    noctalia.runAsync(cmd, function()
      noctalia.runAsync("sleep 0.4", function() noctalia.setWallpaperEnabled("", false) end)
    end, 5000)
    state.statusMessage = "Vídeo aplicado: " .. item.name
    renderUI()
  end, 2000)
end

local function applyStaticWallpaper(item)
  if not item then return end
  clearLastVideoPath()
  clearLastEnginePath()
  noctalia.runAsync("pkill -9 gslapper 2>/dev/null || true; pkill -9 -f waywallen-layer-shell 2>/dev/null || true", function()
    noctalia.setWallpaperEnabled("", true)
    noctalia.setWallpaper(item.path)
    state.statusMessage = "Wallpaper aplicado: " .. item.name
    renderUI()
  end, 2000)
end

local function applyEngineWallpaper(item)
  if not item then return end
  if item.thumbPath ~= "" and noctalia.fileExists(item.thumbPath) then
    noctalia.setWallpaper(item.thumbPath)
  end
  clearLastVideoPath()
  saveLastEnginePath(item.path)
  noctalia.runAsync("pkill -9 gslapper 2>/dev/null || true", function()
    local bin = getWaywallenBin()
    -- Apply via waywallen DBus using sqlite3 lookup
    local db_cmd = [[
      pkg_path=]] .. shellQuote(item.path) .. [[
      rel_path=$(echo "$pkg_path" | grep -o "431960/.*" || true)
      if [ -n "$rel_path" ]; then
        wp_id=$(sqlite3 ~/.var/app/org.waywallen.waywallen/data/waywallen/waywallen-v2.db "SELECT id FROM item WHERE path LIKE '%$rel_path%' LIMIT 1" || true)
        if [ -n "$wp_id" ]; then
          busctl --user call org.waywallen.waywallen.Daemon /org/waywallen/waywallen/Daemon org.waywallen.waywallen.Daemon1 ApplyById s "$wp_id" || true
        fi
      fi
      # Ensure layer-shell client is running
      env > /tmp/noctalia_env.log; pidof waywallen-layer-shell || ]] .. shellQuote(bin) .. [[ >/tmp/waywallen.log 2>&1 &
    ]]
    noctalia.runAsync(db_cmd, function()
      noctalia.runAsync("sleep 0.4", function() noctalia.setWallpaperEnabled("", false) end)
    end, 5000)
    state.statusMessage = "Engine aplicado: " .. item.name
    renderUI()
  end, 2000)
end

local function applyWallpaper(item)
  if not item then return end
  if item.isEngine then applyEngineWallpaper(item)
  elseif item.isVideo then applyVideoWallpaper(item)
  else applyStaticWallpaper(item) end
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

local function selectIndex(newIndex: number)
  local list = state.wallpapers
  if #list == 0 then return end
  if newIndex > #list then newIndex = 1
  elseif newIndex < 1 then newIndex = #list end
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
  renderUI()
end

local function selectNext() selectIndex(state.selectedIndex + 1) end
local function selectPrev() selectIndex(state.selectedIndex - 1) end
local function selectPageForward() selectIndex(state.selectedIndex + 4) end
local function selectPageBack() selectIndex(state.selectedIndex - 4) end

local function shuffle()
  local list = state.wallpapers
  if #list <= 1 then return end
  local nextIdx = math.random(1, #list)
  if nextIdx == state.selectedIndex then nextIdx = (nextIdx % #list) + 1 end
  selectIndex(nextIdx)
end

local function switchTab(tab: string)
  if state.activeTab == tab then return end
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
  renderUI()
end

local function scanEngineWallpapers()
  state.engineDir = getEngineDir()
  state.engineWallpapers = {}
  state.engineCount = 0
  if not noctalia.fileExists(state.engineDir) then return end
  local entries = noctalia.listDir(state.engineDir)
  if not entries or type(entries) ~= "table" then return end
  table.sort(entries, function(a, b) return a:lower() < b:lower() end)
  for _, name in ipairs(entries) do
    local ext = getExtension(name)
    local fullPath = state.engineDir .. "/" .. name
    if ENGINE_EXTS[ext] then
      local cached = thumbCache[fullPath]
      table.insert(state.engineWallpapers, {
        name = name, baseName = getBaseNameWithoutExt(name), path = fullPath,
        thumbPath = (cached and cached.thumbPath) or "", isVideo = false, isEngine = true,
        ext = "PKG", res = (cached and cached.res) or "WE", fps = (cached and cached.fps) or "Engine",
        colorHex = (cached and cached.colorHex) or "#7C3AED",
      })
      state.engineCount += 1
    else
      local scenePkg = fullPath .. "/scene.pkg"
      local projectJson = fullPath .. "/project.json"
      local pkgPath = nil
      if noctalia.fileExists(scenePkg) then pkgPath = scenePkg
      elseif noctalia.fileExists(projectJson) then pkgPath = fullPath end
      if pkgPath then
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
        state.engineCount += 1
      end
    end
  end
end

function scanWallpapers()
  state.wallpaperDir = getWallpaperDir()
  noctalia.mkdirAll(CACHE_DIR)
  local entries = noctalia.listDir(state.wallpaperDir)
  if not entries or type(entries) ~= "table" then
    state.allWallpapers = {}; state.imageCount = 0; state.videoCount = 0
  else
    table.sort(entries, function(a, b) return a:lower() < b:lower() end)
    state.allWallpapers = {}; state.imageCount = 0; state.videoCount = 0
    for _, name in ipairs(entries) do
      local ext = getExtension(name)
      local isImg = IMAGE_EXTS[ext]
      local isVid = VIDEO_EXTS[ext]
      if isImg or isVid then
        local path = state.wallpaperDir .. "/" .. name
        local cached = thumbCache[path]
        table.insert(state.allWallpapers, {
          name = name, baseName = getBaseNameWithoutExt(name), path = path,
          thumbPath = (cached and cached.thumbPath) or "", isVideo = isVid, isEngine = false,
          ext = ext:upper(), res = (cached and cached.res) or (name:match("(%d+x%d+)") or ""),
          fps = (cached and cached.fps) or (isVid and "" or "Static"),
          colorHex = (cached and cached.colorHex) or (isVid and "#0A84FF" or "#2DD4BF"),
        })
        if isVid then state.videoCount += 1 else state.imageCount += 1 end
      end
    end
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

local function buildStripCard(item, idx, keyPrefix, offset)
  local imgPath = safeImagePath(item)
  local typeColor = item.isEngine and "#7C3AED" or (item.isVideo and "#60A5FA" or "#34D399")
  local typeIcon = item.isEngine and "sparkles" or (item.isVideo and "player-play-filled" or "photo")
  local fpsLabel = item.isEngine and "WE" or ((item.fps ~= "" and item.fps:match("^(%d+)")) or (item.isVideo and "V" or "S"))
  local stripContent = {}
  table.insert(stripContent, ui.row({ fill = "#18181B", radius = 6, paddingH = 3, paddingV = 2, align = "center", justify = "space_between", width = 54 }, {
    ui.label({ text = (item.res ~= "" and item.res:match("^(%d+)")) or item.ext, fontSize = 8, fontWeight = "bold", color = "#A1A1AA" }),
    ui.label({ text = fpsLabel, fontSize = 8, fontWeight = "bold", color = typeColor }),
  }))
  if imgPath ~= "" then
    table.insert(stripContent, ui.image({ key = keyPrefix .. offset .. "_" .. idx, path = imgPath, width = 52, height = state.cardHeight - 26, radius = 6, fit = "cover" }))
  else
    table.insert(stripContent, ui.column({ width = 52, height = state.cardHeight - 26, fill = "#18181B", radius = 6, align = "center", justify = "center" }, {
      ui.glyph({ name = typeIcon, size = 18, color = "#3F3F46" }),
    }))
  end
  return ui.column({ gap = 4, align = "center", width = 56, height = state.cardHeight, radius = 8, border = "#27272A", borderWidth = 1, opacity = 0.85, onClick = function() selectIndex(idx) end }, stripContent)
end

function renderUI()
  if not panel or not panel.render then return end
  local list = state.wallpapers
  local total = #list
  local currentItem = list[state.selectedIndex]

  local topChildren = {}
  table.insert(topChildren, ui.row({ fill = "#141416", radius = 14, paddingH = 14, paddingV = 6, align = "center" }, {
    ui.label({ text = string.format("%d  /  %d", total > 0 and state.selectedIndex or 0, total), fontWeight = "bold", fontSize = 13, color = "#2DD4BF" }),
  }))
  table.insert(topChildren, ui.spacer())

  local function tabBtn(label, icon, iconColor, tabKey, count)
    local isActive = state.activeTab == tabKey
    local btnProps = { fill = isActive and "#27272A" or "#141416", radius = 12, paddingH = 12, paddingV = 5, align = "center", gap = 5, onClick = function() switchTab(tabKey) end }
    if isActive then btnProps.border = iconColor; btnProps.borderWidth = 1 end
    return ui.row(btnProps, {
      ui.glyph({ name = icon, size = 12, color = isActive and iconColor or "#71717A" }),
      ui.label({ text = string.format("%s (%d)", label, count), fontSize = 11, fontWeight = "bold", color = isActive and "#FAFAFA" or "#A1A1AA" }),
    })
  end

  table.insert(topChildren, ui.row({ fill = "#141416", radius = 16, paddingH = 6, paddingV = 4, align = "center", gap = 4 }, {
    tabBtn("Imágenes", "photo", "#34D399", "images", state.imageCount),
    tabBtn("Vídeos", "player-play-filled", "#60A5FA", "videos", state.videoCount),
    tabBtn("Engine", "sparkles", "#7C3AED", "engine", state.engineCount),
  }))

  table.insert(topChildren, ui.spacer())
  table.insert(topChildren, ui.row({ fill = "#141416", radius = 16, paddingH = 10, paddingV = 4, align = "center", gap = 8 }, {
    ui.button({ key = "btn_refresh", glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = "Actualizar (F5)", onClick = function() scanWallpapers() end }),
    ui.button({ key = "btn_shuffle", text = "Shuffle", glyph = "arrows-shuffle", variant = "ghost", controlSize = "sm", tooltip = "Shuffle (R)", onClick = shuffle }),
    ui.button({ key = "btn_close_panel", glyph = "x", variant = "ghost", controlSize = "sm", tooltip = "Close (Esc)", onClick = function() if panel and panel.close then panel.close() end end }),
  }))

  local topBar = ui.row({ gap = 12, align = "center", justify = "space_between", width = 1060 }, topChildren)

  local carouselCards = {}
  if total > 0 then
    for _, offset in ipairs({ -4, -3, -2, -1 }) do
      local item, idx = getWrappedItem(state.selectedIndex + offset)
      if item then table.insert(carouselCards, buildStripCard(item, idx, "strip_l_", offset)) end
    end
    if currentItem then
      local heroImgPath = safeImagePath(currentItem)
      local heroChildren = {}
      local heroTypeColor = currentItem.isEngine and "#7C3AED" or (currentItem.isVideo and "#60A5FA" or "#34D399")
      local heroTypeIcon = currentItem.isEngine and "sparkles" or (currentItem.isVideo and "player-play-filled" or "photo")
      local heroFpsLabel = currentItem.isEngine and "Engine" or ((currentItem.fps ~= "" and currentItem.fps) or "—")

      table.insert(heroChildren, ui.row({ gap = 8, align = "center", justify = "space_between", width = 500 }, {
        ui.row({ fill = "#141416", radius = 10, paddingH = 12, paddingV = 4, align = "center" }, {
          ui.label({ text = (currentItem.res ~= "" and currentItem.res) or "—", fontWeight = "bold", fontSize = 11, color = "#FFFFFF" }),
        }),
        currentItem.isEngine and ui.row({ fill = "#1E0A3C", radius = 10, paddingH = 10, paddingV = 4, align = "center", gap = 5 }, {
          ui.glyph({ name = "sparkles", size = 11, color = "#7C3AED" }),
          ui.label({ text = "Wallpaper Engine", fontSize = 11, fontWeight = "bold", color = "#A78BFA" }),
        }) or ui.row({ fill = "#141416", radius = 10, paddingH = 10, paddingV = 4, align = "center", gap = 5 }, {
          ui.glyph({ name = heroTypeIcon, size = 11, color = heroTypeColor }),
          ui.label({ text = heroFpsLabel, fontSize = 11, fontWeight = "bold", color = "#E4E4E7" }),
        }),
      }))

      if heroImgPath ~= "" then
        table.insert(heroChildren, ui.image({ key = "hero_img_" .. state.selectedIndex, path = heroImgPath, width = 500, height = state.cardHeight - 38, radius = 8, fit = "cover" }))
      else
        local pIcon = currentItem.isEngine and "sparkles" or (currentItem.isVideo and "player-play-filled" or "photo")
        local pMsg = currentItem.isEngine and "Cargando preview del Engine..." or "Generando preview..."
        table.insert(heroChildren, ui.column({ width = 500, height = state.cardHeight - 38, fill = currentItem.isEngine and "#0F0620" or "#18181B", radius = 8, align = "center", justify = "center" }, {
          ui.glyph({ name = pIcon, size = 42, color = currentItem.isEngine and "#4C1D95" or "#3F3F46" }),
          ui.label({ text = pMsg, fontSize = 11, color = currentItem.isEngine and "#6D28D9" or "#52525B" }),
        }))
      end

      local heroBorderColor = currentItem.isEngine and "#7C3AED" or (currentItem.colorHex or "#2DD4BF")
      table.insert(carouselCards, ui.column({ gap = 6, align = "center", width = 510, height = state.cardHeight, radius = 12, border = heroBorderColor, borderWidth = 2, padding = 4, onClick = function() applyWallpaper(currentItem) end }, heroChildren))
    end
    for _, offset in ipairs({ 1, 2, 3, 4 }) do
      local item, idx = getWrappedItem(state.selectedIndex + offset)
      if item then table.insert(carouselCards, buildStripCard(item, idx, "strip_r_", offset)) end
    end
  else
    local emptyMsg = "No se encontraron wallpapers"
    local emptyIcon = "folder"
    local emptyColor = "#71717A"
    if state.activeTab == "images" then emptyMsg = "No hay wallpapers estáticos en esta carpeta"
    elseif state.activeTab == "videos" then emptyMsg = "No hay wallpapers animados en esta carpeta"
    elseif state.activeTab == "engine" then
      emptyMsg = "No se encontraron .pkg de Wallpaper Engine"
      emptyIcon = "sparkles"; emptyColor = "#4C1D95"
    end
    local emptyDir = state.activeTab == "engine" and state.engineDir or state.wallpaperDir
    table.insert(carouselCards, ui.column({ gap = 8, align = "center", justify = "center", height = state.cardHeight, width = 800 }, {
      ui.glyph({ name = emptyIcon, size = 42, color = emptyColor }),
      ui.label({ text = emptyMsg, fontWeight = "bold", fontSize = 14 }),
      ui.label({ text = emptyDir, fontSize = 11, color = "#A1A1AA" }),
    }))
  end

  local carouselDeck = ui.row({ gap = 8, align = "center", justify = "center", width = 1060 }, carouselCards)

  local footerChildren = {}
  if state.statusMessage ~= "" then
    table.insert(footerChildren, ui.label({ text = state.statusMessage, fontSize = 11, color = "#2DD4BF" }))
  else
    table.insert(footerChildren, ui.spacer())
  end
  table.insert(footerChildren, ui.label({
    text = "[Enter/Space] Aplicar  •  [←→ J K] Navegar  •  [H/L] Saltar  •  [R] Aleatorio  •  [F5] Actualizar  •  [1] Imágenes  [2] Vídeos  [3] Engine  •  [Esc/Q] Salir",
    fontSize = 10, color = "#71717A",
  }))
  local footerBar = ui.row({ gap = 8, align = "center", justify = "space_between", width = 1060 }, footerChildren)

  panel.render(ui.column({ gap = 14, padding = 16, fill = true, align = "center", justify = "center" }, { topBar, carouselDeck, footerBar }))
end

function onKey(chord: string, pressed: boolean)
  if not pressed then return end
  local key = chord:lower()
  if key == "escape" or key == "q" then if panel and panel.close then panel.close() end
  elseif key == "j" or key == "right" or key == "down" then selectNext()
  elseif key == "k" or key == "left" or key == "up" then selectPrev()
  elseif key == "h" then selectPageBack()
  elseif key == "l" then selectPageForward()
  elseif key == "r" then shuffle()
  elseif key == "f5" then scanWallpapers()
  elseif key == "1" then switchTab("images")
  elseif key == "2" then switchTab("videos")
  elseif key == "3" then switchTab("engine")
  elseif key == "return" or key == "space" then
    local list = state.wallpapers
    if list[state.selectedIndex] then applyWallpaper(list[state.selectedIndex]) end
  end
end

function onTick() end
function update() end

function onConfigChanged()
  state.cardHeight = noctalia.getConfig("card_height") or 230
  scanWallpapers()
end

function init()
  if panel and panel.setWantsSecondTicks then panel.setWantsSecondTicks(true) end
  state.cardHeight = noctalia.getConfig("card_height") or 230
  loadThumbnailIndex()
  scanWallpapers()
end

init()
