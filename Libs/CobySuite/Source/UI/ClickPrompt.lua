---------------------------------------------------------------------------
-- The suite's two asking windows, one look: CreateWindow's shell (title bar
-- with the addon's icon, close X, drag to move, Escape closes) in the
-- DIALOG layer, as a dialog that asks something may, with a body text in
-- the body font and a row of buttons along the bottom, the window's height
-- following the text. Build them out of combat.
--
-- CreateClickPrompt(opts): a small window that asks the player something:
-- a title, a body text and a row of buttons.
--
-- Two forms:
-- - the macro form (opts.macro): the one click addon code can't make. Its
--   button is an addon-owned InsecureActionButtonTemplate running the macro
--   ("/click <Blizzard button>") on the secure path, so a Blizzard panel
--   opens or changes tab as if the player had clicked it (the taint
--   rules, pitfall 5), with Cancel beside it. The insecure template
--   refuses to run in combat.
-- - the plain form (opts.buttons): ordinary buttons, none of them secure.
--
--   opts.name         global name, so Escape closes it
--   opts.title        the title bar's text
--   opts.icon         the title bar's icon (the addon's ICON)
--   opts.onHide       function(prompt), when it closes (a button, the X,
--                     Escape, or a Hide from code)
--   opts.width        default 400
--   opts.point        a SetPoint list, default 120 above the screen's center
--   opts.strata       default "DIALOG"
--   opts.extraHeight  room under the body for the caller's own content (a
--                     checkbox anchored to prompt.Body), default 0
-- The macro form:
--   opts.macro        the button's macro text
--   opts.buttonText   the button's label
--   opts.onPostClick  function(prompt), after each click of the button
-- The plain form:
--   opts.buttons      { { key, text, onClick, width (130), side ("left" or
--                     "right") }, ... }: the left ones from the bottom-left
--                     corner rightwards, the right ones from the bottom-right
--                     corner leftwards, in list order; each kept as
--                     prompt[key]
--
-- Returns the window, with .Body (the text), and in the macro form .Button
-- (the macro button) and .Cancel. prompt:Ask(text) sets the text, shows the
-- window and fits its height to the text (110 at least); prompt:SetBody(text)
-- sets and fits without showing. Used by Recollect's Show Achievement and
-- curator dialogs, by Coby's Currency Searcher's Go to Currency and by
-- Coby's Loot Sweeper's track offer.
---------------------------------------------------------------------------
local UI = CobySuite_ApexFury.UI
local U = CobySuite_ApexFury.Utilities

local WIDTH, MIN_HEIGHT, PAD = 400, 110, 16
-- the body's top, and the buttons' row with the gap above it
local BUTTON_H = U.ButtonSize.MEDIUM.height
local BODY_TOP, BUTTON_ROOM, BUTTON_Y = 34, 14 + BUTTON_H + 16, 14
local BUTTON_GAP = 8

-- The height the text needs, never under the window's least height. A
-- window without a body keeps the height it was given.
local function FitHeight(prompt)
  if not prompt.Body then return end
  prompt:SetHeight(math.max(prompt._minHeight,
    BODY_TOP + prompt.Body:GetStringHeight() + prompt._extraHeight + BUTTON_ROOM))
end

local function AddBody(prompt)
  prompt.Body = prompt:CreateFontString(nil, "OVERLAY", U.Fonts.BODY)
  prompt.Body:SetPoint("TOPLEFT", prompt, "TOPLEFT", PAD, -BODY_TOP)
  prompt.Body:SetWidth(prompt._promptWidth - 2 * PAD)
  prompt.Body:SetJustifyH("LEFT")
  prompt.Body:SetWordWrap(true)
end

-- The shell both asking windows are built on. defaults: width, height (the
-- least height), point, shown.
local function NewPrompt(opts, defaults)
  local width, height = opts.width or defaults.width, defaults.height
  local f = UI.CreateWindow({
    name = opts.name, title = opts.title, icon = opts.icon, parent = opts.parent,
    width = width, height = height, strata = opts.strata or "DIALOG",
    escapeCloses = opts.name ~= nil, point = opts.point or defaults.point, shown = defaults.shown,
  })
  f._promptWidth, f._minHeight = width, height
  f._extraHeight = opts.extraHeight or 0
  if opts.onHide then
    f:HookScript("OnHide", function() opts.onHide(f) end)
  end
  return f
end

local function SetBody(prompt, text)
  prompt.Body:SetText(text)
  FitHeight(prompt)
end

-- sized after Show, once the text has its height
local function Ask(prompt, text)
  prompt.Body:SetText(text)
  prompt:Show()
  FitHeight(prompt)
end

-- the macro button and Cancel
local function AddMacroButtons(f, opts)
  -- the shared button's look on an insecure action button: the macro runs
  -- once, on release, never with a modifier
  f.Button = UI.CreateButton(f, { text = opts.buttonText, size = { 150, BUTTON_H },
    point = { "BOTTOMLEFT", f, "BOTTOMLEFT", PAD, BUTTON_Y }, template = "UIPanelButtonTemplate, InsecureActionButtonTemplate" })
  UI.ConfigureSecureClicker(f.Button, { type = "macro", macrotext = opts.macro, blockModified = true })
  if opts.onPostClick then
    f.Button:HookScript("PostClick", function() opts.onPostClick(f) end)
  end
  f.Cancel = UI.CreateButton(f, { text = "Cancel", size = { 110, BUTTON_H },
    point = { "BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, BUTTON_Y },
    onClick = function() f:Hide() end })
end

-- the plain form's buttons, each beside the last one on its side
local function AddPlainButtons(f, buttons)
  local lastLeft, lastRight
  for _, def in ipairs(buttons) do
    local point
    if def.side == "right" then
      point = lastRight and { "RIGHT", lastRight, "LEFT", -BUTTON_GAP, 0 } or { "BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, BUTTON_Y }
    else
      point = lastLeft and { "LEFT", lastLeft, "RIGHT", BUTTON_GAP, 0 } or { "BOTTOMLEFT", f, "BOTTOMLEFT", PAD, BUTTON_Y }
    end
    local button = UI.CreateButton(f, { text = def.text, size = { def.width or 130, BUTTON_H },
      point = point, onClick = def.onClick })
    if def.side == "right" then lastRight = button else lastLeft = button end
    if def.key then f[def.key] = button end
  end
end

function UI.CreateClickPrompt(opts)
  local f = NewPrompt(opts, { width = WIDTH, height = MIN_HEIGHT, point = { "CENTER", UIParent, "CENTER", 0, 120 } })
  AddBody(f)
  if opts.macro then
    AddMacroButtons(f, opts)
  else
    AddPlainButtons(f, opts.buttons or {})
  end
  f.Ask = Ask
  f.SetBody = SetBody
  return f
end

---------------------------------------------------------------------------
-- CreateDialogPopup(opts): a yes-or-no question in the click prompt's look
-- (restyled 2026-10-01, Task #82): the title in the title bar, the body
-- under it, Confirm at the bottom-left and Cancel at the bottom-right.
-- Closing it (Cancel, the X, Escape) answers nothing; opts.onHide hears
-- every close.
--
-- opts.name gives the popup a global name and closes it with Escape through
-- UISpecialFrames, which works in combat. Without a name the older OnKeyDown
-- handler is kept for compatibility; it raises ADDON_ACTION_BLOCKED on
-- keystrokes while the popup is open in combat, so name new popups.
-- opts.parent (default UIParent) makes the popup follow that frame's
-- visibility; opts.point (default the parent's CENTER) places it. It can
-- always be dragged (opts.movable is no longer needed).
--
-- The popup is shown when created unless opts.hidden. Optional content and
-- actions, so a caller needs no follow-up wiring:
--   opts.title       the title bar's text, as popup.Title
--   opts.icon        the title bar's icon (the addon's ICON)
--   opts.width       default 320
--   opts.height      its least height (default 110); the body's text makes it
--                    taller when it needs more, and a popup without a body
--                    keeps it (the caller places its own content)
--   opts.extraHeight room under the body for the caller's own content
--   opts.body        text (or a list of paragraphs) in popup.Body, under the
--                    title bar; popup:SetBody(text) sets or replaces it
--   opts.confirmText the confirm label (default "OK")
--   opts.onConfirm   function(popup): the confirm click hides the popup, then
--                    calls it (without it, wire popup.ConfirmButton yourself)
--   opts.cancelText  the cancel label (default "Cancel")
--   opts.hideCancel  no cancel button; the confirm button is centred
--   opts.danger      the title in U.Colors.WARNING_RED, for destructive actions
--   opts.onHide      function(popup), on every close
--   opts.strata      default "DIALOG"
---------------------------------------------------------------------------
local DIALOG_WIDTH, DIALOG_BUTTON_W = 320, 110

-- a bottom-row button at least as wide as its label needs
local function DialogButton(popup, text, point, onClick)
  local button = UI.CreateButton(popup, { text = text, size = { DIALOG_BUTTON_W, BUTTON_H }, point = point, onClick = onClick })
  local label = button:GetFontString()
  local needed = label and label:GetStringWidth()
  if type(needed) == "number" and needed + 32 > DIALOG_BUTTON_W then
    button:SetWidth(needed + 32)
  end
  return button
end

-- sets or replaces the body (popup.Body is made on first use, so a popup
-- without a body has no extra region) and fits the height to it
local function SetDialogBody(popup, text)
  if type(text) == "table" then text = table.concat(text, "\n\n") end
  if not popup.Body then AddBody(popup) end
  popup.Body:SetText(text or "")
  FitHeight(popup)
end

function UI.CreateDialogPopup(opts)
  local parent = opts.parent or UIParent
  local popup = NewPrompt(opts, {
    width = DIALOG_WIDTH, height = opts.height or MIN_HEIGHT,
    point = { "CENTER", parent, "CENTER", 0, 0 }, shown = not opts.hidden,
  })
  -- the text's height is only sure once shown
  popup:HookScript("OnShow", FitHeight)

  popup.Title = popup.TitleText
  if opts.danger and popup.Title then
    local wr = U.Colors.WARNING_RED
    popup.Title:SetTextColor(wr[1], wr[2], wr[3])
  end

  popup.SetBody = SetDialogBody
  if opts.body ~= nil then popup:SetBody(opts.body) end

  local confirmPoint = opts.hideCancel and { "BOTTOM", popup, "BOTTOM", 0, BUTTON_Y }
    or { "BOTTOMLEFT", popup, "BOTTOMLEFT", PAD, BUTTON_Y }
  popup.ConfirmButton = DialogButton(popup, opts.confirmText or "OK", confirmPoint, opts.onConfirm and function()
    popup:Hide()
    opts.onConfirm(popup)
  end)
  popup.CancelButton = DialogButton(popup, opts.cancelText or "Cancel",
    { "BOTTOMRIGHT", popup, "BOTTOMRIGHT", -PAD, BUTTON_Y }, function() popup:Hide() end)
  if opts.hideCancel then popup.CancelButton:Hide() end

  if not opts.name then
    popup:SetScript("OnKeyDown", function(self, key)
      if key == "ESCAPE" then
        self:SetPropagateKeyboardInput(false)
        self:Hide()
      else
        self:SetPropagateKeyboardInput(true)
      end
    end)
  end
  return popup
end
