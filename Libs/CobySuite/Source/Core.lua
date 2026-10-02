-- CobySuite: Shared library for all CobySuite addons
-- All shared utilities, UI factories, and infrastructure live here.
-- Individual addons (Recollect, CobysLinkepedia, etc.) depend on this.

CobySuite_ApexFury = CobySuite_ApexFury or {}

-- Sub-namespace declarations (populated by individual modules)
CobySuite_ApexFury.Utilities = CobySuite_ApexFury.Utilities or {}
CobySuite_ApexFury.UI        = CobySuite_ApexFury.UI or {}
CobySuite_ApexFury.Debug     = CobySuite_ApexFury.Debug or {}
CobySuite_ApexFury.Config    = CobySuite_ApexFury.Config or {}
CobySuite_ApexFury.EventBus  = CobySuite_ApexFury.EventBus or {}
CobySuite_ApexFury.Chat      = CobySuite_ApexFury.Chat or {}
CobySuite_ApexFury.Slash     = CobySuite_ApexFury.Slash or {}
CobySuite_ApexFury.Tests     = CobySuite_ApexFury.Tests or {}

CobySuite_ApexFury.SortDir = { ASC = "asc", DESC = "desc" }

-- Where this copy of the library comes from. The monorepo's CobySuite addon
-- leaves it as is; a standalone build embeds the library under its own name
-- and replaces it from its Build.lua with { embedded = true, host = "<addon>",
-- commit = "<short sha>", dirty = <bool> }.
CobySuite_ApexFury.BuildInfo = CobySuite_ApexFury.BuildInfo or { embedded = false }

-- The library version for reports: "embedded in <host> at <commit>" in a
-- standalone build, else the CobySuite addon's TOC version. The addon name
-- below is the only string literal in shipped shared code that is exactly
-- the library's name (the standalone build checks this; Source/Tests/ is
-- stripped).
function CobySuite_ApexFury.LibraryVersionText()
  local info = CobySuite_ApexFury.BuildInfo
  if info and info.embedded then
    return ("embedded in %s at %s"):format(tostring(info.host or "?"), tostring(info.commit or "?"))
  end
  return C_AddOns.GetAddOnMetadata("CobySuite", "Version") or "?"
end
