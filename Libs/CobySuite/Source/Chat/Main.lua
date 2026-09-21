---------------------------------------------------------------------------
-- CobySuite.Chat: branded chat output
--
-- Every consumer addon prints to chat with its own coloured prefix. This
-- constructor builds that printer once per addon:
--
--   local Message = CobySuite.Chat.NewMessenger({
--     prefix = "[Coby's Currency Searcher]",
--     color  = "F2C94C",          -- hex string, {r, g, b} (0..1) or a ColorMixin
--     gate   = function(verboseOnly) return not verboseOnly or IsVerbose() end,  -- optional
--   })
--   Message("Loaded.")             -- "[Coby's Currency Searcher] Loaded."
--   Message("Scanned 12 items", true)   -- second argument reaches opts.gate only
--   Message.Success("Saved.")      -- the text in green (U.Colors.TEXT_GREEN)
--   Message.Warn("Nothing to do.") -- the text in gold (U.Colors.TEXT_GOLD)
--
-- The gate lets an addon keep a "verbose" mode: return false to drop the
-- line. Without a gate every call prints. Success and Warn take the same
-- second argument and go through the same gate and prefix.
--
-- The messenger is a callable table (a metatable __call), not a function:
-- call it, pass it as a callback or to Slash.Register as before, but do not
-- test it with type(x) == "function".
---------------------------------------------------------------------------
CobySuite_ApexFury.Chat = CobySuite_ApexFury.Chat or {}
local Chat = CobySuite_ApexFury.Chat
local U = CobySuite_ApexFury.Utilities

local function ToHex(color)
  if type(color) == "string" then
    return color
  end
  if type(color) == "table" then
    local r = color.r or color[1] or 1
    local g = color.g or color[2] or 1
    local b = color.b or color[3] or 1
    return string.format("%02X%02X%02X", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
  end
  return "FFFFFF"
end

function Chat.NewMessenger(opts)
  opts = opts or {}
  local prefix = opts.prefix or ""
  if prefix ~= "" then
    prefix = U.WrapColor(ToHex(opts.color), prefix) .. (opts.separator or " ")
  end
  local gate = opts.gate

  local function Print(text, verboseOnly)
    if gate and not gate(verboseOnly) then return end
    print(prefix .. tostring(text))
  end

  local messenger = {}
  function messenger.Success(text, verboseOnly)
    Print(U.WrapColor(U.Colors.TEXT_GREEN, tostring(text)), verboseOnly)
  end
  function messenger.Warn(text, verboseOnly)
    Print(U.WrapColor(U.Colors.TEXT_GOLD, tostring(text)), verboseOnly)
  end
  return setmetatable(messenger, {
    __call = function(_, text, verboseOnly) Print(text, verboseOnly) end,
  })
end

---------------------------------------------------------------------------
-- Chat.ComposeWhisper(target, text): put a whisper in the chat box
--
-- Sets the send box to whisper `target` and opens it with `text`, the way
-- Blizzard's reply shortcut prepares a whisper, so the player can edit it
-- and press Enter. Nothing is sent. `text` may contain hyperlinks. Returns
-- the edit box.
---------------------------------------------------------------------------
function Chat.ComposeWhisper(target, text)
  local editBox = ChatFrameUtil.ChooseBoxForSend()
  editBox:SetChatType("WHISPER")
  editBox:SetTellTarget(target)
  ChatFrameUtil.OpenChat(text or "")
  return editBox
end
