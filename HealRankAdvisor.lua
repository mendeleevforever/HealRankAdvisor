local addonName, ns = ...

-- HealRankAdvisor.lua
-- Table of every healing spell rank for your class/level with average
-- Healing per Second (HPS) and Healing per Mana (HPM), healing power
-- coefficients and base heals.

local HRA = {}
_G.HealRankAdvisor = HRA
ns.HRA = HRA

local VERSION = "1.5.1"
local GCD     = 1.5
local DB        -- account-wide settings  (HealRankAdvisorDB)
local CDB       -- per-character data     (HealRankAdvisorCharDB)

-- Account-wide settings
local DEFAULTS = {
    crit          = true,   -- include average crit (direct heals and HoT ticks)
    group         = true,   -- multiply group heals by number of targets
    untrained     = true,   -- show ranks available at your level but not trained
    hotByDuration = false,  -- HoT HPS = total / HoT duration instead of / cast time
    sort          = "spell",
    minimap       = { hide = false },   -- LibDBIcon button settings (position, hidden)
}

-- Per-character data (depends on the character's level, talents and gear)
local CHAR_DEFAULTS = {
    observed      = {},     -- [spellID] = { dur = seconds, sig = talentSignature }
    samples       = {},     -- [spellID] = tooltip values at low/high healing power
    healMode      = {},     -- [spell name] = whether talent healing % is in the tooltip
    dataVersion   = 0,
}

-- Copies every missing default into `dst` (recursively for tables).
local function MergeDefaults(dst, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            MergeDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

-- ============================================================
-- SMALL HELPERS
-- ============================================================
local function Clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

local function FmtInt(n)
    n = math.floor((n or 0) + 0.5)
    local s = tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (s:gsub("^,", ""))
end

-- 2.50 -> "2.5", 3.00 -> "3", 1.75 -> "1.75"
local function FmtSec(x)
    local s = ("%.2f"):format(x or 0):gsub("%.?0+$", "")
    return s
end

local function Clean(s)
    if not s then return "" end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("[\r\n]+", " ")
    return s
end

-- WoW Forever (like Midnight) can hand addons "secret" values, e.g. a unit's health
-- or power in combat. They can't be compared, printed or used in math, so every
-- piece of unit data goes through these checks before the addon branches on it.
local function Secret(v)
    return issecretvalue ~= nil and issecretvalue(v) or false
end
ns.Secret = Secret

-- Returns v if it is usable (not secret, right type), else the fallback.
local function Usable(v, kind, fallback)
    if v == nil or Secret(v) or type(v) ~= kind then return fallback end
    return v
end

local function PlayerLevel()
    return Usable(UnitLevel("player"), "number", 1)
end

local function PlayerClass()
    local _, class = UnitClass("player")
    return Usable(class, "string", "UNKNOWN")
end

-- ============================================================
-- ERROR CAPTURE
-- Errors are caught instead of spamming the screen. The first one prints a single
-- chat line; /hra errors opens a window where every error can be copied.
-- ============================================================
local ERRORS = {}
local errorNotified = false

local function ReportError(err, stack)
    local msg = tostring(err)
    for _, e in ipairs(ERRORS) do
        if e.msg == msg then e.count = e.count + 1; return end
    end
    if #ERRORS >= 25 then return end
    ERRORS[#ERRORS + 1] = { msg = msg, stack = stack or "", count = 1, time = date and date("%H:%M:%S") or "" }
    if not errorNotified then
        errorNotified = true
        print("|cffff4040HealRankAdvisor:|r an error was caught. Type |cffffff00/hra errors|r to view and copy it.")
    end
end
HRA.errors = ERRORS

-- Runs fn(...) and catches any error, so a bug never repeats on screen.
local function Safe(fn, ...)
    local n, args = select("#", ...), { ... }
    local ok, a, b, c = xpcall(function() return fn(unpack(args, 1, n)) end,
        function(e) ReportError(e, debugstack and debugstack(2) or nil); return e end)
    if ok then return a, b, c end
end
ns.Safe = Safe

-- ============================================================
-- API WRAPPERS
-- Forever uses the Mainline API: spell data comes from C_Spell / C_SpellBook /
-- C_TooltipInfo, never from the old globals (GetSpellInfo etc. don't exist).
-- Every function is checked before use, and strings are checked for secrets.
-- ============================================================
local function Str(v) return (type(v) == "string" and not Secret(v)) and v or nil end
local function Num(v) return (type(v) == "number" and not Secret(v)) and v or nil end

local function SpellName(id)
    if not id or not (C_Spell and C_Spell.GetSpellName) then return nil end
    return Str(C_Spell.GetSpellName(id))
end

local function CastMs(id)
    if C_Spell and C_Spell.GetSpellInfo then
        local i = C_Spell.GetSpellInfo(id)          -- returns a table (or nil until cached)
        if type(i) == "table" then return Num(i.castTime) or 0 end
    end
    return 0
end

local function SpellSubtext(id)
    if C_Spell and C_Spell.GetSpellSubtext then
        local s = Str(C_Spell.GetSpellSubtext(id))
        if s and s ~= "" then return s end
    end
end

local function IsPassive(id)
    if C_Spell and C_Spell.IsSpellPassive then return C_Spell.IsSpellPassive(id) == true end
    return false
end

local function Known(id)
    if IsPlayerSpell and IsPlayerSpell(id) == true then return true end
    if C_SpellBook and C_SpellBook.IsSpellKnown then
        local ok, known = pcall(C_SpellBook.IsSpellKnown, id)
        if ok and known == true then return true end
    end
    return false
end

local function LearnLevel(id, fallback)
    local fn = (C_Spell and C_Spell.GetSpellLevelLearned) or GetSpellLevelLearned
    if fn then
        local ok, l = pcall(fn, id)
        l = ok and Num(l)
        if l and l > 0 then return l end
    end
    return fallback or 0
end

local function ManaCost(id)
    local costs = C_Spell and C_Spell.GetSpellPowerCost and C_Spell.GetSpellPowerCost(id)
    if type(costs) == "table" then
        for _, c in ipairs(costs) do
            if c.type == 0 or c.name == "MANA" then
                local v = Num(c.cost) or 0
                local pct = Num(c.costPercent) or 0
                if v == 0 and pct > 0 then
                    v = Usable(UnitPowerMax("player", 0), "number", 0) * pct / 100
                end
                return v
            end
        end
    end
    return 0
end

-- Hidden tooltip, only used if C_TooltipInfo can't describe a spell or talent.
local scanTip = CreateFrame("GameTooltip", "HRAScanTooltip", nil, "GameTooltipTemplate")
scanTip:SetScript("OnUpdate", nil)   -- a scanning tooltip never needs to refresh itself
scanTip:Hide()

-- Spell data that hasn't loaded yet: requested here, re-read on SPELL_DATA_LOAD_RESULT.
HRA.pendingLoads = {}

local function RequestSpellLoad(id)
    if C_Spell and C_Spell.RequestLoadSpellData and id then
        HRA.pendingLoads[id] = true
        C_Spell.RequestLoadSpellData(id)
    end
end

local function TooltipDesc(id)
    if C_TooltipInfo and C_TooltipInfo.GetSpellByID then
        local ok, data = pcall(C_TooltipInfo.GetSpellByID, id)
        if ok and type(data) == "table" and type(data.lines) == "table" then
            for i = #data.lines, 1, -1 do               -- the description is the last line
                local tx = Str(data.lines[i].leftText)
                if tx and tx ~= "" then return tx end
            end
        end
    end
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:ClearLines()
    if not pcall(scanTip.SetSpellByID, scanTip, id) then scanTip:Hide(); return "" end
    local n = scanTip:NumLines()
    local fs = n and n > 0 and _G["HRAScanTooltipTextLeft" .. n]
    local text = fs and Str(fs:GetText()) or ""
    scanTip:Hide()
    return text
end

local function SpellDesc(id)
    local d
    if C_Spell and C_Spell.GetSpellDescription then d = Str(C_Spell.GetSpellDescription(id)) end
    if not d or d == "" then d = TooltipDesc(id) end
    if not d or d == "" then
        RequestSpellLoad(id)
        return ""
    end
    return Clean(d)
end

-- True while the game hides combat information (auras etc.) from addons.
local function AurasRestricted()
    if InCombatLockdown and InCombatLockdown() then return true end
    if C_Secrets and C_Secrets.ShouldAurasBeSecret then
        local ok, secret = pcall(C_Secrets.ShouldAurasBeSecret)
        if ok and secret == true then return true end
    end
    return false
end

local function IterSpellbook(cb)
    if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookSkillLineInfo
            and C_SpellBook.GetSpellBookItemInfo and Enum and Enum.SpellBookSpellBank) then
        return
    end
    for tab = 1, C_SpellBook.GetNumSpellBookSkillLines() do
        local info = C_SpellBook.GetSpellBookSkillLineInfo(tab)
        if type(info) == "table" and not info.shouldHide then
            for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                local it = C_SpellBook.GetSpellBookItemInfo(i, Enum.SpellBookSpellBank.Player)
                if type(it) == "table" and Num(it.spellID) and not it.isPassive then
                    cb(it.spellID, Str(it.name), Str(it.subName))
                end
            end
        end
    end
end

-- ============================================================
-- TOOLTIP PARSER
-- Returns { min, max, hotTotal, tick, interval, dur, targets } or nil
-- ============================================================
local UNIT_SEC = { sec = 1, secs = 1, second = 1, seconds = 1, min = 60, mins = 60, minute = 60, minutes = 60 }

function ns.ParseHeal(desc, requireHealWord)
    if not desc or desc == "" then return nil end
    local t = Clean(desc):gsub("(%d),(%d%d%d)", "%1%2"):lower()
    local p = {}

    local hpos = t:find("heal[^t]") or t:find("heal$")
    if not hpos then
        if requireHealWord then return nil end
        hpos = 1
    end

    -- Direct heal: "for 93 to 107"
    local a, b = t:match("(%d+) to (%d+)", hpos)
    if not a then a, b = t:match("(%d+) to (%d+) heal") end
    if a then p.min, p.max = tonumber(a), tonumber(b) end

    -- Direct heal with a single value: "heals them for 800"
    if not p.min then
        local init = 1
        while true do
            local s, e, word, n = t:find("(heal%a*)[^%.]-for (%d+)", init)
            if not s then break end
            local after = t:sub(e + 1, e + 9)
            local bad = word:find("^health")
                or after:find("^ over") or after:find("^ every") or after:find("^ sec")
                or after:find("^ min") or after:find("^%%") or after:find("^ yard")
                or after:find("^ damage") or after:find("^ to ") or after:find("^%.%d")
            if not bad then p.min, p.max = tonumber(n), tonumber(n) break end
            init = s + 4
        end
    end

    -- Heal over time: "for 98 over 21 sec" / "of 45 damage over 15 sec"
    local tot, dur, unit = t:match("(%d+)[%a ]-over (%d+) (%a+)")
    if tot and UNIT_SEC[unit] then
        p.hotTotal = tonumber(tot)
        p.dur = tonumber(dur) * UNIT_SEC[unit]
    else
        -- Ticking effect: "for 98 every 2 seconds for 10 sec" / totem "for 1 min ... for 6 every 2 seconds"
        local _, e, tick, interval = t:find("(%d+) every (%d+) sec")
        if tick then
            p.tick, p.interval = tonumber(tick), tonumber(interval)
            local d, u = t:match("^[^%.]-for (%d+) (%a+)", e + 1)
            if not (d and UNIT_SEC[u]) then d, u = t:match("for (%d+) (min%a*)") end
            if not (d and UNIT_SEC[u]) then d, u = t:match("lasts (%d+) (%a+)") end
            if d and UNIT_SEC[u] then p.dur = tonumber(d) * UNIT_SEC[u] end
        end
    end

    -- Number of targets
    local total = t:match("(%d+) total targets")
    local fall  = t:match("effectiveness of the heal by (%d+)%%") or t:match("reduc%a* [^%.]-by (%d+)%%")
    if total and t:find("jump") then
        total = tonumber(total)
        local r = fall and (1 - tonumber(fall) / 100) or 1
        local f, m = 0, 1
        for _ = 1, total do f = f + m; m = m * r end
        p.targets = f
    else
        local n = t:match("up to (%d+) [%a ]-member") or t:match("up to (%d+) friendly")
               or t:match("up to (%d+) target") or t:match("up to (%d+) all")
               or t:match("up to (%d+) times") or t:match("(%d+) times")
        if n then
            p.targets = tonumber(n)
        elseif t:find("party members") or t:find("group members") or t:find("raid members") then
            p.targets = 5
        elseif t:find("and the caster") or t:find("and yourself") or t:find("and you ") then
            p.targets = 2
        end
    end

    -- Volleys: "...or 126 healing to an ally, instantly and every 1 sec for 2 sec" (Penance)
    -- = one bolt now plus one per interval: 3 bolts over a 2 sec channel.
    if not p.min and not p.hotTotal then
        local iv, d = t:match("instantly and every (%d+) sec for (%d+) sec")
        if iv and tonumber(iv) > 0 then
            local lo, hi = t:match("(%d+) to (%d+) healing")
            if not lo then lo = t:match("(%d+) healing"); hi = lo end
            if lo then
                local bolts = 1 + math.floor(tonumber(d) / tonumber(iv) + 0.001)
                p.min, p.max = tonumber(lo) * bolts, tonumber(hi) * bolts
                p.bolts, p.boltMin, p.boltMax = bolts, tonumber(lo), tonumber(hi)
                p.dur = tonumber(d)                 -- channel time
                p.tick, p.interval = nil, nil
            end
        end
    end

    -- Absorb shields: "absorbing 48 damage" (Power Word: Shield)
    if not p.min and not p.hotTotal and not p.tick then
        local n = t:match("absorbing (%d+) damage") or t:match("absorbs? (%d+) damage")
        if n then p.min, p.max, p.absorb = tonumber(n), tonumber(n), true end
    end

    if p.min or p.hotTotal or p.tick then return p end
    return nil
end

-- ============================================================
-- TALENT DETECTION
-- Builds { cast = { [spell] = {amount, sources} }, dur = { ... } }
-- ============================================================
local function SplitNames(s)
    local names = {}
    s = s:gsub(" and ", ","):gsub("%s*,%s*", ",")
    for n in s:gmatch("[^,]+") do
        n = n:gsub("^%s+", ""):gsub("%s+$", "")
        if n ~= "" then names[#names + 1] = n end
    end
    return names
end

local function AddMod(tbl, spell, amount, src)
    local m = tbl[spell]
    if not m then m = { amount = 0, sources = {} }; tbl[spell] = m end
    m.amount = m.amount + amount
    m.sources[#m.sources + 1] = src
end

-- Turns "your Smite, Holy Fire, and instant cast spells" into spell names / categories:
--   "*" = all heals, "@instant" = instant casts, "@holy" / "@nature" = that school
local function TalentTargets(chunk)
    chunk = chunk:gsub("^%s+", ""):gsub("%s+$", "")
    chunk = chunk:match(".*your (.*)") or chunk:match(".* of (.*)") or chunk
    chunk = chunk:gsub(" spells?$", ""):gsub(" abilit%a+$", "")
    local out = {}
    for _, n in ipairs(SplitNames(chunk)) do
        n = n:gsub(" spells?$", ""):gsub("^the ", "")
        if n == "spells" or n == "healing" or n == "heals" or n == "healing spell" then
            out[#out + 1] = "*"
        elseif n:find("instant") then
            out[#out + 1] = "@instant"
        elseif n == "holy" then
            out[#out + 1] = "@holy"
        elseif n == "nature" then
            out[#out + 1] = "@nature"
        elseif n ~= "" then
            out[#out + 1] = n
        end
    end
    return out
end

local function Pct(str) return str and tonumber((str:gsub("%.$", ""))) end

-- Reads one talent's tooltip text into mods.{cast, dur, heal, cost, crit}.
-- Only the talent's CURRENT rank text is passed in, so values are already per rank.
function ns.ParseTalentText(text, mods, src)
    local t = text:lower() .. ". "
    local found = false
    for clause in t:gmatch("(.-)%.%s") do
        local conditional = clause:find("when activated") or clause:find("your next") or clause:find(" when cast on")
            or clause:find("after ") or clause:find("chance to ")

        -- Crit shields: "Your non-periodic critical heals create a protective shield on the
        -- target, absorbing 15% of the amount healed" (Divine Aegis)
        if clause:find("critical heal") and clause:find("absorb") then
            local pct = Pct(clause:match("absorbing ([%d%.]+)%%"))
            if pct and pct > 0 then
                AddMod(mods.aegis, "*", pct, src)
                found = true
            end

        -- Mana cost: "Reduces the mana cost of your Smite, Holy Fire, and instant cast spells by 9%"
        elseif clause:find("mana cost") and (clause:find("reduc") or clause:find("decreas") or clause:find("lower"))
           and not conditional then
            local chunk, pct = clause:match("mana cost of (.-) by ([%d%.]+)%%")
            pct = Pct(pct)
            if chunk and pct and pct > 0 then
                for _, n in ipairs(TalentTargets(chunk)) do AddMod(mods.cost, n, pct, src) end
                found = true
            end

        -- Crit: "Increases the critical effect chance of your Holy spells by 5%"
        elseif clause:find("critical") and clause:find("chance") and clause:find("increas") and not conditional then
            local chunk, pct = clause:match("critical %a+ chance of (.-) by ([%d%.]+)%%")
            if not chunk then chunk, pct = clause:match("critical %a+ chance for (.-) by ([%d%.]+)%%") end
            pct = Pct(pct)
            if chunk and pct and pct > 0 then
                for _, n in ipairs(TalentTargets(chunk)) do AddMod(mods.crit, n, pct, src) end
                found = true
            end

        -- Healing %: "Increases the amount healed by your Renew spell by 15%",
        -- "...damage and healing of your instant cast spells by 5%", "...effect of your Rejuvenation spell by 15%"
        elseif clause:find("increas") and (clause:find("heal") or clause:find("effect of your") or clause:find("absorb"))
               and not conditional
               and not clause:find("duration") then
            local chunk, pct = clause:match("healed by (.-) by ([%d%.]+)%%")
            if not chunk then chunk, pct = clause:match("absorbed by (your .-) by ([%d%.]+)%%") end
            if not chunk then chunk, pct = clause:match("effect of (your .-) by ([%d%.]+)%%") end
            if not chunk then chunk, pct = clause:match("healing done by (.-) by ([%d%.]+)%%") end
            if not chunk then chunk, pct = clause:match("healing of (.-) by ([%d%.]+)%%") end
            pct = Pct(pct)
            if chunk and pct and pct > 0 then
                for _, n in ipairs(TalentTargets(chunk)) do AddMod(mods.heal, n, pct, src) end
                found = true
            end
        end

        -- Cast time / HoT duration: "...by 0.5 sec"
        local isDur  = clause:find("increases? the duration") or (clause:find("duration") and clause:find("extend"))
        local isCast = (not isDur) and clause:find("cast%a* time") and not clause:find("mana cost")
                       and (clause:find("reduc") or clause:find("decreas") or clause:find("shorten"))
        if isDur or isCast then
            for chunk, amt in clause:gmatch("([^%d]-) by ([%d%.]+) sec") do
                local names = chunk:match(".*your (.*)") or chunk:match(".* of (.*)") or chunk
                names = names:gsub("^[%s,]+", ""):gsub("^and ", ""):gsub(" spells?$", ""):gsub(" abilit%a+$", "")
                local a = Pct(amt)
                if a and a > 0 then
                    for _, n in ipairs(SplitNames(names)) do
                        AddMod(isDur and mods.dur or mods.cast, n, a, src)
                        found = true
                    end
                end
            end
        end
    end
    return found
end

-- Sum of a talent effect that applies to a spell: its own name plus matching categories.
local function Applicable(tbl, def, isInstant, school, namedOnly)
    local total, srcs, schoolWide = 0, {}, 0
    local function take(key, isSchool)
        local m = tbl and tbl[key]
        if not m then return end
        total = total + m.amount
        if isSchool then schoolWide = schoolWide + m.amount end
        for _, sname in ipairs(m.sources) do srcs[#srcs + 1] = sname end
    end
    take(def.lname)
    if namedOnly then return total, table.concat(srcs, ", "), schoolWide end
    take("*")
    if isInstant then take("@instant") end
    if school == 2 then take("@holy", true) end
    if school == 4 then take("@nature", true) end
    return total, table.concat(srcs, ", "), schoolWide
end
ns.Applicable = Applicable

-- ============================================================
-- READING TALENTS
-- WoW Forever has no GetNumTalentTabs / GetTalentInfo. Its talent frame uses the
-- modern trait system (C_ClassTalents / C_Traits): a config holds trees, trees
-- hold nodes, and each node has a rank and an entry whose spell is the talent.
-- Every talent with points becomes { name, rank, maxRank, entryID, spellID }.
-- ============================================================
local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
end

-- Talents read through the trait system for one config
local function ReadTraitConfig(configID)
    local ci = Call(C_Traits.GetConfigInfo, configID)
    if type(ci) ~= "table" or type(ci.treeIDs) ~= "table" then return nil end
    local list, points = {}, 0
    for _, treeID in ipairs(ci.treeIDs) do
        local nodes = Call(C_Traits.GetTreeNodes, treeID)
        for _, nodeID in ipairs(type(nodes) == "table" and nodes or {}) do
            local ni = Call(C_Traits.GetNodeInfo, configID, nodeID)
            if type(ni) == "table" then
                local rank = ni.activeRank or ni.currentRank or ni.ranksPurchased or 0
                if type(rank) == "number" and not Secret(rank) and rank > 0 then
                    local entryID = (type(ni.activeEntry) == "table" and ni.activeEntry.entryID)
                        or (type(ni.entryIDs) == "table" and ni.entryIDs[1])
                    local name, spellID
                    if entryID then
                        local ei = Call(C_Traits.GetEntryInfo, configID, entryID)
                        if type(ei) == "table" and ei.definitionID then
                            local di = Call(C_Traits.GetDefinitionInfo, ei.definitionID)
                            if type(di) == "table" then
                                spellID = di.spellID or di.overriddenSpellID
                                if type(di.overrideName) == "string" and di.overrideName ~= "" then name = di.overrideName end
                            end
                        end
                    end
                    if not name and spellID then name = SpellName(spellID) end
                    if name then
                        list[#list + 1] = { name = name, rank = rank, maxRank = ni.maxRanks or rank,
                                            entryID = entryID, spellID = spellID, nodeID = nodeID }
                        points = points + rank
                    end
                end
            end
        end
    end
    return list, points
end

local function ReadTalentsTraits()
    if not (C_Traits and C_Traits.GetConfigInfo and C_Traits.GetTreeNodes and C_Traits.GetNodeInfo) then return nil end
    local group = Call(C_SpecializationInfo and C_SpecializationInfo.GetActiveSpecGroup)
        or Call(GetActiveSpecGroup) or 1

    -- Config IDs from every read-only "Get...ConfigID..." function C_ClassTalents offers
    -- (the active config, and the spec group's config Forever's talent frame uses).
    local candidates, seen = {}, {}
    local function add(id, prio)
        if type(id) == "number" and not Secret(id) and id > 0 and not seen[id] then
            seen[id] = true
            candidates[#candidates + 1] = { id = id, prio = prio }
        end
    end
    if C_ClassTalents then
        for fname, fn in pairs(C_ClassTalents) do
            if type(fn) == "function" and fname:find("^Get") and fname:find("ConfigID") then
                local prio = (fname:find("Combat") or fname:find("SpecGroup")) and 1
                    or (fname:find("Active") and 2) or 3
                local r = Call(fn, group)
                if type(r) == "table" then
                    for _, v in ipairs(r) do add(v, prio) end
                else
                    add(r, prio)
                end
            end
        end
    end
    table.sort(candidates, function(a, b) if a.prio ~= b.prio then return a.prio < b.prio end return a.id < b.id end)

    local best, bestPts, bestID
    for _, c in ipairs(candidates) do
        local list, pts = ReadTraitConfig(c.id)
        if list and pts > 0 then return list, ("traits, config %d"):format(c.id) end
        if list and not best then best, bestPts, bestID = list, pts, c.id end
    end
    if best then return best, ("traits, config %d"):format(bestID) end
    return nil
end

-- Reads talents once per refresh; the result is cached for the cast-learning code.
function HRA:ReadTalents()
    local list, method = ReadTalentsTraits()
    list = list or {}
    table.sort(list, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return (a.nodeID or 0) < (b.nodeID or 0)
    end)
    local parts = {}
    for _, t in ipairs(list) do parts[#parts + 1] = (t.nodeID or t.name) .. "=" .. t.rank end
    self.talents, self.talentMethod = list, method or "none found"
    self.lastSig = table.concat(parts, ";")
    return list
end

local function TalentSig()
    if HRA.lastSig then return HRA.lastSig end
    HRA:ReadTalents()
    return HRA.lastSig
end

local function TooltipLines(data)
    local parts = {}
    if type(data) ~= "table" or type(data.lines) ~= "table" then return parts end
    for idx, line in ipairs(data.lines) do
        local tx = line.leftText
        if idx > 1 and type(tx) == "string" and not Secret(tx) then
            if tx:lower():find("^next rank") then break end
            parts[#parts + 1] = Clean(tx)
        end
    end
    return parts
end

-- Text of a talent at its CURRENT rank. Returns text, fromTooltip.
local function TalentText(t)
    local parts = {}
    if t.entryID then
        if C_TooltipInfo and C_TooltipInfo.GetTraitEntry then
            parts = TooltipLines(Call(C_TooltipInfo.GetTraitEntry, t.entryID, t.rank))
        end
        if #parts == 0 and scanTip.SetTraitEntry then
            scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
            scanTip:ClearLines()
            if pcall(scanTip.SetTraitEntry, scanTip, t.entryID, t.rank) then
                for idx = 2, scanTip:NumLines() do
                    local fs = _G["HRAScanTooltipTextLeft" .. idx]
                    local tx = fs and fs:GetText()
                    if type(tx) == "string" and not Secret(tx) then
                        if tx:lower():find("^next rank") then break end
                        parts[#parts + 1] = Clean(tx)
                    end
                end
            end
            scanTip:Hide()
        end
    end
    if #parts > 0 then return table.concat(parts, ". "), true end
    -- Last resort: the talent spell's own description (may only describe rank 1)
    if t.spellID then return SpellDesc(t.spellID), false end
    return "", false
end

function HRA:GetTalentMods(talents)
    local mods = { cast = {}, dur = {}, heal = {}, cost = {}, crit = {}, aegis = {} }
    talents = talents or self.talents or self:ReadTalents()
    for _, t in ipairs(talents) do
        local name, rank = t.name, t.rank
        local src = ("%s %d"):format(name, rank)
        local fb = ns.TALENT_FALLBACK[name]
        local text, fromTooltip = TalentText(t)
        local found = false
        -- A spell description only shows rank 1; for multi-rank talents with a
        -- fallback entry, trust the fallback (it multiplies by your rank) instead.
        if text ~= "" and (fromTooltip or (t.maxRank or 1) <= 1 or not fb) then
            found = ns.ParseTalentText(text, mods, src)
        end
        if not found and fb then
            local mult = fb.perRank and rank or 1
            for sp, v in pairs(fb.cast or {}) do AddMod(mods.cast, sp, v * mult, src .. "*") end
            for sp, v in pairs(fb.dur  or {}) do AddMod(mods.dur,  sp, v * mult, src .. "*") end
            for sp, v in pairs(fb.heal or {}) do AddMod(mods.heal, sp, v * mult, src .. "*") end
            for sp, v in pairs(fb.cost or {}) do AddMod(mods.cost, sp, v * mult, src .. "*") end
            for sp, v in pairs(fb.crit or {}) do AddMod(mods.crit, sp, v * mult, src .. "*") end
            for sp, v in pairs(fb.aegis or {}) do AddMod(mods.aegis, sp, v * mult, src .. "*") end
        end
    end
    return mods
end

-- ============================================================
-- SPELL DISCOVERY
-- ============================================================
ns.HOT_IDS = {}
for _, defs in pairs(ns.SPELLS) do
    for i, def in ipairs(defs) do
        def.order = i
        def.lname = def.name:lower()
        if def.hot then for _, r in ipairs(def.ranks) do ns.HOT_IDS[r[1]] = true end end
    end
end

local autoDefs = {}

function HRA:BuildEntries()
    local class = PlayerClass()
    local defs = ns.SPELLS[class] or {}
    local byName = {}
    for _, def in ipairs(defs) do byName[def.lname] = def end

    local entries, seen = {}, {}
    local function add(e)
        if seen[e.id] then return end
        seen[e.id] = true
        entries[#entries + 1] = e
    end

    -- 1) Every rank in the data table (finds untrained ranks too)
    for _, def in ipairs(defs) do
        for ri, r in ipairs(def.ranks) do
            local id = r[1]
            if type(id) == "table" then
                -- Several spells share the name (e.g. Penance's hidden bolt spells):
                -- take the first candidate whose tooltip actually reads as a heal.
                local pick
                for _, cand in ipairs(id) do
                    local cn = SpellName(cand)
                    if cn and cn:lower() == def.lname and ns.ParseHeal(SpellDesc(cand), false) then
                        pick = cand
                        break
                    end
                end
                id = pick
            end
            local nm = id and SpellName(id)
            if nm and nm:lower() == def.lname then
                add({ id = id, def = def, rank = ri, level = LearnLevel(id, r[2]),
                      baseCast = r[3], known = Known(id) })
            end
        end
    end

    -- 2) Spellbook: catches changed spell IDs and brand-new WoW Forever heals
    local autoCount = 0
    IterSpellbook(function(id, name, sub)
        if not id or not name or seen[id] or IsPassive(id) then return end
        local lname = name:lower()
        sub = sub or SpellSubtext(id) or ""
        local rank = tonumber(sub:match("(%d+)")) or 0
        local def = byName[lname]
        if def then
            local r = def.ranks[rank]
            add({ id = id, def = def, rank = rank, level = LearnLevel(id, r and r[2]),
                  baseCast = r and r[3], known = true })
        elseif not ns.AUTO_BLACKLIST[lname] then
            local p = ns.ParseHeal(SpellDesc(id), true)
            if p and ManaCost(id) > 0 then
                local ad = autoDefs[lname]
                if not ad then
                    autoCount = autoCount + 1
                    ad = { name = name, lname = lname, auto = true, order = 100 + autoCount, ranks = {} }
                    autoDefs[lname] = ad
                end
                if p.hotTotal then ns.HOT_IDS[id] = true end
                add({ id = id, def = ad, rank = rank, level = LearnLevel(id), known = true })
            end
        end
    end)
    return entries
end

-- ============================================================
-- COMPUTATION
-- ============================================================

-- Note: the original game's below-level-20 penalty does NOT exist in WoW Forever.
-- In-game tooltips (level 30 priest, 16 vs 151 spell healing) show Heal rank 1
-- (learned at 16) and Renew rank 2 (learned at 14) keeping their full coefficient.

-- WoW Forever downranking nerf: once you are 18+ levels past the level a rank
-- is learned at, it loses 5% of its +healing coefficient per level.
--   share = 1 - (L - 17 - T) * 0.05, clamped to 0..1
--   L = your level, T = level the rank is learned at
-- Community measurements (levels 18-30); Blizzard confirmed the mechanic without numbers.
-- Confirmed against in-game tooltips for Lesser Heal 2-3, Renew 1-4 and Heal 1-3 at
-- level 30. Lesser Heal rank 1 kept less than predicted (~24% vs 40%), so the addon
-- prefers coefficients it measures from your own tooltips (see HRA:LearnSlope).
ns.DOWNRANK_GRACE    = 17     -- full bonus while L - T <= 17
ns.DOWNRANK_PER_LVL  = 0.05   -- share lost per level beyond that

function ns.DownrankShare(playerLevel, learnLevel)
    if not playerLevel or not learnLevel or learnLevel <= 0 then return 1 end
    return Clamp(1 - (playerLevel - ns.DOWNRANK_GRACE - learnLevel) * ns.DOWNRANK_PER_LVL, 0, 1)
end
-- Remembers each rank's tooltip value at the lowest and highest healing power seen
-- (same level and talents). Once they are 20+ apart, the slope is the rank's
-- true healing power coefficient including talents and the downranking penalty.
-- `expected` = the estimated healing per point of healing power. It is only used to
-- throw away readings that can't be right:
--   * the spell-healing number changed but the tooltip didn't (the game hadn't
--     updated the tooltip yet, e.g. right after swapping gear), or
--   * the tooltip went DOWN as spell healing went up, or rose impossibly fast
--     (a temporary buff such as Power Infusion was active for one of the readings).
-- A measured slope that can't be right: the tooltip went DOWN as healing power went
-- up, or rose impossibly fast (e.g. a temporary buff during one of the readings).
-- Tooltips round to whole numbers, hence the tolerance.
local function PlausibleSlope(slope, dsp, expected)
    local tol = 2 / dsp
    if slope < -tol then return false, "the heal went down as healing power went up" end
    if slope > math.max(1.6, (expected or 0) * 2.5) then return false, "the heal rose impossibly fast (a buff?)" end
    return true
end

-- Keeps each rank's tooltip value at the lowest and highest healing power seen
-- (same level and talents) and returns the slope between them once they are 20+
-- apart. With record = false it only reads what is stored.
function HRA:LearnSlope(id, level, sig, sp, value, expected, record)
    CDB.samples = CDB.samples or {}
    local s = CDB.samples[id]
    if not s or s.lvl ~= level or s.sig ~= sig then
        if not record then return nil end
        s = { lvl = level, sig = sig, lo = { sp, value }, hi = { sp, value } }
        CDB.samples[id] = s
    elseif record then
        local function ok(other)
            local dsp = sp - other[1]
            if math.abs(dsp) < 20 then return true end
            local good, why = PlausibleSlope((value - other[2]) / dsp, math.abs(dsp), expected)
            if not good then s.note = why end
            return good
        end
        if sp < s.lo[1] then
            if ok(s.hi) then s.lo = { sp, value } end
        elseif sp == s.lo[1] and ok(s.hi) then
            s.lo[2] = value
        end
        if sp > s.hi[1] then
            if ok(s.lo) then s.hi = { sp, value } end
        elseif sp == s.hi[1] and ok(s.lo) then
            s.hi[2] = value
        end
    end
    local dsp = s.hi[1] - s.lo[1]
    if dsp < 20 then return nil end
    local slope = (s.hi[2] - s.lo[2]) / dsp
    local good, why = PlausibleSlope(slope, dsp, expected)
    if not good then
        -- The stored readings disagree with each other: start over from this one
        CDB.samples[id] = { lvl = level, sig = sig, lo = { sp, value }, hi = { sp, value }, note = why }
        return nil
    end
    return math.max(slope, 0), s.lo[1], s.hi[1]
end

-- Why a rank has no measurement yet (for its row tooltip).
function HRA:SampleStatus(id)
    local s = CDB.samples and CDB.samples[id]
    if not s then return "no readings yet" end
    local txt
    if s.hi[1] - s.lo[1] < 20 then
        txt = ("read at %d healing power so far; change it by 20+ and Refresh"):format(s.lo[1])
    else
        txt = ("read at %d and %d healing power"):format(s.lo[1], s.hi[1])
    end
    if s.note then txt = txt .. " (last reading ignored: " .. s.note .. ")" end
    return txt
end

function HRA:ComputeEntry(e, mods, sig, bonus, critPct, playerLevel)
    local def  = e.def
    local desc = SpellDesc(e.id)
    local row  = { e = e, id = e.id, name = def.name, rank = e.rank, level = e.level,
                   known = e.known, desc = desc }
    local p = ns.ParseHeal(desc, false)
    if not p then row.pending = true; return row end
    row.parsed = p

    -- ---- Cast time (client value already includes talents & haste) ----
    local castNow = CastMs(e.id) / 1000
    local cast = castNow
    local cm = mods.cast[def.lname]
    if cm and cm.amount > 0 then
        local srcs = table.concat(cm.sources, ", ")
        if e.baseCast and castNow > 0 and math.abs(castNow - e.baseCast) < 0.02 then
            cast = math.max(0, castNow - cm.amount)
            row.castAdjusted = true
            row.castNote = ("-%ss from %s (applied by addon)"):format(FmtSec(cm.amount), srcs)
        elseif e.baseCast and castNow < e.baseCast - 0.02 then
            row.castNote = ("%s already included in client cast time"):format(srcs)
        else
            row.castNote = ("%s detected; client cast time used"):format(srcs)
        end
    end

    -- ---- Duration ----
    local ttDur = p.dur
    local isPeriodic = p.hotTotal or p.tick
    if isPeriodic and not ttDur then ttDur = def.baseDur end
    local effDur, durSrc = ttDur, "tooltip"
    if isPeriodic and not def.channel and not def.totem then
        local dm = mods.dur[def.lname]
        if dm and dm.amount > 0 and ttDur then
            local srcs = table.concat(dm.sources, ", ")
            if def.baseDur and math.abs(ttDur - def.baseDur) < 0.05 then
                effDur, durSrc = ttDur + dm.amount, "talent"
                row.durNote = ("+%ss from %s (applied by addon)"):format(FmtSec(dm.amount), srcs)
            elseif def.baseDur and ttDur > def.baseDur then
                row.durNote = ("%s already included in tooltip"):format(srcs)
            else
                row.durNote = ("%s detected; cast once to verify"):format(srcs)
            end
        end
        local ob = CDB.observed[e.id]
        if ob and ob.dur and ob.sig == sig then
            effDur, durSrc = ob.dur, "observed"
        end
    end

    -- ---- Base amounts ----
    local direct = p.min and (p.min + p.max) / 2 or 0
    local hot = 0
    if p.hotTotal then
        hot = p.hotTotal
    elseif p.tick and ttDur and p.interval > 0 then
        hot = p.tick * math.floor(ttDur / p.interval + 0.001)
    end
    local durScale = 1
    if hot > 0 and ttDur and effDur and ttDur > 0 and math.abs(effDur - ttDur) > 0.05 then
        durScale = effDur / ttDur        -- extra ticks heal for the same amount
    end

    -- ---- Targets ----
    local tf = def.targets or p.targets or def.targetsDefault or 1
    local factor = DB.group and tf or 1

    -- ---- +Healing coefficients ----
    local cd, ch = 0, 0
    local castForCoef = e.baseCast or (castNow > 0 and castNow or GCD)
    if def.coefDirect or def.coefHot then
        cd, ch = def.coefDirect or 0, def.coefHot or 0
    elseif type(def.coef) == "number" then
        if direct > 0 then cd = def.coef else ch = def.coef end
    elseif def.coef == "cast" then
        cd = Clamp(castForCoef / 3.5, 1.5 / 3.5, 1)
    else -- auto-detected spell: generic vanilla formulas
        local c = Clamp(math.max(castNow, GCD) / 3.5, 1.5 / 3.5, 1)
        local h = (ttDur or 15) / 15
        if direct > 0 and hot > 0 then
            local sum = direct + hot
            cd, ch = c * direct / sum, h * hot / sum
        elseif direct > 0 then cd = c else ch = h end
        if tf > 1 then cd, ch = cd / 3, ch / 3 end
    end
    if direct <= 0 then cd = 0 end
    if hot <= 0 then ch = 0 end
    -- HoT coefficient covers the base duration; a tooltip that already shows a
    -- talent-extended duration also shows the extra ticks' +healing
    if ch > 0 and def.baseDur and ttDur and not def.channel and not def.totem then
        ch = ch * ttDur / def.baseDur
    end

    -- ---- Talent effects that apply to this spell ----
    local ctx       = self.ctx or {}
    local school    = ctx.school or 2
    local isInstant = castNow <= 0 and not def.channel
    -- Shields only get talents that name them (e.g. Improved Power Word: Shield)
    local healPct, healSrc = Applicable(mods.heal, def, isInstant, school, def.absorb)
    local costPct, costSrc = Applicable(mods.cost, def, isInstant, school)
    local critTal, critSrc, critSchoolWide = Applicable(mods.crit, def, isInstant, school)
    local M = 1 + healPct / 100

    -- ---- Healing power ----
    -- WoW Forever's tooltips already include your healing power, the downranking
    -- penalty and healing talents (verified in game), so the tooltip value is used
    -- as-is. The addon works out the healing power portion to show the coefficient
    -- and the base heal (what the spell heals with 0 healing power).
    local formulaShare = ns.DownrankShare(playerLevel, e.level)
    local share = formulaShare
    local expectedPerSP = (cd + ch) * formulaShare * M
    row.rawValue = direct + hot
    local slope, sLo, sHi = self:LearnSlope(e.id, playerLevel, sig, bonus, direct + hot, expectedPerSP,
        self.ctx and self.ctx.record)

    -- Is the talent healing % already in the tooltip? Assumed yes (verified in game for
    -- Improved Renew). Confirmed per spell once a rank that keeps its full +healing has
    -- a measured coefficient: slope / base coefficient equals the multiplier in the tooltip.
    CDB.healMode = CDB.healMode or {}
    local healIncluded, healVerified = true, false
    local hm = CDB.healMode[def.lname]
    if hm and hm.sig == sig then healIncluded, healVerified = (hm.mode == "included"), true end
    if slope and M > 1.005 and formulaShare >= 0.999 and (cd + ch) > 0 and slope >= 0.02 then
        local ratio = slope / (cd + ch)
        -- "missing" only when the measurement clearly sits at the untalented value
        healIncluded = not (math.abs(ratio - 1) < math.abs(ratio - M) and ratio > 0.8 and ratio < 1.2)
        healVerified = true
        CDB.healMode[def.lname] = { mode = healIncluded and "included" or "missing", sig = sig }
    end
    if M <= 1.005 then healIncluded, healVerified = true, false end
    local mult      = healIncluded and M or 1     -- healing % already inside the tooltip
    local extraMult = healIncluded and 1 or M     -- healing % the addon has to apply

    local estD, estH = cd * share * mult, ch * share * mult     -- per point of +healing
    local perD, perH = estD, estH
    local includes, measured = true, false
    local fullCoef = (cd + ch) * mult
    -- WoW Forever's tooltips always include +healing (verified in game), so a
    -- measurement only refines how much of the tooltip is +healing.
    if slope then
        measured = true
        local est = estD + estH
        if est > 0 then
            perD, perH = estD * slope / est, estH * slope / est
        else
            local sum = direct + hot
            perD = sum > 0 and slope * direct / sum or 0
            perH = sum > 0 and slope * hot / sum or 0
        end
        if fullCoef > 0 then share = Clamp(slope / fullCoef, 0, 1.5) end
    end
    local bD, bH = perD * bonus, perH * bonus
    local directBase = includes and math.max(direct - bD, 0) or direct
    local hotBase    = includes and math.max(hot - bH, 0) or hot

    -- ---- Crit ----
    -- In WoW Forever heals over time can crit too: every tick of a HoT or channelled
    -- heal (Renew, Rejuvenation, Regrowth's HoT, Tranquility) has the same crit chance
    -- as a direct heal. Shields never crit; totem heals are cast by the totem, not you.
    -- The character sheet / GetSpellCritChance() shows your base spell crit only:
    -- crit talents (Holy Specialization, Improved Regrowth, ...) are never in it
    -- (verified in game: 6.9% with 0 and with 5 points in Holy Specialization),
    -- so every crit talent that applies to this spell is added on top.
    local critAdd   = critTal
    local critTotal = Clamp(critPct + critAdd, 0, 100)
    local canCrit = not def.absorb and not def.totem and (direct > 0 or hot > 0)
    local critMult = 1
    if DB.crit and canCrit then critMult = 1 + (critTotal / 100) * 0.5 end

    local directNoCrit = (directBase + bD) * extraMult
    local directAvg = directNoCrit * critMult

    -- Divine Aegis: non-periodic crits also leave a shield worth X% of the crit heal.
    -- Expected extra = chance to crit x crit heal (1.5x) x X%. Counted with the Crit option.
    local aegisPct = (mods.aegis and mods.aegis["*"] and mods.aegis["*"].amount) or 0
    local aegisSrc = aegisPct > 0 and table.concat(mods.aegis["*"].sources, ", ") or nil
    local aegis = 0
    if DB.crit and aegisPct > 0 and direct > 0 and not def.absorb then
        aegis = directNoCrit * (critTotal / 100) * 1.5 * (aegisPct / 100)
        directAvg = directAvg + aegis
    end
    local hotAvg    = (hotBase + bH) * durScale * extraMult * critMult

    -- Healing power coefficient and base heal of one cast on one target (no crit):
    --   coefficient = extra healing per point of healing power (measured from your
    --                 tooltips at two healing power values, else estimated)
    --   base heal   = what the cast heals with 0 healing power
    local coefShown = (perD + perH * durScale) * extraMult
    local baseHeal  = (directBase + hotBase * durScale) * extraMult
    hot = hot * durScale
    local perTarget = directAvg + hotAvg
    local total     = perTarget * factor

    -- ---- Time used for HPS ----
    local time
    if def.channel then
        time = effDur or castNow
    else
        time = math.max(cast, GCD)
        if DB.hotByDuration and hotAvg > 0 and effDur and effDur > 0 and not def.totem then
            time = effDur
        end
    end

    -- ---- Mana cost ----
    -- The game's cost already includes cost talents (verified in game: Lesser Heal
    -- rank 3 shows 64 mana with Improved Healing 3/3, i.e. 75 - 15%), so it is used as-is.
    local clientCost = ManaCost(e.id)
    local mana = clientCost

    row.castNow, row.cast = castNow, cast
    row.absorb = def.absorb
    row.channel, row.totem = def.channel, def.totem
    row.ttDur, row.effDur, row.durSrc = ttDur, (hot > 0) and effDur or nil, durSrc
    row.direct, row.hot, row.bD, row.bH = direct, hot, bD, bH
    row.cd, row.ch, row.mult = cd, ch, mult
    row.healPct, row.healSrc, row.healIncluded, row.healVerified, row.extraMult = healPct, healSrc, healIncluded, healVerified, extraMult
    row.costPct, row.costSrc, row.clientCost = costPct, costSrc, clientCost
    row.critTal, row.critSrc = critTal, critSrc
    row.critAdd, row.critClient, row.critTotal = critAdd, critPct, critTotal
    row.bonusShare, row.shareMeasured = share, measured
    row.coef, row.baseHeal = coefShown, baseHeal
    row.slope, row.slopeLo, row.slopeHi = slope, sLo, sHi
    row.tooltipHasBonus = includes
    row.bonusAmt = (bD + bH * durScale) * extraMult
    row.spellHealing = bonus
    row.playerLevel = playerLevel
    row.critMult, row.critPct, row.canCrit = critMult, critTotal, canCrit
    row.aegis, row.aegisPct, row.aegisSrc = aegis, aegisPct, aegisSrc
    row.bolts, row.cooldown = p.bolts, def.cooldown
    row.tf, row.factor = tf, factor
    row.time, row.mana, row.total = time, mana, total
    row.directAvg, row.hotAvg = directAvg, hotAvg
    row.hps = (time and time > 0) and total / time or nil
    row.hpm = (mana and mana > 0) and total / mana or nil
    return row
end

function HRA:ComputeRows()
    local class = PlayerClass()
    local level = PlayerLevel()
    local entries = self:BuildEntries()
    local talents = self:ReadTalents()
    local mods = self:GetTalentMods(talents)
    local sig = self.lastSig
    local bonus = GetSpellBonusHealing and GetSpellBonusHealing() or 0
    if Secret(bonus) or type(bonus) ~= "number" then bonus = 0 end
    local school = ns.CLASS_SCHOOL[class] or 2
    local critPct = GetSpellCritChance and GetSpellCritChance(school) or 0
    if Secret(critPct) or type(critPct) ~= "number" then critPct = 0 end
    self.ctx = { school = school }
    -- Crit talents that cover all your heals (e.g. Holy Specialization), for the header line
    local schoolKey = (school == 2 and "@holy") or (school == 4 and "@nature") or nil
    local critTalent = (mods.crit["*"] and mods.crit["*"].amount or 0)
        + (schoolKey and mods.crit[schoolKey] and mods.crit[schoolKey].amount or 0)

    local function computeAll()
        local rows = {}
        for _, e in ipairs(entries) do
            local show = e.known or (DB.untrained and e.level > 0 and e.level <= level)
            if show then rows[#rows + 1] = self:ComputeEntry(e, mods, sig, bonus, critPct, level) end
        end
        return rows
    end

    -- Pass 1: read tooltips without recording a measurement.
    self.ctx.record = false
    local rows = computeAll()

    -- Right after a gear swap the game updates spell tooltips a moment later than
    -- the healing power number. If healing power changed since the last Refresh but
    -- not a single tooltip did, the tooltips are stale: don't record this reading.
    local values = {}
    for _, r in ipairs(rows) do if r.rawValue then values[r.id] = r.rawValue end end
    local prev, stale = self.lastSnapshot, false
    if prev and math.abs(bonus - prev.sp) >= 1 then
        stale = true
        for id, v in pairs(values) do
            if prev.values[id] and math.abs(prev.values[id] - v) > 0.01 then stale = false; break end
        end
    end
    self.lastSnapshot = { sp = bonus, values = values }
    self.tooltipsStale = stale

    -- Pass 2: record the reading and recompute with any new measurements.
    if not stale then
        self.ctx.record = true
        rows = computeAll()
        self.ctx.record = false
    end
    self.lastMods = mods
    return rows, { level = level, class = class, bonus = bonus, crit = critPct, critTalent = critTalent, school = school }
end

-- ============================================================
-- GUI
-- ============================================================
local MainFrame
local ROWS = {}
local LH = 18
local FRAME_W, FRAME_H = 810, 540
local SCROLL_LEFT = 20          -- scroll area inset from the window's left edge
local CHILD_W = FRAME_W - SCROLL_LEFT - 40

-- Palette (r, g, b)
local C = {
    bg        = { 0.118, 0.082, 0.051 },
    gold      = { 0.541, 0.416, 0.173 },
    goldLight = { 0.722, 0.569, 0.235 },
    outline   = { 0.169, 0.118, 0.055 },
    inner     = { 0.290, 0.212, 0.094 },
    rule      = { 0.420, 0.314, 0.137 },
    header    = { 0.831, 0.627, 0.090 },
    text      = { 0.902, 0.839, 0.682 },
    muted     = { 0.612, 0.553, 0.439 },
    legend    = { 0.720, 0.650, 0.520 },
}

local COLS = {
    { key = "name",  label = "Spell",    w = 150, justify = "LEFT",   sort = "spell" },
    { key = "rank",  label = "Rank",     w = 36,  justify = "CENTER" },
    { key = "level", label = "Lvl",      w = 30,  justify = "CENTER",
      tip = "Level the rank is learned at." },
    { key = "coef",  label = "Coef",     w = 50,  justify = "RIGHT",  sort = "coef",
      tip = "Healing power coefficient: extra healing per point of healing power, for one cast on one target. Measured from your tooltips; ~ = estimate until measured." },
    { key = "base",  label = "Base",     w = 50,  justify = "RIGHT",  sort = "baseHeal",
      tip = "Base heal: what one cast heals on one target with 0 healing power (no crit). ~ = estimate until measured." },
    { key = "cast",  label = "Cast",     w = 50,  justify = "RIGHT" },
    { key = "dur",   label = "HoT",      w = 40,  justify = "RIGHT" },
    { key = "mana",  label = "Mana",     w = 48,  justify = "RIGHT",  sort = "mana" },
    { key = "crit",  label = "Crit",     w = 46,  justify = "RIGHT" },
    { key = "heal",  label = "Avg Heal", w = 66,  justify = "RIGHT",  sort = "total",
      tip = "Average heal of one cast with your healing power and crit (group heals: all targets)." },
    { key = "hps",   label = "HPS",      w = 56,  justify = "RIGHT",  sort = "hps",
      tip = "Healing per second. Coloured red (lowest) to green (highest) within each spell." },
    { key = "hpm",   label = "HPM",      w = 52,  justify = "RIGHT",  sort = "hpm",
      tip = "Healing per mana. Coloured red (lowest) to green (highest) within each spell." },
}
do
    local x = 6
    for _, c in ipairs(COLS) do c.x = x; x = x + c.w + 6 end
end

local COLOR = {
    gold   = { 1.00, 0.82, 0.00 },
    white  = C.text,
    grey   = C.muted,
    yellow = { 1.00, 0.90, 0.30 },
    green  = { 0.40, 1.00, 0.40 },
}

local function Grad(v, lo, hi)
    if not v or not lo or hi <= lo then return 1, 1, 1 end
    local t = Clamp((v - lo) / (hi - lo), 0, 1)
    if t < 0.5 then
        local k = t * 2           -- red -> yellow
        return 1, 0.35 + 0.55 * k, 0.3
    end
    local k = (t - 0.5) * 2       -- yellow -> green
    return 1 - 0.6 * k, 0.9 + 0.1 * k, 0.3 + 0.1 * k
end

local function RowOnEnter(self)
    local r = self.data
    if not r then return end
    local GT = GameTooltip
    GT:SetOwner(self, "ANCHOR_RIGHT")
    GT:AddLine(("%s%s"):format(r.name, (r.rank and r.rank > 0) and (" (Rank " .. r.rank .. ")") or ""), 1, 0.82, 0)
    if not r.known then GT:AddLine("Not trained yet — visit your class trainer", 1, 0.4, 0.4) end
    if r.desc and r.desc ~= "" then GT:AddLine(r.desc, 0.85, 0.85, 0.85, true) end
    if r.pending then
        GT:AddLine("Spell data still loading or tooltip not understood.", 1, 0.5, 0.5, true)
        GT:Show()
        return
    end
    GT:AddLine(" ")
    if r.channel then
        GT:AddDoubleLine("Channel:", FmtSec(r.time) .. "s", 0.8, 0.8, 0.8, 1, 1, 1)
    else
        GT:AddDoubleLine("Cast time:", r.cast > 0 and (FmtSec(r.cast) .. "s") or "Instant (1.5s GCD)", 0.8, 0.8, 0.8, 1, 1, 1)
    end
    if r.castNote then GT:AddLine("  " .. r.castNote, 1, 0.9, 0.3, true) end
    if r.direct > 0 then
        local p = r.parsed
        if r.bolts then
            local p2 = r.parsed
            local bolt = (p2.boltMin == p2.boltMax) and tostring(p2.boltMin) or ("%d - %d"):format(p2.boltMin, p2.boltMax)
            GT:AddDoubleLine("Bolts (tooltip):", ("%d x %s = %s"):format(r.bolts, bolt, FmtInt(r.direct)), 0.8, 0.8, 0.8, 1, 1, 1)
            GT:AddLine("  each bolt can crit; the channel can be cut short by moving", 0.6, 0.6, 0.6, true)
        elseif r.absorb then
            GT:AddDoubleLine("Absorb (tooltip):", FmtInt(r.direct), 0.8, 0.8, 0.8, 1, 1, 1)
            GT:AddLine("  a damage shield, not a heal: it never crits or overheals,", 0.6, 0.6, 0.6, true)
            GT:AddLine("  but only counts if the target takes that much damage", 0.6, 0.6, 0.6, true)
            GT:AddLine("  Weakened Soul: same target can't be shielded again for 15 sec", 0.6, 0.6, 0.6, true)
        else
            GT:AddDoubleLine("Direct (tooltip):", ("%d - %d  (avg %s)"):format(p.min, p.max, FmtInt(r.direct)), 0.8, 0.8, 0.8, 1, 1, 1)
        end
    end
    if r.hot > 0 then
        local label = r.channel and "Channel heal:" or (r.totem and "Totem heal:" or "HoT:")
        GT:AddDoubleLine(label, ("%s over %ss"):format(FmtInt(r.hot), FmtSec(r.effDur or r.ttDur or 0)), 0.8, 0.8, 0.8, 1, 1, 1)
        if r.ttDur and r.effDur and math.abs(r.effDur - r.ttDur) > 0.05 then
            GT:AddLine(("  tooltip says %ss; using %ss (%s)"):format(FmtSec(r.ttDur), FmtSec(r.effDur), r.durSrc), 1, 0.9, 0.3, true)
        elseif r.durSrc == "observed" then
            GT:AddLine("  duration confirmed from your own aura", 0.4, 1, 0.4)
        elseif not r.channel and not r.totem then
            GT:AddLine("  duration from tooltip (cast it once to confirm)", 0.6, 0.6, 0.6)
        end
        if r.durNote then GT:AddLine("  " .. r.durNote, 1, 0.9, 0.3, true) end
        if r.effDur and r.effDur > 0 then
            GT:AddDoubleLine("  HoT rate:", ("%.1f per sec"):format(r.hotAvg / r.effDur), 0.6, 0.6, 0.6, 0.8, 0.8, 0.8)
        end
    end
    do
        local measured = r.shareMeasured
        GT:AddDoubleLine("Coefficient:", ("%s%.3f  (%s)"):format(measured and "" or "~", r.coef or 0,
            measured and "measured" or "estimate"), 0.8, 0.8, 0.8, measured and 0.4 or 1, 1, measured and 0.4 or 1)
        GT:AddDoubleLine("Base heal:", ("%s%s  at 0 healing power"):format(measured and "" or "~", FmtInt(r.baseHeal or 0)),
            0.8, 0.8, 0.8, 1, 1, 1)
        GT:AddDoubleLine("From healing power:", ("+%s  (%d x %.3f)"):format(FmtInt((r.coef or 0) * (r.spellHealing or 0)),
            r.spellHealing or 0, r.coef or 0), 0.8, 0.8, 0.8, 0.6, 1, 0.6)
        if measured then
            GT:AddLine(("  measured from your tooltips at %d and %d healing power"):format(r.slopeLo, r.slopeHi), 0.6, 0.6, 0.6)
        else
            GT:AddLine("  " .. HRA:SampleStatus(r.id), 0.6, 0.6, 0.6, true)
        end
        if r.tf and r.tf > 1 then
            GT:AddLine("  coefficient and base heal are per target", 0.6, 0.6, 0.6)
        end
        if r.mult and r.mult > 1.0001 then
            GT:AddLine(("  includes +%s%% healing from talents"):format(FmtSec((r.mult - 1) * 100)), 0.6, 0.6, 0.6)
        end
        if r.level and r.level > 0 then
            local fadeStart = r.level + ns.DOWNRANK_GRACE + 1
            local gone = r.level + ns.DOWNRANK_GRACE + math.ceil(1 / ns.DOWNRANK_PER_LVL)
            local keeps = math.floor((r.bonusShare or 1) * 100 + 0.5)
            if r.playerLevel >= gone then
                GT:AddLine(("  downranking: gets no healing power since level %d"):format(gone), 1, 0.4, 0.3)
            elseif r.playerLevel >= fadeStart then
                GT:AddLine(("  downranking: keeps %d%% of its full coefficient (-5%% per level since %d, none at %d)"):format(
                    keeps, fadeStart, gone), 1, 0.6, 0.3, true)
            else
                GT:AddLine(("  full coefficient until level %d, then -5%% per level"):format(fadeStart - 1), 0.6, 0.6, 0.6)
            end
        end
    end
    if DB.crit and r.canCrit then
        local where = (r.direct > 0 and r.hot > 0) and "heal and every tick"
            or (r.hot > 0 and "every tick") or (r.bolts and "every bolt") or "the heal"
        GT:AddDoubleLine("Crit:", ("%.1f%%  (x%.3f on %s)"):format(r.critTotal, r.critMult, where), 0.8, 0.8, 0.8, 1, 1, 1)
        if r.critTal > 0 then
            GT:AddLine(("  %.1f%% character sheet + %s%% talents (%s)"):format(r.critClient, FmtSec(r.critAdd), r.critSrc), 0.6, 0.6, 0.6, true)
        else
            GT:AddLine(("  %.1f%% character sheet, no crit talents for this spell"):format(r.critClient), 0.6, 0.6, 0.6, true)
        end
    end

    -- Talent healing % and mana cost
    if r.healPct > 0 then
        local state = not r.healIncluded and "applied by addon (not in tooltip)"
            or (r.healVerified and "in tooltip (verified)" or "assumed in tooltip")
        GT:AddDoubleLine("Talent healing:", ("+%s%%  %s"):format(FmtSec(r.healPct), state), 0.8, 0.8, 0.8,
            1, r.healIncluded and 1 or 0.9, r.healIncluded and 1 or 0.3)
        GT:AddLine("  " .. r.healSrc, 0.6, 0.6, 0.6, true)
    end
    if r.costPct > 0 then
        GT:AddDoubleLine("Talent mana cost:", ("-%s%%"):format(FmtSec(r.costPct)), 0.8, 0.8, 0.8, 1, 1, 1)
        GT:AddLine(("  already in the game's mana cost  (%s)"):format(r.costSrc), 0.6, 0.6, 0.6, true)
    end
    if r.aegisPct and r.aegisPct > 0 and r.direct > 0 and not r.absorb then
        if DB.crit then
            GT:AddDoubleLine("Divine Aegis:", ("+%s absorb  (%s%% of crits)"):format(FmtSec(math.floor(r.aegis * 10 + 0.5) / 10), FmtSec(r.aegisPct)),
                0.8, 0.8, 0.8, 0.6, 1, 0.6)
            GT:AddLine(("  average shield per cast: crit chance x crit heal x %s%%  (%s)"):format(FmtSec(r.aegisPct), r.aegisSrc or ""), 0.6, 0.6, 0.6, true)
        else
            GT:AddLine("  Divine Aegis not counted (Crit option off)", 0.6, 0.6, 0.6)
        end
    end
    if r.cooldown then
        GT:AddDoubleLine("Cooldown:", ("%ss"):format(FmtSec(r.cooldown)), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    if r.tf > 1 then
        GT:AddDoubleLine("Targets:", DB.group and ("x%s (group heals on)"):format(FmtSec(r.tf)) or "1 (group heals off)", 0.8, 0.8, 0.8, 1, 1, 1)
    end
    GT:AddLine(" ")
    GT:AddDoubleLine(r.absorb and "Average absorb:" or "Average heal:", FmtInt(r.total), 1, 0.82, 0, 1, 1, 1)
    GT:AddDoubleLine("Mana:", FmtInt(r.mana), 1, 0.82, 0, 1, 1, 1)
    GT:AddDoubleLine("HPS:", r.hps and ("%.1f  (over %ss)"):format(r.hps, FmtSec(r.time)) or "-", 1, 0.82, 0, 1, 1, 1)
    GT:AddDoubleLine("HPM:", r.hpm and ("%.2f"):format(r.hpm) or "-", 1, 0.82, 0, 1, 1, 1)
    GT:AddLine(("Spell ID %d"):format(r.id), 0.4, 0.4, 0.4)
    GT:Show()
end

local function GetRow(i)
    if ROWS[i] then return ROWS[i] end
    local child = MainFrame.child
    local r = CreateFrame("Button", nil, child)
    r:SetHeight(LH)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.sep = r:CreateTexture(nil, "ARTWORK")
    r.sep:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.55)
    r.sep:SetHeight(1)
    r.sep:SetPoint("BOTTOMLEFT", r, "TOPLEFT", 0, 2)
    r.sep:SetPoint("BOTTOMRIGHT", r, "TOPRIGHT", 0, 2)
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.18)
    r.cells = {}
    for _, col in ipairs(COLS) do
        local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", r, "LEFT", col.x, 0)
        fs:SetWidth(col.w)
        fs:SetJustifyH(col.justify)
        if fs.SetWordWrap then fs:SetWordWrap(false) end
        r.cells[col.key] = fs
    end
    r:SetScript("OnEnter", function(self) Safe(RowOnEnter, self) end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ROWS[i] = r
    return r
end

local OPTION_TIPS = {
    crit = "Include the average value of critical heals. In WoW Forever heals over time can crit too (every tick). Shields don't crit.",
    group = "Multiply group heals (Prayer of Healing, Chain Heal, Tranquility, ...) by the number of targets they hit.",
    untrained = "Also list ranks you could train at your level but haven't yet (shown in grey).",
    hotByDuration = "HoT HPS = total heal / HoT duration (healing per second on the target) instead of total heal / time spent casting.",
}

-- Draws a rectangular border of the given thickness, `inset` px inside the frame edge
-- (negative inset draws outside it).
local function AddBorder(frame, layer, rgb, alpha, thickness, inset)
    local function edge()
        local t = frame:CreateTexture(nil, layer)
        t:SetColorTexture(rgb[1], rgb[2], rgb[3], alpha)
        return t
    end
    local top, bottom, left, right = edge(), edge(), edge(), edge()
    top:SetPoint("TOPLEFT", inset, -inset)
    top:SetPoint("TOPRIGHT", -inset, -inset)
    top:SetHeight(thickness)
    bottom:SetPoint("BOTTOMLEFT", inset, inset)
    bottom:SetPoint("BOTTOMRIGHT", -inset, inset)
    bottom:SetHeight(thickness)
    left:SetPoint("TOPLEFT", inset, -inset)
    left:SetPoint("BOTTOMLEFT", inset, inset)
    left:SetWidth(thickness)
    right:SetPoint("TOPRIGHT", -inset, -inset)
    right:SetPoint("BOTTOMRIGHT", -inset, inset)
    right:SetWidth(thickness)
end

local function MakeFrame()
    if MainFrame then return MainFrame end
    local f = CreateFrame("Frame", "HRAMainFrame", UIParent)
    f:SetSize(FRAME_W, FRAME_H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, "HRAMainFrame")   -- Escape closes the window

    -- Solid background (opaque, so the world doesn't show through)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetColorTexture(C.bg[1], C.bg[2], C.bg[3], 0.97)
    bg:SetAllPoints()

    -- Layered trim: dark outline, gold band, faint inner line
    AddBorder(f, "BORDER",  C.outline, 1, 2, -2)
    AddBorder(f, "BORDER",  C.gold,    1, 3,  0)
    AddBorder(f, "ARTWORK", C.inner,   1, 1,  3)

    -- Title plate overlapping the top edge
    local plate = CreateFrame("Frame", nil, f)
    plate:SetSize(300, 34)
    plate:SetPoint("TOP", 0, 18)
    plate:SetFrameLevel(f:GetFrameLevel() + 5)
    local pbg = plate:CreateTexture(nil, "BACKGROUND")
    pbg:SetColorTexture(0.165, 0.114, 0.063, 1)
    pbg:SetAllPoints()
    AddBorder(plate, "BORDER", C.outline,   1, 2, -2)
    AddBorder(plate, "BORDER", C.goldLight, 1, 2,  0)
    local title = plate:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER", 0, 0)
    title:SetText("Heal Rank Advisor")
    title:SetTextColor(1, 0.82, 0)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() f:Hide() end)

    -- Character summary line under the title plate
    f.info = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.info:SetPoint("TOP", 0, -26)
    f.info:SetTextColor(C.legend[1], C.legend[2], C.legend[3])

    -- Fixed column headers (click to sort; they don't scroll away)
    local headerY = -48
    f.headers = {}
    for _, col in ipairs(COLS) do
        local b = CreateFrame("Button", nil, f)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", SCROLL_LEFT + col.x, headerY)
        b:SetSize(col.w, 16)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetAllPoints()
        fs:SetJustifyH(col.justify)
        if fs.SetWordWrap then fs:SetWordWrap(false) end
        b.fs = fs
        b.col = col
        if col.sort then
            b:SetScript("OnClick", function() DB.sort = col.sort; Safe(HRA.Render, HRA) end)
        end
        if col.sort or col.tip then
            b:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine(col.label, 1, 0.82, 0)
                if col.tip then GameTooltip:AddLine(col.tip, 1, 1, 1, true) end
                if col.sort then
                    GameTooltip:AddLine(col.sort == "spell" and "Click to sort by spell & rank" or "Click to sort",
                        0.6, 0.6, 0.6)
                end
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        f.headers[#f.headers + 1] = b
    end
    local headRule = f:CreateTexture(nil, "ARTWORK")
    headRule:SetColorTexture(C.rule[1], C.rule[2], C.rule[3], 1)
    headRule:SetPoint("TOPLEFT", SCROLL_LEFT, headerY - 18)
    headRule:SetPoint("TOPRIGHT", -20, headerY - 18)
    headRule:SetHeight(1)

    -- Scrolling body; right inset leaves room for the scrollbar inside the trim
    local scroll = CreateFrame("ScrollFrame", "HRAScrollFrame", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", SCROLL_LEFT, headerY - 22)
    scroll:SetPoint("BOTTOMRIGHT", -40, 92)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(CHILD_W, 10)
    scroll:SetScrollChild(child)
    f.scroll, f.child = scroll, child

    f.empty = child:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.empty:SetPoint("TOP", 0, -40)
    f.empty:SetWidth(CHILD_W - 40)
    f.empty:SetTextColor(C.muted[1], C.muted[2], C.muted[3])

    -- Footer: rule, legend, options, Refresh button
    local footRule = f:CreateTexture(nil, "ARTWORK")
    footRule:SetColorTexture(C.rule[1], C.rule[2], C.rule[3], 1)
    footRule:SetPoint("BOTTOMLEFT", SCROLL_LEFT, 84)
    footRule:SetPoint("BOTTOMRIGHT", -20, 84)
    footRule:SetHeight(1)

    f.legend = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.legend:SetPoint("TOPLEFT", f, "BOTTOMLEFT", SCROLL_LEFT + 4, 78)
    f.legend:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", -24, 78)
    f.legend:SetJustifyH("LEFT")
    f.legend:SetTextColor(C.legend[1], C.legend[2], C.legend[3])
    f.legend:SetText("Cast / HoT / Crit colour:  |cffe6d6aenormal|r = from game client,  "
        .. "|cffffe64dyellow|r = talent applied by addon,  "
        .. "|cff66ff66green|r = confirmed by your own cast.   Coef / Base: ~ = estimate until measured.   Hover a row for details.")

    -- Options
    local x = SCROLL_LEFT
    local opts = {
        { "crit", "Crit" }, { "group", "Group heals" },
        { "untrained", "Untrained ranks" }, { "hotByDuration", "HoT HPS by duration" },
    }
    f.checks = {}
    for _, o in ipairs(opts) do
        local key, label = o[1], o[2]
        local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        cb:SetSize(22, 22)
        cb:SetPoint("BOTTOMLEFT", x, 16)
        local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", cb, "RIGHT", 1, 1)
        fs:SetText(label)
        fs:SetTextColor(C.text[1], C.text[2], C.text[3])
        cb:SetScript("OnClick", function(self) Safe(HRA.SetOption, HRA, key, self:GetChecked() and true or false) end)
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(label, 1, 0.82, 0)
            GameTooltip:AddLine(OPTION_TIPS[key], 1, 1, 1, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.checks[key] = cb
        x = x + 22 + math.max(fs:GetStringWidth(), 30) + 12
    end

    local refresh = CreateFrame("Button", nil, f, "GameMenuButtonTemplate")
    refresh:SetSize(110, 26)
    refresh:SetPoint("BOTTOMRIGHT", -20, 14)
    refresh:SetText("Refresh")
    refresh:SetScript("OnClick", function() Safe(HRA.Refresh, HRA) end)

    -- HoT-duration learning only listens while the table is open
    f:SetScript("OnShow", function() HRA:SetLearning(true) end)
    f:SetScript("OnHide", function() HRA:SetLearning(false) end)

    MainFrame = f
    return f
end

-- ============================================================
-- ERROR WINDOW (/hra errors) — select all and copy
-- ============================================================
local ErrFrame
function HRA:ShowErrors()
    if #ERRORS == 0 then
        print("|cff00ff96HealRankAdvisor:|r no errors caught this session.")
        return
    end
    if not ErrFrame then
        local f = CreateFrame("Frame", "HRAErrorFrame", UIParent)
        f:SetSize(640, 400)
        f:SetPoint("CENTER")
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetClampedToScreen(true)
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        tinsert(UISpecialFrames, "HRAErrorFrame")

        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetColorTexture(C.bg[1], C.bg[2], C.bg[3], 0.97)
        bg:SetAllPoints()
        AddBorder(f, "BORDER",  C.outline, 1, 2, -2)
        AddBorder(f, "BORDER",  C.gold,    1, 3,  0)
        AddBorder(f, "ARTWORK", C.inner,   1, 1,  3)

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", 0, -12)
        title:SetText("Heal Rank Advisor — errors")
        title:SetTextColor(1, 0.82, 0)

        local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("TOP", 0, -34)
        hint:SetTextColor(C.legend[1], C.legend[2], C.legend[3])
        hint:SetText("Click in the box, press Ctrl+A to select everything, then Ctrl+C to copy.")

        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -4, -4)

        local scroll = CreateFrame("ScrollFrame", "HRAErrorScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 20, -56)
        scroll:SetPoint("BOTTOMRIGHT", -40, 50)

        local eb = CreateFrame("EditBox", nil, scroll)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:SetFontObject(ChatFontNormal)
        eb:SetWidth(570)
        eb:SetTextColor(C.text[1], C.text[2], C.text[3])
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus(); f:Hide() end)
        -- read-only: undo any typing
        eb:SetScript("OnTextChanged", function(self, userInput)
            if userInput and self.fullText then self:SetText(self.fullText); self:HighlightText() end
        end)
        scroll:SetScrollChild(eb)
        f.eb = eb

        local clear = CreateFrame("Button", nil, f, "GameMenuButtonTemplate")
        clear:SetSize(110, 26)
        clear:SetPoint("BOTTOMRIGHT", -20, 14)
        clear:SetText("Clear")
        clear:SetScript("OnClick", function()
            wipe(ERRORS)
            errorNotified = false
            f:Hide()
        end)
        ErrFrame = f
    end

    local lines = {}
    local version, build, _, toc = "?", "?", nil, "?"
    if GetBuildInfo then version, build, _, toc = GetBuildInfo() end
    lines[#lines + 1] = ("HealRankAdvisor %s  |  client %s (%s, toc %s)  |  %s level %d"):format(
        VERSION, tostring(version), tostring(build), tostring(toc),
        PlayerClass(), PlayerLevel())
    for i, e in ipairs(ERRORS) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = ("#%d  [%s]  x%d  %s"):format(i, e.time, e.count, e.msg)
        if e.stack and e.stack ~= "" then lines[#lines + 1] = e.stack end
    end
    local text = table.concat(lines, "\n")
    local eb = ErrFrame.eb
    eb.fullText = text
    eb:SetText(text)
    ErrFrame:Show()
    eb:SetFocus()
    eb:HighlightText()
end

local function SortRows(rows)
    local k = DB.sort
    table.sort(rows, function(a, b)
        if k == "spell" then
            local ao, bo = a.e.def.order or 999, b.e.def.order or 999
            if ao ~= bo then return ao < bo end
            if (a.rank or 0) ~= (b.rank or 0) then return (a.rank or 0) < (b.rank or 0) end
            return a.id < b.id
        end
        local av, bv = a[k] or -1, b[k] or -1
        if av ~= bv then
            if k == "mana" then return av < bv end
            return av > bv
        end
        return a.id < b.id
    end)
end

local CLASS_DISPLAY = { PRIEST = "Priest", DRUID = "Druid", PALADIN = "Paladin", SHAMAN = "Shaman" }
local retries = 0

-- Recalculates every row. Only runs when you open the table for the first time,
-- click Refresh, or change one of the options.
function HRA:Recalculate()
    local rows, info = self:ComputeRows()
    self.rows, self.info = rows, info
    self.updatedAt = date and date("%H:%M") or ""
end

-- Draws the last calculated rows (no recalculation).
function HRA:Render()
    local f = MakeFrame()
    local rows, info = self.rows or {}, self.info or {}
    SortRows(rows)

    for key, cb in pairs(f.checks) do cb:SetChecked(DB[key]) end
    for _, b in ipairs(f.headers) do
        local active = b.col.sort and b.col.sort == DB.sort
        b.fs:SetText(b.col.label .. (active and " v" or ""))
        if active then b.fs:SetTextColor(1, 0.82, 0)
        else b.fs:SetTextColor(C.header[1], C.header[2], C.header[3]) end
    end

    -- HPS / HPM colours: each spell gets its own red (lowest) -> green (highest)
    -- range, built from the ranks you know.
    local ranges = {}
    local pending = false
    for _, r in ipairs(rows) do
        if r.pending then pending = true end
        if r.known and not r.pending then
            local g = ranges[r.e.def]
            if not g then g = {}; ranges[r.e.def] = g end
            if r.hps then g.hpsLo = math.min(g.hpsLo or r.hps, r.hps); g.hpsHi = math.max(g.hpsHi or r.hps, r.hps) end
            if r.hpm then g.hpmLo = math.min(g.hpmLo or r.hpm, r.hpm); g.hpmHi = math.max(g.hpmHi or r.hpm, r.hpm) end
        end
    end

    local y, prevName = 0, nil
    for i, r in ipairs(rows) do
        local row = GetRow(i)
        local newGroup = r.name ~= prevName
        local grouped = DB.sort == "spell"
        if grouped and newGroup and i > 1 then y = y - 6 end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f.child, "TOPLEFT", 0, y)
        row:SetPoint("TOPRIGHT", f.child, "TOPRIGHT", 0, y)
        row.sep:SetShown(grouped and newGroup and i > 1)
        if i % 2 == 0 then row.bg:SetColorTexture(0.353, 0.263, 0.125, 0.22) else row.bg:SetColorTexture(0, 0, 0, 0) end
        row.data = r

        local c = row.cells
        local base = r.known and COLOR.white or COLOR.grey
        local function set(key, text, col)
            col = r.known and (col or base) or COLOR.grey
            c[key]:SetText(text or "")
            c[key]:SetTextColor(col[1], col[2], col[3])
        end

        local nameText = ""
        if not grouped or newGroup then
            nameText = r.name
            if r.tf and r.tf > 1 and DB.group then nameText = nameText .. ("  |cff9c8d70x%s|r"):format(FmtSec(r.tf)) end
            if r.e.def.auto then nameText = nameText .. " |cff9c8d70(auto)|r" end
            if r.e.def.absorb then nameText = nameText .. " |cff9c8d70(absorb)|r" end
        end
        set("name", nameText, COLOR.gold)
        set("rank", (r.rank and r.rank > 0) and tostring(r.rank) or "-")
        set("level", (r.level and r.level > 0) and tostring(r.level) or "-")

        if r.pending then
            set("coef", ""); set("base", ""); set("cast", ""); set("dur", ""); set("mana", ""); set("crit", ""); set("hps", ""); set("hpm", "")
            set("heal", "loading...", COLOR.grey)
        else
            local castText
            if r.channel then castText = FmtSec(r.time) .. "s ch"
            elseif r.cast <= 0 then castText = "Inst"
            else castText = FmtSec(r.cast) .. "s" end
            set("cast", castText, r.castAdjusted and COLOR.yellow or nil)

            -- Healing power coefficient and base heal. "~" = estimate until measured.
            local est = r.shareMeasured and "" or "~"
            set("coef", ("%s%.3f"):format(est, r.coef or 0))
            set("base", est .. FmtInt(r.baseHeal or 0))

            local durCol = (r.durSrc == "observed" and COLOR.green) or (r.durSrc == "talent" and COLOR.yellow) or nil
            set("dur", (r.effDur and not r.channel) and (FmtSec(r.effDur) .. "s") or "-", durCol)
            set("mana", FmtInt(r.mana))
            -- Crit chance (HoT ticks can crit in WoW Forever). Yellow = includes talents.
            if r.canCrit then
                local critCol = (not DB.crit and COLOR.grey) or (r.critAdd > 0 and COLOR.yellow) or nil
                set("crit", ("%.1f%%"):format(r.critTotal), critCol)
            else
                set("crit", "-")
            end
            set("heal", FmtInt(r.total))
            local g = ranges[r.e.def] or {}
            set("hps", r.hps and ("%.1f"):format(r.hps) or "-", { Grad(r.hps, g.hpsLo, g.hpsHi) })
            set("hpm", r.hpm and ("%.2f"):format(r.hpm) or "-", { Grad(r.hpm, g.hpmLo, g.hpmHi) })
        end
        row:Show()
        y = y - LH
        prevName = r.name
    end
    for i = #rows + 1, #ROWS do ROWS[i]:Hide(); ROWS[i].data = nil end
    f.child:SetHeight(math.max(-y + 6, 1))

    if #rows == 0 then
        f.empty:SetText("No healing spells found for this character.")
        f.empty:Show()
    else
        f.empty:Hide()
    end

    local critText = ("%.1f%%"):format(info.crit or 0)
    if (info.critTalent or 0) > 0 then
        critText = ("%.1f%% |cff7d705a(%.1f%% + %s%% talents)|r"):format((info.crit or 0) + info.critTalent,
            info.crit or 0, FmtSec(info.critTalent))
    end
    if not DB.crit then critText = critText .. " |cff7d705a(off)|r" end
    f.info:SetText(("Level %d %s   |cff7d705a•|r   Healing power %s   |cff7d705a•|r   %s crit %s   |cff7d705a•|r   Updated %s"):format(
        info.level or 0, CLASS_DISPLAY[info.class] or (info.class or "?"):lower(),
        FmtInt(info.bonus),
        ns.SCHOOL_NAME[info.school] or "Spell", critText, self.updatedAt or "-"))

    if self.tooltipsStale then
        f.info:SetText((f.info:GetText() or "") .. "   |cffffd100Tooltips haven't caught up with your gear yet - click Refresh again|r")
    end

    f:Show()
    self.hasPending = pending
end

-- Recalculate + redraw. Triggered only by the Refresh button, an option change,
-- or opening the table for the first time.
function HRA:Refresh(isRetry)
    if not isRetry then retries = 0 end
    wipe(self.pendingLoads)
    self:Recalculate()
    self:Render()
    -- Spell data that wasn't cached yet has been requested: recalculate once it
    -- arrives (SPELL_DATA_LOAD_RESULT), at most 3 times per Refresh you asked for.
    if next(self.pendingLoads) and retries < 3 then
        self:WatchSpellLoads(true)
    else
        self:WatchSpellLoads(false)
    end
end

function HRA:Toggle()
    if MainFrame and MainFrame:IsShown() then
        MainFrame:Hide()
    elseif self.rows then
        self:Render()          -- show the last results; click Refresh to update them
    else
        self:Refresh()
    end
end

-- ============================================================
-- HoT DURATION LEARNING
-- After you cast a HoT (out of combat, window open), the UNIT_AURA event that
-- adds or refreshes your aura carries its real duration. No polling.
-- ============================================================
local hotPending     -- { id = spellID, t = cast time }

local function RecordHotDuration(spellID, dur)
    local rounded = math.floor(dur * 10 + 0.5) / 10
    local prev = CDB.observed[spellID]
    CDB.observed[spellID] = { dur = rounded, sig = TalentSig() }
    if not prev or prev.dur ~= rounded then
        local sub = SpellSubtext(spellID)
        print(("|cff00ff96HealRankAdvisor:|r %s%s lasts |cffffff00%ss|r (click Refresh to update the table)"):format(
            SpellName(spellID) or "?", (sub and sub ~= "") and (" (" .. sub .. ")") or "", FmtSec(rounded)))
    end
end

-- True if this aura is the HoT we just cast; records its duration.
local function CheckAura(a)
    if type(a) ~= "table" or not hotPending then return false end
    local sid, dur, exp = Num(a.spellId), Num(a.duration), Num(a.expirationTime)
    if not sid or sid ~= hotPending.id or not dur or dur <= 0 or not exp then return false end
    local mine = a.isFromPlayerOrPlayerPet
    if Secret(mine) then return false end
    if not (mine == true or Str(a.sourceUnit) == "player") then return false end
    if math.abs((exp - dur) - hotPending.t) > 1.5 then return false end
    RecordHotDuration(sid, dur)
    return true
end

-- ============================================================
-- ============================================================
-- MINIMAP BUTTON (LibDataBroker + LibDBIcon)
-- Left-click opens/closes the table, right-click opens it and recalculates.
-- Drag to move it around the minimap. /hra minimap shows or hides it.
-- ============================================================
local MINIMAP_ICON = 135980   -- spell_holy_summonlightwell

function HRA:SetupMinimapButton()
    if self.minimapReady or not LibStub then return end
    local ldb  = LibStub("LibDataBroker-1.1", true)
    local icon = LibStub("LibDBIcon-1.0", true)
    if not ldb or not icon then return end
    DB.minimap = DB.minimap or { hide = false }

    local launcher = ldb:NewDataObject(addonName, {
        type  = "launcher",
        label = "Heal Rank Advisor",
        text  = "Heal Rank Advisor",
        icon  = MINIMAP_ICON,
        OnClick = function(_, button)
            if button == "RightButton" then
                Safe(HRA.Refresh, HRA)       -- opens the table and recalculates
            else
                Safe(HRA.Toggle, HRA)
            end
        end,
        OnTooltipShow = function(tt)
            if not tt or not tt.AddLine then return end
            tt:AddLine("Heal Rank Advisor", 1, 0.82, 0)
            tt:AddLine(("|cffe6d6aeLeft-click|r  open / close the table"), 1, 1, 1)
            tt:AddLine(("|cffe6d6aeRight-click|r  open and refresh"), 1, 1, 1)
            tt:AddLine(("|cffe6d6aeDrag|r  move this button"), 1, 1, 1)
            if HRA.updatedAt then
                tt:AddLine(("Last calculated %s"):format(HRA.updatedAt), 0.6, 0.6, 0.6)
            end
        end,
    })
    if not launcher then return end
    icon:Register(addonName, launcher, DB.minimap)
    self.ldbIcon = icon
    self.minimapReady = true
end

-- Addon compartment (the addon list button by the minimap). Wired up in the .toc.
function HealRankAdvisor_OnAddonCompartmentClick(_, mouseButton)
    if mouseButton == "RightButton" then
        Safe(HRA.Refresh, HRA)
    else
        Safe(HRA.Toggle, HRA)
    end
end

function HealRankAdvisor_OnAddonCompartmentEnter(_, menuButton)
    if not menuButton then return end
    GameTooltip:SetOwner(menuButton, "ANCHOR_LEFT")
    GameTooltip:AddLine("Heal Rank Advisor", 1, 0.82, 0)
    GameTooltip:AddLine("|cffe6d6aeLeft-click|r  open / close the table", 1, 1, 1)
    GameTooltip:AddLine("|cffe6d6aeRight-click|r  open and refresh", 1, 1, 1)
    GameTooltip:Show()
end

function HealRankAdvisor_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end

function HRA:ApplyMinimapVisibility()
    if not self.ldbIcon then return end
    if DB.minimap.hide then self.ldbIcon:Hide(addonName) else self.ldbIcon:Show(addonName) end
end

function HRA:ToggleMinimapButton()
    if not self.ldbIcon then
        print("|cff00ff96HealRankAdvisor:|r the minimap button library isn't loaded.")
        return
    end
    self:SetOption("minimapHide", not DB.minimap.hide)
    if DB.minimap.hide then
        print("|cff00ff96HealRankAdvisor:|r minimap button hidden. Type /hra minimap to show it again.")
    else
        print("|cff00ff96HealRankAdvisor:|r minimap button shown.")
    end
end

-- ============================================================
-- OPTIONS (Settings API: Esc > Options > AddOns > Heal Rank Advisor)
-- The same options are also tick boxes at the bottom of the table window; both
-- read and write the account-wide saved table, so they always agree.
-- ============================================================
local OPTION_LIST = {
    { key = "crit",          name = "Count crits" },
    { key = "group",         name = "Group heals hit every target" },
    { key = "untrained",     name = "Show untrained ranks" },
    { key = "hotByDuration", name = "HoT HPS by duration" },
}

-- Applies an option change from the table window, the Settings panel or a slash command.
function HRA:SetOption(key, value)
    local setting = self.settings and self.settings[key]
    if setting and setting.SetValue then
        setting:SetValue(value)            -- writes the saved table and calls OnOptionChanged
        return
    end
    if key == "minimapHide" then DB.minimap.hide = value else DB[key] = value end
    self:OnOptionChanged(key)
end

function HRA:OnOptionChanged(key)
    if key == "minimapHide" then
        self:ApplyMinimapVisibility()
    elseif MainFrame and MainFrame:IsShown() then
        self:Refresh()
    end
end

function HRA:SetupSettings()
    if self.settingsCategory then return end
    -- Capability probe: Mainline's Settings API (11.0.2+ signatures).
    if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting
            and Settings.CreateCheckbox and Settings.RegisterAddOnCategory) then
        self.settingsUnavailable = "the Settings API isn't available on this client"
        return
    end
    local boolType = (Settings.VarType and Settings.VarType.Boolean) or "boolean"
    local ok, err = pcall(function()
        local category = Settings.RegisterVerticalLayoutCategory("Heal Rank Advisor")
        local settings = {}
        local function add(key, tbl, tblKey, name, tip, default)
            local setting = Settings.RegisterAddOnSetting(category, "HealRankAdvisor_" .. key, tblKey, tbl,
                boolType, name, default)
            if setting.SetValueChangedCallback then
                setting:SetValueChangedCallback(function() Safe(HRA.OnOptionChanged, HRA, key) end)
            end
            Settings.CreateCheckbox(category, setting, tip)
            settings[key] = setting
        end
        for _, o in ipairs(OPTION_LIST) do
            add(o.key, DB, o.key, o.name, OPTION_TIPS[o.key], DEFAULTS[o.key])
        end
        add("minimapHide", DB.minimap, "hide", "Hide minimap button",
            "Hide the Lightwell button on the minimap. The table is still available from the addon list button next to the minimap and with /hra.", false)
        Settings.RegisterAddOnCategory(category)
        self.settings, self.settingsCategory = settings, category
    end)
    if not ok then
        self.settings, self.settingsCategory = nil, nil
        self.settingsUnavailable = tostring(err)
    end
end

function HRA:OpenSettings()
    if self.settingsCategory and Settings and Settings.OpenToCategory then
        local id = self.settingsCategory.GetID and self.settingsCategory:GetID() or self.settingsCategory
        Settings.OpenToCategory(id)
    else
        print(("|cff00ff96HealRankAdvisor:|r the options panel isn't available (%s). Use the tick boxes at the bottom of the table instead.")
            :format(self.settingsUnavailable or "unknown reason"))
    end
end

-- ============================================================
-- SLASH COMMANDS
-- ============================================================
SLASH_HEALRANKADVISOR1 = "/hra"
SLASH_HEALRANKADVISOR2 = "/healranks"
local function PrintHelp()
    print(("|cff00ff96HealRankAdvisor %s|r commands:"):format(VERSION))
    print("  /hra            Open or close the table")
    print("  /hra refresh    Recalculate the table")
    print("  /hra options    Open the options in the game's AddOns settings")
    print("  /hra talents    List your talents and the effects found on your heals")
    print("  /hra minimap    Show or hide the minimap button")
    print("  /hra resetobs   Forget learned HoT durations and coefficient measurements")
    print("  /hra errors     Show caught errors in a window you can copy from")
    print("  /hra debug      Print the parsed values for every row")
    print("  /hra help       Show this list")
end

local function SlashHandler(msg)
    msg = (type(msg) == "string") and msg:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
    if msg == "errors" then
        HRA:ShowErrors()
        return
    elseif msg == "help" or msg == "?" then
        PrintHelp()
        return
    elseif msg == "talents" then
        local talents = HRA:ReadTalents()
        local mods = HRA:GetTalentMods(talents)
        local any = false
        print(("|cff00ff96HealRankAdvisor|r found %d talents with points (%s)."):format(#talents, HRA.talentMethod or "?"))
        local names = {}
        for _, t in ipairs(talents) do names[#names + 1] = ("%s %d/%d"):format(t.name, t.rank, t.maxRank or t.rank) end
        if #names > 0 then print("  " .. table.concat(names, ", ")) end
        print("|cff00ff96HealRankAdvisor|r talent effects found:")
        for sp, m in pairs(mods.cast) do any = true; print(("  %s: cast time -%ss  (%s)"):format(sp, FmtSec(m.amount), table.concat(m.sources, ", "))) end
        for sp, m in pairs(mods.dur)  do any = true; print(("  %s: duration +%ss  (%s)"):format(sp, FmtSec(m.amount), table.concat(m.sources, ", "))) end
        local CAT = { ["*"] = "all heals", ["@instant"] = "instant spells", ["@holy"] = "Holy spells", ["@nature"] = "Nature spells" }
        for sp, m in pairs(mods.heal) do any = true; print(("  %s: healing +%s%%  (%s)"):format(CAT[sp] or sp, FmtSec(m.amount), table.concat(m.sources, ", "))) end
        for sp, m in pairs(mods.cost) do any = true; print(("  %s: mana cost -%s%%  (%s)"):format(CAT[sp] or sp, FmtSec(m.amount), table.concat(m.sources, ", "))) end
        for sp, m in pairs(mods.crit) do any = true; print(("  %s: crit +%s%%  (%s)"):format(CAT[sp] or sp, FmtSec(m.amount), table.concat(m.sources, ", "))) end
        for _, m in pairs(mods.aegis) do any = true; print(("  critical heals: shield for %s%% of the heal  (%s)"):format(FmtSec(m.amount), table.concat(m.sources, ", "))) end
        print("  (mana cost talents are already included in the game's spell costs)")
        if not any then print("  none") end
        print("  (* = read from the addon's fallback table instead of the talent tooltip)")
        return
    elseif msg == "debug" then
        local ok, rows = pcall(HRA.ComputeRows, HRA)
        if not ok then print("error: " .. tostring(rows)) return end
        for _, r in ipairs(rows) do
            local p = r.parsed or {}
            print(("[%d] %s r%s lvl%s | castNow=%s ttDur=%s effDur=%s(%s) | min=%s max=%s hot=%s tick=%s/%s | tf=%s mana=%s coef=%s base=%s [%s] | HPS=%s HPM=%s"):format(
                r.id, r.name, tostring(r.rank), tostring(r.level), tostring(r.castNow), tostring(r.ttDur),
                tostring(r.effDur), tostring(r.durSrc), tostring(p.min), tostring(p.max), tostring(p.hotTotal),
                tostring(p.tick), tostring(p.interval), tostring(r.tf), tostring(r.mana),
                r.coef and ("%.3f"):format(r.coef) or "-", r.baseHeal and tostring(math.floor(r.baseHeal + 0.5)) or "-",
                r.shareMeasured and "measured" or HRA:SampleStatus(r.id),
                r.hps and ("%.1f"):format(r.hps) or "-", r.hpm and ("%.2f"):format(r.hpm) or "-"))
        end
        return
    elseif msg == "resetobs" then
        wipe(CDB.observed)
        CDB.healMode, CDB.samples = {}, {}
        CDB.costObs, CDB.costMode = nil, nil   -- leftovers from older versions
        print("|cff00ff96HealRankAdvisor:|r learned durations, mana costs and measurements cleared.")
        if MainFrame and MainFrame:IsShown() then HRA:Refresh() end
        return
    elseif msg == "minimap" then
        HRA:ToggleMinimapButton()
        return
    elseif msg == "refresh" then
        HRA:Refresh()
        return
    elseif msg == "options" or msg == "config" or msg == "settings" then
        HRA:OpenSettings()
        return
    elseif msg ~= "" then
        print(("|cff00ff96HealRankAdvisor:|r unknown command \"%s\"."):format(msg))
        PrintHelp()
        return
    end
    HRA:Toggle()
end
SlashCmdList["HEALRANKADVISOR"] = function(msg) Safe(SlashHandler, msg) end

-- ============================================================
-- EVENTS — one frame, one handler table
-- ============================================================
local ev = CreateFrame("Frame")
local handlers = {}

local function Reg(event, unit)
    pcall(function()
        if unit and ev.RegisterUnitEvent then ev:RegisterUnitEvent(event, unit) else ev:RegisterEvent(event) end
    end)
end

-- The HoT-duration listener is registered only while the table window is open.
function HRA:SetLearning(on)
    if on then
        Reg("UNIT_SPELLCAST_SUCCEEDED", "player")
    else
        ev:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        ev:UnregisterEvent("UNIT_AURA")
        hotPending = nil
        self:WatchSpellLoads(false)
    end
end

-- SPELL_DATA_LOAD_RESULT is only listened to while a Refresh is waiting for data.
function HRA:WatchSpellLoads(on)
    if on then Reg("SPELL_DATA_LOAD_RESULT") else ev:UnregisterEvent("SPELL_DATA_LOAD_RESULT") end
end

function handlers.ADDON_LOADED(loadedName)
    if loadedName ~= addonName then return end
    ev:UnregisterEvent("ADDON_LOADED")

    -- Saved variables are created here and nowhere else, merged onto defaults.
    local firstAccountLoad = (HealRankAdvisorDB == nil)
    HealRankAdvisorDB     = MergeDefaults(HealRankAdvisorDB or {}, DEFAULTS)
    HealRankAdvisorCharDB = MergeDefaults(HealRankAdvisorCharDB or {}, CHAR_DEFAULTS)
    DB, CDB = HealRankAdvisorDB, HealRankAdvisorCharDB

    -- Before 1.4.0 the options lived in the per-character table: carry them over once.
    if firstAccountLoad then
        for _, k in ipairs({ "crit", "group", "untrained", "hotByDuration", "sort" }) do
            if CDB[k] ~= nil then DB[k] = CDB[k] end
        end
        if type(CDB.minimap) == "table" then DB.minimap = MergeDefaults(CDB.minimap, DEFAULTS.minimap) end
    end
    for _, k in ipairs({ "bonus", "crit", "group", "untrained", "hotByDuration", "sort", "minimap", "costObs", "costMode" }) do
        CDB[k] = nil
    end
    if DB.sort == "bonusShare" then DB.sort = "spell" end

    -- Measurements stored by versions before 1.2.4 weren't checked for stale
    -- tooltips and could be wrong: start them over once.
    -- 1.5.1 changed how readings are checked and how the talent signature is built.
    if (CDB.dataVersion or 0) < 3 then
        CDB.samples, CDB.healMode = {}, {}
        CDB.dataVersion = 3
    end
    Safe(HRA.SetupMinimapButton, HRA)
    Safe(HRA.SetupSettings, HRA)
end

function handlers.PLAYER_LOGIN()
    ev:UnregisterEvent("PLAYER_LOGIN")
    print(("|cff00ff96HealRankAdvisor %s|r loaded  —  /hra to open, /hra help for commands"):format(VERSION))
end

function handlers.UNIT_SPELLCAST_SUCCEEDED(unit, _, spellID)
    if unit ~= "player" or not Num(spellID) then return end
    -- HoT durations are only learned out of combat (auras are hidden in combat)
    if ns.HOT_IDS[spellID] and not AurasRestricted() then
        hotPending = { id = spellID, t = GetTime() }
        Reg("UNIT_AURA")
    end
end

function handlers.UNIT_AURA(unit, info)
    local done = not hotPending or (GetTime() - hotPending.t > 3) or AurasRestricted()
    if not done and Str(unit) and type(info) == "table" then
        for _, a in ipairs(type(info.addedAuras) == "table" and info.addedAuras or {}) do
            if CheckAura(a) then done = true break end
        end
        if not done and type(info.updatedAuraInstanceIDs) == "table"
           and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
            for _, iid in ipairs(info.updatedAuraInstanceIDs) do
                -- pcall: reading an aura while auras are secret raises an error on Forever
                local ok, a = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, iid)
                if ok and CheckAura(a) then done = true break end
            end
        end
    end
    if done then
        hotPending = nil
        ev:UnregisterEvent("UNIT_AURA")
    end
end

function handlers.SPELL_DATA_LOAD_RESULT(spellID)
    if not Num(spellID) or not HRA.pendingLoads[spellID] then return end
    HRA.pendingLoads[spellID] = nil
    if next(HRA.pendingLoads) then return end
    HRA:WatchSpellLoads(false)
    if MainFrame and MainFrame:IsShown() then
        retries = retries + 1
        HRA:Refresh(true)
    end
end

ev:SetScript("OnEvent", function(_, event, ...)
    local handler = handlers[event]
    if handler then Safe(handler, ...) end
end)
Reg("ADDON_LOADED")
Reg("PLAYER_LOGIN")
