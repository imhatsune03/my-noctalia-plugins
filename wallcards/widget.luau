-- Wallcards bar widget for Noctalia v5
-- Displays an icon on the Noctalia bar/panel. Clicking it opens/toggles Wallcards.

local bar = barWidget or widget

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
end

function update()
  updateWidget()
end

-- Primary click handler when clicking the icon on the panel/bar
function onClick()
  noctalia.togglePanel("tonigineer/wallcards:main")
end

-- Fallback activation hook
function onActivate()
  noctalia.togglePanel("tonigineer/wallcards:main")
end

-- Right click opens plugin settings
function onRightClick()
  noctalia.openSettings()
end

function onConfigChanged()
  updateWidget()
end

init()
