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

local ToHex = U.ColorToHex

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

---------------------------------------------------------------------------
-- Chat.PutInChat(text): a link or text into chat, as a Shift-click does
--
-- Into the chat box already open (or wherever the game's InsertLink puts
-- it), else a newly opened one. Never into the macro editor: InsertLink
-- types into MacroFrameText while it has focus, and text an addon types
-- there taints the macro window's saves (measured with Coby's Linkepedia's
-- macro tools, 2026-09-16), so chat opens instead. InsertLink alone does
-- nothing when no box takes the text; OpenChat covers that.
---------------------------------------------------------------------------
-- The client calls PutInChat makes, swapped by tests (never a Blizzard global)
Chat.seams = {
  MacroFocused = function() return MacroFrameText ~= nil and MacroFrameText:HasFocus() == true end,
  InsertLink = function(text) return ChatFrameUtil.InsertLink(text) end,
  OpenChat = function(text) ChatFrameUtil.OpenChat(text) end,
}

function Chat.PutInChat(text)
  local seams = Chat.seams
  if seams.MacroFocused() or not seams.InsertLink(text) then
    seams.OpenChat(text)
  end
end
