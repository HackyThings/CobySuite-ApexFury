-- CobySuite: Shared library for all CobySuite addons
-- All shared utilities, UI factories, and infrastructure live here.
-- Individual addons (CobySniper, Linkepedia, etc.) depend on this.

CobySuite = CobySuite or {}

-- Sub-namespace declarations (populated by individual modules)
CobySuite.Utilities = CobySuite.Utilities or {}
CobySuite.UI        = CobySuite.UI or {}
CobySuite.Debug     = CobySuite.Debug or {}
CobySuite.Config    = CobySuite.Config or {}
CobySuite.EventBus  = CobySuite.EventBus or {}

CobySuite.SortDir = { ASC = "asc", DESC = "desc" }
