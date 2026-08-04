-- Wallcards shortcut for Noctalia v5 Control Center
-- Displays a toggle tile with icon in the control center to open/toggle Wallcards

local sc = shortcut

local function updateShortcut()
  if not sc then
    return
  end

  if sc.setLabel then
    sc.setLabel(noctalia.tr("name"))
  end

  if sc.setIcon then
    sc.setIcon("cards")
  end

  if sc.setEnabled then
    sc.setEnabled(true)
  end
end

function init()
  updateShortcut()
end

function update()
  updateShortcut()
end

function onClick()
  noctalia.togglePanel("tonigineer/wallcards:main")
end

function onActivate()
  noctalia.togglePanel("tonigineer/wallcards:main")
end

function onRightClick()
  noctalia.openSettings()
end

function onConfigChanged()
  updateShortcut()
end

init()
