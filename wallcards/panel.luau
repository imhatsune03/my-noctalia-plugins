--!nonstrict
-- Wallcards Panel for Noctalia v5
-- Unified wallpaper manager (images & videos in a single collection),
-- dynamic shell palette theming from video frames and static images,
-- resolution & frame rate badges, manual Enter-to-apply (without closing),
-- and centered card carousel with keyboard shortcuts footer.

local CACHE_DIR = (noctalia.getenv("XDG_CACHE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.cache")) .. "/noctalia/wallcards/thumbnails"
local INDEX_FILE = (noctalia.getenv("XDG_CACHE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.cache")) .. "/noctalia/wallcards/index.json"

local THUMB_MAX_CONCURRENT = 2
local BATCH_SIZE = 20

local IMAGE_EXTS = { png = true, jpg = true, jpeg = true, webp = true, bmp = true, avif = true, gif = true }
local VIDEO_EXTS = { mp4 = true, mkv = true, webm = true, avi = true, mov = true }

local state = {
  wallpapers = {},
  imageCount = 0,
  videoCount = 0,
  selectedIndex = 1,
  cardHeight = 230,
  wallpaperDir = "",
  statusMessage = "",
}

local thumbCache = {}
local thumbPending = {}
local thumbQueue = {}
local thumbActive = 0
local indexDirty = false
local isScanning = false
local tickCount = 0

-- Deferred batch processing state
local pendingLines = {}      -- raw file paths from find, waiting to be processed
local processingActive = false

-- Forward declarations
local renderUI
local pumpThumbQueue
local scanWallpapersAsync
local processBatch

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
  if configured and configured ~= "" then
    return noctalia.expandPath(configured)
  end
  local wpDir = noctalia.expandPath("~/Imágenes/Wallpapers")
  if wpDir and noctalia.fileExists(wpDir) then
    return wpDir
  end
  local picWallpapers = noctalia.expandPath("~/Pictures/Wallpapers")
  if picWallpapers and noctalia.fileExists(picWallpapers) then
    return picWallpapers
  end
  return noctalia.expandPath("~/Imágenes")
end

local function loadThumbnailIndex()
  if noctalia.fileExists(INDEX_FILE) then
    local content = noctalia.readFile(INDEX_FILE)
    if content and content ~= "" and noctalia.json and noctalia.json.decode then
      local ok, decoded = pcall(noctalia.json.decode, content)
      if ok and type(decoded) == "table" then
        thumbCache = decoded
      end
    end
  end
end

local function saveThumbnailIndex()
  if not indexDirty or not noctalia.json or not noctalia.json.encode then return end
  indexDirty = false
  local ok, encoded = pcall(noctalia.json.encode, thumbCache)
  if ok and encoded then
    noctalia.writeFile(INDEX_FILE, encoded)
  end
end

local function getThumbPathFor(wallpaperPath: string): string
  return CACHE_DIR .. "/" .. wallpaperPath:gsub("[^%w]", "_") .. ".jpg"
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
        if item.isVideo then
          cmd = "ffmpeg -y -ss 00:00:01 -i " .. shellQuote(path) .. " -vframes 1 -vf 'scale=480:-1' -q:v 3 " .. shellQuote(dest) .. " 2>/dev/null && ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=s=x:p=0 " .. shellQuote(path) .. " 2>/dev/null && magick " .. shellQuote(dest) .. " -resize 1x1 -format ' #%[hex:u.p{0,0}]' info: 2>/dev/null"
        else
          cmd = "magick " .. shellQuote(path) .. " -thumbnail 480x270^ -gravity center -extent 480x270 -quality 82 " .. shellQuote(dest) .. " 2>/dev/null && magick identify -format '%wx%h' " .. shellQuote(path) .. " 2>/dev/null && magick " .. shellQuote(dest) .. " -resize 1x1 -format ' #%[hex:u.p{0,0}]' info: 2>/dev/null"
        end

        noctalia.runAsync(cmd, function(result)
          thumbActive -= 1
          thumbPending[path] = nil

          if noctalia.fileExists(dest) then
            item.thumbPath = dest
            local outStr = ""
            if type(result) == "string" then
              outStr = result
            elseif type(result) == "table" and result.stdout then
              outStr = result.stdout
            end

            local hex = outStr:match("#(%x%x%x%x%x%x)")
            if hex then item.colorHex = "#" .. hex end

            if item.isVideo then
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

            thumbCache[path] = {
              thumbPath = dest,
              colorHex = item.colorHex,
              res = item.res,
              fps = item.fps,
            }
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

local function applyVideoWallpaper(item)
  if not item then return end
  -- Apply thumbnail to Noctalia to extract palette and recolor the shell
  if item.thumbPath ~= "" and noctalia.fileExists(item.thumbPath) then
    noctalia.setWallpaper(item.thumbPath)
  end
  noctalia.runAsync("pkill -9 gslapper 2>/dev/null", function()
    local cmd = "gslapper -f -o 'no-audio loop' '*' " .. shellQuote(item.path)
    noctalia.runAsync(cmd, function()
      noctalia.runAsync("sleep 0.4", function()
        noctalia.setWallpaperEnabled("", false)
      end)
    end, 5000)
    state.statusMessage = "Vídeo aplicado: " .. item.name
    renderUI()
  end, 2000)
end

local function applyStaticWallpaper(item)
  if not item then return end
  noctalia.runAsync("pkill -9 gslapper 2>/dev/null", function()
    noctalia.setWallpaperEnabled("", true)
    noctalia.setWallpaper(item.path)
    state.statusMessage = "Wallpaper aplicado: " .. item.name
    renderUI()
  end, 2000)
end

local function applyWallpaper(item)
  if not item then return end
  if item.isVideo then
    applyVideoWallpaper(item)
  else
    applyStaticWallpaper(item)
  end
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
    for _, off in ipairs({ -1, 1, -2, 2 }) do
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
  if nextIdx == state.selectedIndex then
    nextIdx = (nextIdx % #list) + 1
  end
  selectIndex(nextIdx)
end

-- ── Batch processing: converts pendingLines into state.wallpapers in small chunks ─
function processBatch()
  if #pendingLines == 0 then
    processingActive = false
    if state.selectedIndex > #state.wallpapers then
      state.selectedIndex = math.max(1, #state.wallpapers)
    elseif state.selectedIndex < 1 and #state.wallpapers > 0 then
      state.selectedIndex = 1
    end
    selectIndex(state.selectedIndex)
    return
  end

  local count = 0
  while count < BATCH_SIZE and #pendingLines > 0 do
    local path = table.remove(pendingLines, 1)
    local name = path:match("([^/]+)$") or path
    local ext = getExtension(name)
    local isImg = IMAGE_EXTS[ext]
    local isVid = VIDEO_EXTS[ext]

    if isImg or isVid then
      local cached = thumbCache[path]
      local item = {
        name = name,
        baseName = getBaseNameWithoutExt(name),
        path = path,
        thumbPath = (cached and cached.thumbPath) or "",
        isVideo = isVid,
        ext = ext:upper(),
        res = (cached and cached.res) or (name:match("(%d+x%d+)") or ""),
        fps = (cached and cached.fps) or (isVid and "" or "Static"),
        colorHex = (cached and cached.colorHex) or (isVid and "#0A84FF" or "#2DD4BF"),
      }
      table.insert(state.wallpapers, item)
      if isVid then
        state.videoCount += 1
      else
        state.imageCount += 1
      end
    end
    count += 1
  end

  -- Render intermediate progress
  if state.selectedIndex < 1 and #state.wallpapers > 0 then
    state.selectedIndex = 1
  end
  renderUI()
end

function scanWallpapersAsync()
  if isScanning then return end
  isScanning = true
  state.wallpaperDir = getWallpaperDir()
  noctalia.mkdirAll(CACHE_DIR)
  loadThumbnailIndex()

  local findCmd = "find " .. shellQuote(state.wallpaperDir) .. " -maxdepth 2 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.bmp' -o -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' -o -iname '*.avi' -o -iname '*.mov' \\) 2>/dev/null | sort -f"

  noctalia.runAsync(findCmd, function(result)
    isScanning = false
    local outStr = ""
    if type(result) == "string" then
      outStr = result
    elseif type(result) == "table" and result.stdout then
      outStr = result.stdout
    end

    -- Reset state and queue raw lines for deferred batch processing
    state.wallpapers = {}
    state.imageCount = 0
    state.videoCount = 0
    pendingLines = {}

    for line in outStr:gmatch("[^\r\n]+") do
      local path = line:match("^%s*(.-)%s*$")
      if path and path ~= "" then
        table.insert(pendingLines, path)
      end
    end

    processingActive = true
    renderUI()
  end, 8000)
end

local function getWrappedItem(idx: number)
  local list = state.wallpapers
  local total = #list
  if total == 0 then return nil, 0 end
  local wrapped = ((idx - 1) % total) + 1
  return list[wrapped], wrapped
end

-- ── Render the UI ──────────────────────────────────────────────────────────
function renderUI()
  if not panel or not panel.render then return end

  local list = state.wallpapers
  local total = #list
  local currentItem = list[state.selectedIndex]

  -- ── 1. Top bar ─────────────────────────────────────────────────────────
  local topChildren = {}

  table.insert(topChildren, ui.row({
    fill = "#141416", radius = 14, paddingH = 14, paddingV = 6, align = "center",
  }, {
    ui.label({
      text = string.format("%d  /  %d", total > 0 and state.selectedIndex or 0, total),
      fontWeight = "bold", fontSize = 13, color = "#2DD4BF",
    }),
  }))

  table.insert(topChildren, ui.spacer())

  table.insert(topChildren, ui.row({
    fill = "#141416", radius = 16, paddingH = 16, paddingV = 6, align = "center", gap = 12,
  }, {
    ui.row({ gap = 5, align = "center" }, {
      ui.glyph({ name = "photo", size = 13, color = "#34D399" }),
      ui.label({
        text = string.format("%d Estáticos", state.imageCount),
        fontSize = 12, fontWeight = "bold", color = "#E4E4E7",
      }),
    }),
    ui.label({ text = "•", color = "#52525B", fontSize = 12 }),
    ui.row({ gap = 5, align = "center" }, {
      ui.glyph({ name = "player-play-filled", size = 13, color = "#60A5FA" }),
      ui.label({
        text = string.format("%d Vídeos", state.videoCount),
        fontSize = 12, fontWeight = "bold", color = "#E4E4E7",
      }),
    }),
  }))

  table.insert(topChildren, ui.spacer())

  table.insert(topChildren, ui.row({
    fill = "#141416", radius = 16, paddingH = 10, paddingV = 4, align = "center", gap = 8,
  }, {
    ui.button({
      key = "btn_shuffle", text = "Shuffle", glyph = "arrows-shuffle",
      variant = "ghost", controlSize = "sm", tooltip = "Shuffle (R)", onClick = shuffle,
    }),
    ui.button({
      key = "btn_close_panel", glyph = "x", variant = "ghost", controlSize = "sm",
      tooltip = "Close (Esc)",
      onClick = function() if panel and panel.close then panel.close() end end,
    }),
  }))

  local topBar = ui.row({
    gap = 12, align = "center", justify = "space_between", width = 1060,
  }, topChildren)

  -- ── 2. Carousel deck ───────────────────────────────────────────────────
  local carouselCards = {}

  if total > 0 then
    -- Left flanking strips
    for _, offset in ipairs({ -4, -3, -2, -1 }) do
      local item, idx = getWrappedItem(state.selectedIndex + offset)
      if item then
        local imgPath = item.thumbPath ~= "" and item.thumbPath or item.path
        table.insert(carouselCards, ui.column({
          gap = 4, align = "center", width = 56, height = state.cardHeight,
          radius = 8, border = "#27272A", borderWidth = 1, opacity = 0.85,
          onClick = function() selectIndex(idx) end,
        }, {
          ui.row({
            fill = "#18181B", radius = 6, paddingH = 3, paddingV = 2,
            align = "center", justify = "space_between", width = 54,
          }, {
            ui.label({
              text = (item.res ~= "" and item.res:match("^(%d+)")) or item.ext,
              fontSize = 8, fontWeight = "bold", color = "#A1A1AA",
            }),
            ui.label({
              text = (item.fps ~= "" and item.fps:match("^(%d+)")) or (item.isVideo and "V" or "S"),
              fontSize = 8, fontWeight = "bold",
              color = item.isVideo and "#60A5FA" or "#34D399",
            }),
          }),
          ui.image({
            key = "strip_l_" .. offset .. "_" .. idx,
            path = imgPath, width = 52, height = state.cardHeight - 26,
            radius = 6, fit = "cover",
          }),
        }))
      end
    end

    -- Center hero card
    if currentItem then
      local heroImgPath = currentItem.thumbPath ~= "" and currentItem.thumbPath or currentItem.path
      table.insert(carouselCards, ui.column({
        gap = 6, align = "center", width = 510, height = state.cardHeight,
        radius = 12, border = currentItem.colorHex or "#2DD4BF", borderWidth = 2, padding = 4,
        onClick = function() applyWallpaper(currentItem) end,
      }, {
        ui.row({
          gap = 8, align = "center", justify = "space_between", width = 500,
        }, {
          ui.row({ fill = "#141416", radius = 10, paddingH = 12, paddingV = 4, align = "center" }, {
            ui.label({
              text = (currentItem.res ~= "" and currentItem.res) or "—",
              fontWeight = "bold", fontSize = 11, color = "#FFFFFF",
            }),
          }),
          ui.row({
            fill = "#141416", radius = 10, paddingH = 10, paddingV = 4, align = "center", gap = 5,
          }, {
            ui.glyph({
              name = currentItem.isVideo and "player-play-filled" or "photo", size = 11,
              color = currentItem.isVideo and "#60A5FA" or "#34D399",
            }),
            ui.label({
              text = (currentItem.fps ~= "" and currentItem.fps) or "—",
              fontSize = 11, fontWeight = "bold", color = "#E4E4E7",
            }),
          }),
        }),
        ui.image({
          key = "hero_img_" .. state.selectedIndex,
          path = heroImgPath, width = 500, height = state.cardHeight - 38,
          radius = 8, fit = "cover",
        }),
      }))
    end

    -- Right flanking strips
    for _, offset in ipairs({ 1, 2, 3, 4 }) do
      local item, idx = getWrappedItem(state.selectedIndex + offset)
      if item then
        local imgPath = item.thumbPath ~= "" and item.thumbPath or item.path
        table.insert(carouselCards, ui.column({
          gap = 4, align = "center", width = 56, height = state.cardHeight,
          radius = 8, border = "#27272A", borderWidth = 1, opacity = 0.85,
          onClick = function() selectIndex(idx) end,
        }, {
          ui.row({
            fill = "#18181B", radius = 6, paddingH = 3, paddingV = 2,
            align = "center", justify = "space_between", width = 54,
          }, {
            ui.label({
              text = (item.res ~= "" and item.res:match("^(%d+)")) or item.ext,
              fontSize = 8, fontWeight = "bold", color = "#A1A1AA",
            }),
            ui.label({
              text = (item.fps ~= "" and item.fps:match("^(%d+)")) or (item.isVideo and "V" or "S"),
              fontSize = 8, fontWeight = "bold",
              color = item.isVideo and "#60A5FA" or "#34D399",
            }),
          }),
          ui.image({
            key = "strip_r_" .. offset .. "_" .. idx,
            path = imgPath, width = 52, height = state.cardHeight - 26,
            radius = 6, fit = "cover",
          }),
        }))
      end
    end
  else
    -- Empty state
    table.insert(carouselCards, ui.column({
      gap = 8, align = "center", justify = "center",
      height = state.cardHeight, width = 800,
    }, {
      ui.glyph({ name = "folder", size = 42, color = "#71717A" }),
      ui.label({
        text = processingActive and "Cargando wallpapers..." or "No se encontraron imágenes ni vídeos",
        fontWeight = "bold", fontSize = 14,
      }),
      ui.label({ text = state.wallpaperDir, fontSize = 11, color = "#A1A1AA" }),
    }))
  end

  local carouselDeck = ui.row({
    gap = 8, align = "center", justify = "center", width = 1060,
  }, carouselCards)

  -- ── 3. Footer bar with keyboard shortcuts ──────────────────────────────
  local footerChildren = {}

  if state.statusMessage ~= "" then
    table.insert(footerChildren, ui.label({
      text = state.statusMessage, fontSize = 11, color = "#2DD4BF",
    }))
  else
    table.insert(footerChildren, ui.spacer())
  end

  table.insert(footerChildren, ui.label({
    text = "[Enter / Space] Aplicar    •    [← → J K] Navegar    •    [H / L] Saltar    •    [R] Aleatorio    •    [Esc / Q] Salir",
    fontSize = 11, color = "#71717A",
  }))

  local footerBar = ui.row({
    gap = 8, align = "center", justify = "space_between", width = 1060,
  }, footerChildren)

  -- ── Master layout ──────────────────────────────────────────────────────
  panel.render(ui.column({
    gap = 14, padding = 16, fill = true, align = "center", justify = "center",
  }, {
    topBar,
    carouselDeck,
    footerBar,
  }))
end

-- ── Key handler ────────────────────────────────────────────────────────────
function onKey(chord: string, pressed: boolean)
  if not pressed then return end
  local key = chord:lower()

  if key == "escape" or key == "q" then
    if panel and panel.close then panel.close() end
  elseif key == "j" or key == "right" or key == "down" then
    selectNext()
  elseif key == "k" or key == "left" or key == "up" then
    selectPrev()
  elseif key == "h" then
    selectPageBack()
  elseif key == "l" then
    selectPageForward()
  elseif key == "r" then
    shuffle()
  elseif key == "return" or key == "space" then
    local list = state.wallpapers
    if list[state.selectedIndex] then
      applyWallpaper(list[state.selectedIndex])
    end
  end
end

-- ── Tick: batch processing + periodic rescan ───────────────────────────────
function onTick()
  tickCount += 1

  -- Process pending file lines in batches
  if processingActive and #pendingLines > 0 then
    processBatch()
    return
  end

  -- Periodic rescan every 10 seconds
  if tickCount % 10 == 0 and not isScanning and not processingActive then
    scanWallpapersAsync()
  end
end

function update()
  onTick()
end

function onConfigChanged()
  state.cardHeight = noctalia.getConfig("card_height") or 230
  scanWallpapersAsync()
end

function init()
  state.cardHeight = noctalia.getConfig("card_height") or 230
  scanWallpapersAsync()
end

init()
