---------------------------------------------------------------------------
-- CobySuite.UI.CreateFormLayout — settings-form builder
--
-- Wraps the standalone widget factories (CreateCheckbox, CreateNumberInput,
-- CreateTextInput, CreateSlider, CreateSection) with consistent label
-- placement and y-offset bookkeeping so addon settings windows stop
-- reimplementing the same row math.
--
-- Construction takes a layout config; row methods ride on top of it.
-- The form-builder is purely visual — it never touches Config, Stage(),
-- Apply(), event buses, or refresh logic. Wiring is per-row via the
-- onChange / onCommit callbacks the caller supplies, so addons that
-- commit immediately and addons that stage-then-apply both work
-- without changing the form-builder.
--
--   local form = CobySuite.UI.CreateFormLayout(parent, {
--       labelX     = 16,        -- x-anchor for labels
--       controlX   = 220,       -- x-anchor for controls
--       rowHeight  = 26,        -- vertical pitch between standard rows
--       sectionGap = 14,        -- extra gap before a section header
--       width      = 480,       -- form width (used for divider/section sizing)
--       startY     = -16,       -- initial y offset
--       inputWidth     = 80,    -- default number/text input width
--       sliderWidth    = 280,
--       sliderTemplate = "MinimalSliderTemplate",
--       checkboxSize   = 24,
--       labelFont      = U.Fonts.DATA,
--   })
--
--   form:Section("Behavior")
--   form:Checkbox{ label = "...", tooltip = "...", initialValue = ...,
--                  onChange = function(v) end }
--   form:NumberInput{ label = "...", validate = function(n) end,
--                     initialValue = ..., onCommit = function(n) end }
--   form:Slider{ label = "...", min = 1, max = 100, initialValue = ...,
--                onChange = function(v) end }
--   form:Skip(8)
--   form:Custom(function(parent, y, layout) return y - 30 end)
--
-- All row methods return the widget plus the new y offset for callers
-- that want to anchor adjacent siblings off the same row.
---------------------------------------------------------------------------

local UI = CobySuite.UI
local U  = CobySuite.Utilities

local FormLayout = {}
FormLayout.__index = FormLayout

local function nilOr(v, default)
  if v == nil then return default end
  return v
end

function UI.CreateFormLayout(parent, layout)
  layout = layout or {}
  local self = setmetatable({}, FormLayout)
  self.parent = parent
  self.layout = {
    labelX         = nilOr(layout.labelX, 16),
    controlX       = nilOr(layout.controlX, 220),
    rowHeight      = nilOr(layout.rowHeight, 26),
    sectionGap     = nilOr(layout.sectionGap, 14),
    width          = nilOr(layout.width, parent:GetWidth() or 480),
    inputWidth     = nilOr(layout.inputWidth, 80),
    sliderWidth    = nilOr(layout.sliderWidth, 280),
    sliderTemplate = layout.sliderTemplate or "MinimalSliderTemplate",
    checkboxSize   = nilOr(layout.checkboxSize, 24),
    labelFont      = layout.labelFont or U.Fonts.DATA,
    sectionFont    = layout.sectionFont or "GameFontNormal",
    dividerPadding = nilOr(layout.dividerPadding, 0),
  }
  self.y = nilOr(layout.startY, -16)
  self.lastWidget = nil
  return self
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function buildLabel(form, text, tooltip)
  if not text then return nil end
  local label = form.parent:CreateFontString(nil, "OVERLAY", form.layout.labelFont)
  label:SetPoint("LEFT", form.parent, "TOPLEFT", form.layout.labelX, form.y)
  label:SetText(text)
  if tooltip then UI.AddTooltip(label, tooltip, "ANCHOR_RIGHT") end
  return label
end

---------------------------------------------------------------------------
-- Sections
---------------------------------------------------------------------------
function FormLayout:Section(text, opts)
  opts = opts or {}
  -- Extra gap before the section header.
  self.y = self.y - (opts.gap or self.layout.sectionGap)

  local header, divider = UI.CreateSection(self.parent, {
    text         = text,
    font         = opts.font or self.layout.sectionFont,
    point        = { "LEFT", self.parent, "TOPLEFT", self.layout.labelX, self.y },
    divider      = opts.divider ~= false,
    dividerOffset = opts.dividerOffset or -4,
    dividerPadding = opts.dividerPadding or self.layout.dividerPadding,
    dividerY     = self.y - (opts.dividerOffset and -opts.dividerOffset or 4),
    dividerColor = opts.dividerColor,
    width        = opts.width,
  })

  -- Advance past header + divider so the next row starts with rowHeight gap.
  self.y = self.y - self.layout.rowHeight
  self.lastWidget = header
  return header, divider, self.y
end

---------------------------------------------------------------------------
-- Checkbox row — checkbox at labelX, label-on-right.
-- Tooltip applies to BOTH the checkbox AND its text via two AddTooltip
-- calls so hovering either triggers the same hint.
---------------------------------------------------------------------------
function FormLayout:Checkbox(opts)
  opts = opts or {}
  local cb = UI.CreateCheckbox(self.parent, {
    name         = opts.name,
    size         = opts.size or self.layout.checkboxSize,
    label        = opts.label,
    labelGap     = opts.labelGap or 4,
    tooltip      = opts.tooltip,
    initialValue = opts.initialValue,
    optionKey    = opts.optionKey,
    onChange     = opts.onChange,
    point        = { "LEFT", self.parent, "TOPLEFT", self.layout.labelX, self.y },
  })

  self.y = self.y - (opts.rowHeight or self.layout.rowHeight)
  self.lastWidget = cb
  return cb, self.y
end

---------------------------------------------------------------------------
-- Number input row — label at labelX, input at controlX.
-- opts mirrors CreateNumberInput plus a `label` and an optional
-- `controlX` override for one-off alignment.
---------------------------------------------------------------------------
function FormLayout:NumberInput(opts)
  opts = opts or {}
  buildLabel(self, opts.label, opts.tooltip)

  local controlX = opts.controlX or self.layout.controlX
  local eb = UI.CreateNumberInput(self.parent, {
    name         = opts.name,
    template     = opts.template,
    width        = opts.width or self.layout.inputWidth,
    height       = opts.height,
    maxLetters   = opts.maxLetters or 10,
    initialValue = opts.initialValue,
    parse        = opts.parse,
    validate     = opts.validate,
    format       = opts.format,
    onCommit     = opts.onCommit,
    optionKey    = opts.optionKey,
    tooltip      = opts.tooltip,
    point        = { "LEFT", self.parent, "TOPLEFT", controlX, self.y },
  })

  self.y = self.y - (opts.rowHeight or self.layout.rowHeight)
  self.lastWidget = eb
  return eb, self.y
end

---------------------------------------------------------------------------
-- Text input row — label at labelX, input at controlX.
---------------------------------------------------------------------------
function FormLayout:TextInput(opts)
  opts = opts or {}
  buildLabel(self, opts.label, opts.tooltip)

  local controlX = opts.controlX or self.layout.controlX
  local eb = UI.CreateTextInput(self.parent, {
    name             = opts.name,
    template         = opts.template,
    width            = opts.width or 200,
    height           = opts.height,
    maxLetters       = opts.maxLetters,
    autoFocus        = opts.autoFocus,
    initialValue     = opts.initialValue,
    parse            = opts.parse,
    validate         = opts.validate,
    format           = opts.format,
    onCommit         = opts.onCommit,
    onChange         = opts.onChange,
    highlightOnFocus = opts.highlightOnFocus,
    optionKey        = opts.optionKey,
    tooltip          = opts.tooltip,
    point            = { "LEFT", self.parent, "TOPLEFT", controlX, self.y },
  })

  self.y = self.y - (opts.rowHeight or self.layout.rowHeight)
  self.lastWidget = eb
  return eb, self.y
end

---------------------------------------------------------------------------
-- Slider row — label above slider (sliders are wide).
--
-- Layout:
--   y          [Label "Foo (s)"]
--   y - 16     [=========slider==========]   [valueText]
--
-- Total advance: rowHeight + sliderRowExtra (default 16). The label
-- sits at labelX; the slider sits at labelX + 10 to align nicely with
-- the label baseline (matches Linkepedia's CreateSliderRow pattern).
---------------------------------------------------------------------------
function FormLayout:Slider(opts)
  opts = opts or {}

  local label
  if opts.label then
    label = self.parent:CreateFontString(nil, "OVERLAY", U.Fonts.BODY)
    label:SetPoint("LEFT", self.parent, "TOPLEFT", self.layout.labelX, self.y)
    label:SetText(opts.label)
    if opts.tooltip then UI.AddTooltip(label, opts.tooltip, "ANCHOR_RIGHT") end
  end

  local sliderY = self.y - (opts.labelToSliderGap or 16)
  local sl = UI.CreateSlider(self.parent, {
    name           = opts.name,
    template       = opts.template or self.layout.sliderTemplate,
    width          = opts.width or self.layout.sliderWidth,
    height         = opts.height,
    min            = opts.min or 0,
    max            = opts.max or 100,
    step           = opts.step or 1,
    initialValue   = opts.initialValue,
    showValue      = opts.showValue,
    valueWidth     = opts.valueWidth,
    valueGap       = opts.valueGap,
    format         = opts.format,
    onChange       = opts.onChange,
    optionKey      = opts.optionKey,
    obeyStepOnDrag = opts.obeyStepOnDrag,
    point          = { "LEFT", self.parent, "TOPLEFT", self.layout.labelX + 10, sliderY },
  })

  self.y = sliderY - (opts.rowHeight or self.layout.rowHeight)
  self.lastWidget = sl
  return sl, self.y
end

---------------------------------------------------------------------------
-- Dropdown row — wraps Utilities.CreateDropDown for forms.
-- The shared dropdown owns its own label (see CobySuite.UI.CreateDropDown);
-- here we just position the row and supply opts.
---------------------------------------------------------------------------
function FormLayout:Dropdown(opts)
  opts = opts or {}
  local dd = UI.CreateDropDown(self.parent)
  dd:SetPoint("TOPLEFT", self.parent, "TOPLEFT",
    self.layout.labelX, self.y)
  if opts.label then dd.Label:SetText(opts.label) end
  if opts.labels and opts.values then
    dd:InitAgain(opts.labels, opts.values, opts.tooltips)
  end
  if opts.initialValue ~= nil then dd:SetValue(opts.initialValue) end
  if opts.onChange then dd.onValueChanged = opts.onChange end

  -- Dropdowns are taller than a standard row; default to 44 (matches
  -- Linkepedia's CreateDropdownRow) but allow override.
  self.y = self.y - (opts.rowHeight or 44)
  self.lastWidget = dd
  return dd, self.y
end

---------------------------------------------------------------------------
-- Custom row — caller builds whatever and returns the new y offset.
---------------------------------------------------------------------------
function FormLayout:Custom(builder)
  if not builder then return self.y end
  local newY = builder(self.parent, self.y, self.layout)
  if type(newY) == "number" then self.y = newY end
  return self.y
end

---------------------------------------------------------------------------
-- Y-offset manipulation
---------------------------------------------------------------------------
function FormLayout:Skip(amount) self.y = self.y - (amount or 0); return self.y end
function FormLayout:GetY()        return self.y                               end
function FormLayout:SetY(y)       self.y = y; return self.y                   end
function FormLayout:GetLastWidget() return self.lastWidget                    end

---------------------------------------------------------------------------
-- Accessors for the layout config (so caller can compute custom positions
-- against the same anchor values the form-builder is using).
---------------------------------------------------------------------------
function FormLayout:GetLayout() return self.layout end
function FormLayout:GetLabelX()    return self.layout.labelX    end
function FormLayout:GetControlX()  return self.layout.controlX  end
function FormLayout:GetRowHeight() return self.layout.rowHeight end
function FormLayout:GetWidth()     return self.layout.width     end
