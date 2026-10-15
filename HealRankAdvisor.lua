-- HealRankAdvisor.lua
-- Table of every healing spell rank for your class/level with average
-- Healing per Second (HPS) and Healing per Mana (HPM).

local ADDON_NAME, ns = ...
local HRA = {}
_G.HealRankAdvisor = HRA
ns.HRA = HRA

local VERSION = "1.3.0"
local GCD     = 1.5
local DB

local DEFAULTS = {
    bonus         = true,   -- include +healing (tooltips already do; off = show base heal)
    crit          = true,   -- include average crit contribution on direct heals
    group         = true,   -- multiply group heals by number of targets
    untrained     = true,   -- show ranks available at your level but not trained
    hotByDuration = false,  -- HoT HPS = total / HoT duration instead of / cast time
    samples       = {},     -- [spellID] = tooltip values at low/high +healing, to measure coefficients
    sort          = "spell",
    observed      = {},     -- [spellID] = { dur = seconds, sig = talentSignature }
}

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

-- ============================================================
-- API WRAPPERS (work with both the classic globals and the C_ namespaces)
-- ============================================================
local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then
        local n = C_Spell.GetSpellName(id)
        if n then return n end
    end
    if GetSpellInfo then return (GetSpellInfo(id)) end
end

local function CastMs(id)
    if C_Spell and C_Spell.GetSpellInfo then
        local i = C_Spell.GetSpellInfo(id)
        if type(i) == "table" then return i.castTime or 0 end
    end
    if GetSpellInfo then
        local _, _, _, ct = GetSpellInfo(id)
        return ct or 0
    end
    return 0
end

local function SpellSubtext(id)
    if C_Spell and C_Spell.GetSpellSubtext then
        local s = C_Spell.GetSpellSubtext(id)
        if s and s ~= "" then return s end
    end
    if GetSpellSubtext then return GetSpellSubtext(id) end
end

local function IsPassive(id)
    if C_Spell and C_Spell.IsSpellPassive then return C_Spell.IsSpellPassive(id) end
    if IsPassiveSpell then return IsPassiveSpell(id) end
    return false
end

local function Known(id)
    if IsPlayerSpell and IsPlayerSpell(id) then return true end
    if IsSpellKnown and IsSpellKnown(id) then return true end
    return false
end

local function LearnLevel(id, fallback)
    if GetSpellLevelLearned then
        local ok, l = pcall(GetSpellLevelLearned, id)
        if ok and type(l) == "number" and l > 0 then return l end
    end
    return fallback or 0
end

local function ManaCost(id)
    local costs
    if C_Spell and C_Spell.GetSpellPowerCost then
        costs = C_Spell.GetSpellPowerCost(id)
    elseif GetSpellPowerCost then
        costs = GetSpellPowerCost(id)
    end
    if type(costs) == "table" then
        for _, c in ipairs(costs) do
            if c.type == 0 or c.name == "MANA" then
                local v = c.cost or 0
                if v == 0 and (c.costPercent or 0) > 0 then
                    v = UnitPowerMax("player", 0) * c.costPercent / 100
                end
                return v
            end
        end
    end
    return 0
end

local scanTip = CreateFrame("GameTooltip", "HRAScanTooltip", nil, "GameTooltipTemplate")

local function TooltipDesc(id)
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:ClearLines()
    if not pcall(scanTip.SetSpellByID, scanTip, id) then return "" end
    local n = scanTip:NumLines()
    local fs = n and n > 0 and _G["HRAScanTooltipTextLeft" .. n]
    return fs and fs:GetText() or ""
end

local function SpellDesc(id)
    local d
    if C_Spell and C_Spell.GetSpellDescription then d = C_Spell.GetSpellDescription(id) end
    if (not d or d == "") and GetSpellDescription then d = GetSpellDescription(id) end
    if not d or d == "" then d = TooltipDesc(id) end
    if not d or d == "" then
        if C_Spell and C_Spell.RequestLoadSpellData then C_Spell.RequestLoadSpellData(id) end
        return ""
    end
    return Clean(d)
end

local function ForEachAura(unit, filter, cb)
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 40 do
            local a = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
            if not a then break end
            if cb(a.spellId, a.duration, a.expirationTime, a.sourceUnit) then return end
        end
    elseif UnitAura then
        for i = 1, 40 do
            local name, _, _, _, dur, exp, src, _, _, sid = UnitAura(unit, i, filter)
            if not name then break end
            if cb(sid, dur, exp, src) then return end
        end
    end
end

local function IterSpellbook(cb)
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and Enum and Enum.SpellBookSpellBank then
        for tab = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local info = C_SpellBook.GetSpellBookSkillLineInfo(tab)
            if info and not info.shouldHide then
                for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                    local it = C_SpellBook.GetSpellBookItemInfo(i, Enum.SpellBookSpellBank.Player)
                    if it and it.spellID and not it.isPassive then cb(it.spellID, it.name, it.subName) end
                end
            end
        end
    elseif GetNumSpellTabs then
        local book = BOOKTYPE_SPELL or "spell"
        for tab = 1, GetNumSpellTabs() do
            local _, _, offset, num = GetSpellTabInfo(tab)
            for i = (offset or 0) + 1, (offset or 0) + (num or 0) do
                local stype, id = GetSpellBookItemInfo(i, book)
                if stype == "SPELL" and id then
                    local name, sub = GetSpellBookItemName(i, book)
                    cb(id, name, sub)
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

function ns.ParseTalentText(text, cast, dur, src, heal)
    local t = text:lower() .. ". "
    local found = false
    for clause in t:gmatch("(.-)%.%s") do
        -- Healing % talents: "Increases the amount healed by your Renew spell by 15%",
        -- "...healed by your spells by 3%", "...damage and healing of your instant cast spells by 5%"
        if heal and clause:find("increas") and (clause:find("heal") or clause:find("effect of your")) then
            local chunk, pct = clause:match("healed by your (.-) by ([%d%.]+)%%")
            if not chunk then chunk, pct = clause:match("effect of your (.-) by ([%d%.]+)%%") end
            if not chunk then chunk, pct = clause:match("healing done by your (.-) by ([%d%.]+)%%") end
            if not chunk then chunk, pct = clause:match("healing of your (.-) by ([%d%.]+)%%") end
            pct = pct and tonumber((pct:gsub("%.$", "")))
            if chunk and pct and pct > 0 then
                chunk = chunk:gsub("^%s+", ""):gsub("%s+$", "")
                if chunk == "spells" or chunk == "healing spells" then
                    AddMod(heal, "*", pct, src)
                elseif chunk:find("instant") then
                    AddMod(heal, "@instant", pct, src)
                else
                    chunk = chunk:gsub(" spells?$", "")
                    for _, n in ipairs(SplitNames(chunk)) do AddMod(heal, n, pct, src) end
                end
                found = true
            end
        end
        local isDur  = clause:find("duration") and (clause:find("increas") or clause:find("extend"))
        local isCast = (not isDur) and clause:find("cast")
                       and (clause:find("reduc") or clause:find("decreas") or clause:find("shorten"))
        if isDur or isCast then
            for chunk, amt in clause:gmatch("([^%d]-) by ([%d%.]+) sec") do
                local names = chunk:match(".*your (.*)") or chunk:match(".* of (.*)") or chunk
                names = names:gsub("^[%s,]+", ""):gsub("^and ", ""):gsub(" spells?$", ""):gsub(" abilit%a+$", "")
                local a = tonumber((amt:gsub("%.$", "")))
                if a and a > 0 then
                    for _, n in ipairs(SplitNames(names)) do
                        AddMod(isDur and dur or cast, n, a, src)
                        found = true
                    end
                end
            end
        end
    end
    return found
end

local function TalentText(tab, i)
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:ClearLines()
    if not pcall(scanTip.SetTalent, scanTip, tab, i) then return "" end
    local parts = {}
    for idx = 2, scanTip:NumLines() do
        local fs = _G["HRAScanTooltipTextLeft" .. idx]
        local tx = fs and fs:GetText()
        if tx then
            if tx:lower():find("^next rank") then break end
            parts[#parts + 1] = Clean(tx)
        end
    end
    return table.concat(parts, ". ")
end

local function TalentSig()
    local t = {}
    pcall(function()
        for tab = 1, (GetNumTalentTabs() or 0) do
            for i = 1, (GetNumTalents(tab) or 0) do
                local _, _, _, _, r = GetTalentInfo(tab, i)
                t[#t + 1] = r or 0
            end
        end
    end)
    return table.concat(t)
end

function HRA:GetTalentMods()
    local mods = { cast = {}, dur = {}, heal = {} }
    pcall(function()
        for tab = 1, (GetNumTalentTabs() or 0) do
            for i = 1, (GetNumTalents(tab) or 0) do
                local name, _, _, _, rank = GetTalentInfo(tab, i)
                if name and rank and rank > 0 then
                    local src  = ("%s %d"):format(name, rank)
                    local text = TalentText(tab, i)
                    local found = text ~= "" and ns.ParseTalentText(text, mods.cast, mods.dur, src, mods.heal)
                    local fb = ns.TALENT_FALLBACK[name]
                    if not found and fb then
                        local mult = fb.perRank and rank or 1
                        for sp, v in pairs(fb.cast or {}) do AddMod(mods.cast, sp, v * mult, src .. "*") end
                        for sp, v in pairs(fb.dur  or {}) do AddMod(mods.dur,  sp, v * mult, src .. "*") end
                        for sp, v in pairs(fb.heal or {}) do AddMod(mods.heal, sp, v * mult, src .. "*") end
                    end
                end
            end
        end
    end)
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
    local class = select(2, UnitClass("player"))
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
            local nm = SpellName(r[1])
            if nm and nm:lower() == def.lname then
                add({ id = r[1], def = def, rank = ri, level = LearnLevel(r[1], r[2]),
                      baseCast = r[3], known = Known(r[1]) })
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
-- Measured in the beta (levels 18-30); Blizzard confirmed the mechanic without numbers.
-- Confirmed against in-game tooltips for Lesser Heal 2-3, Renew 1-4 and Heal 1-3 at
-- level 30. Lesser Heal rank 1 kept less than predicted (~24% vs 40%), so the addon
-- prefers coefficients it measures from your own tooltips (see HRA:LearnSlope).
ns.DOWNRANK_GRACE    = 17     -- full bonus while L - T <= 17
ns.DOWNRANK_PER_LVL  = 0.05   -- share lost per level beyond that

function ns.DownrankShare(playerLevel, learnLevel)
    if not playerLevel or not learnLevel or learnLevel <= 0 then return 1 end
    return Clamp(1 - (playerLevel - ns.DOWNRANK_GRACE - learnLevel) * ns.DOWNRANK_PER_LVL, 0, 1)
end
-- Healing % from talents that applies to this spell (used only for estimates;
-- tooltip values and measured coefficients already include it).
local function HealMult(mods, def, isInstant)
    local h = mods.heal or {}
    local pct = (h[def.lname] and h[def.lname].amount or 0) + (h["*"] and h["*"].amount or 0)
    if isInstant and h["@instant"] then pct = pct + h["@instant"].amount end
    return 1 + pct / 100
end

-- Remembers each rank's tooltip value at the lowest and highest +healing seen
-- (same level and talents). Once they are 20+ apart, the slope is the rank's
-- true +healing coefficient including talents and the downranking penalty.
function HRA:LearnSlope(id, level, sig, sp, value)
    DB.samples = DB.samples or {}
    local s = DB.samples[id]
    if not s or s.lvl ~= level or s.sig ~= sig then
        s = { lvl = level, sig = sig, lo = { sp, value }, hi = { sp, value } }
        DB.samples[id] = s
    else
        if sp < s.lo[1] then s.lo = { sp, value } elseif sp == s.lo[1] then s.lo[2] = value end
        if sp > s.hi[1] then s.hi = { sp, value } elseif sp == s.hi[1] then s.hi[2] = value end
    end
    local dsp = s.hi[1] - s.lo[1]
    if dsp >= 20 then return (s.hi[2] - s.lo[2]) / dsp, s.lo[1], s.hi[1] end
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
        local ob = DB.observed[e.id]
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

    -- ---- +Healing ----
    -- WoW Forever's tooltips already include your +healing, the downranking penalty
    -- and healing talents (verified in game), so the tooltip value is used as-is.
    -- The addon only works out the +healing portion, to show it or remove it.
    local share  = ns.DownrankShare(playerLevel, e.level)
    local mult   = HealMult(mods, def, castNow <= 0 and not def.channel)
    local estD, estH = cd * share * mult, ch * share * mult     -- per point of +healing
    local slope, sLo, sHi = self:LearnSlope(e.id, playerLevel, sig, bonus, direct + hot)
    local perD, perH = estD, estH
    local includes, measured = true, false
    local fullCoef = (cd + ch) * mult
    if slope then
        measured = true
        if math.abs(slope) < 0.02 and fullCoef * share > 0.05 then
            includes = false              -- tooltip didn't move with +healing: add it ourselves
        else
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
    end
    local bD, bH = perD * bonus, perH * bonus
    local directBase = includes and math.max(direct - bD, 0) or direct
    local hotBase    = includes and math.max(hot - bH, 0) or hot

    -- ---- Crit (direct portion only) ----
    local critMult = 1
    if DB.crit and direct > 0 then critMult = 1 + (critPct / 100) * 0.5 end

    local directAvg = (directBase + (DB.bonus and bD or 0)) * critMult
    local hotAvg    = (hotBase + (DB.bonus and bH or 0)) * durScale
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

    local mana = ManaCost(e.id)

    row.castNow, row.cast = castNow, cast
    row.channel, row.totem = def.channel, def.totem
    row.ttDur, row.effDur, row.durSrc = ttDur, (hot > 0) and effDur or nil, durSrc
    row.direct, row.hot, row.bD, row.bH = direct, hot, bD, bH
    row.cd, row.ch, row.mult = cd, ch, mult
    row.bonusShare, row.shareMeasured = share, measured
    row.slope, row.slopeLo, row.slopeHi = slope, sLo, sHi
    row.tooltipHasBonus = includes
    row.bonusAmt = (bD + bH * durScale)
    row.spellHealing = bonus
    row.playerLevel = playerLevel
    row.critMult, row.critPct = critMult, critPct
    row.tf, row.factor = tf, factor
    row.time, row.mana, row.total = time, mana, total
    row.directAvg, row.hotAvg = directAvg, hotAvg
    row.hps = (time and time > 0) and total / time or nil
    row.hpm = (mana and mana > 0) and total / mana or nil
    return row
end

function HRA:ComputeRows()
    local _, class = UnitClass("player")
    local level = UnitLevel("player")
    local entries = self:BuildEntries()
    local mods = self:GetTalentMods()
    local sig = TalentSig()
    local bonus = GetSpellBonusHealing and GetSpellBonusHealing() or 0
    local school = ns.CLASS_SCHOOL[class] or 2
    local critPct = GetSpellCritChance and GetSpellCritChance(school) or 0

    local rows = {}
    for _, e in ipairs(entries) do
        local show = e.known or (DB.untrained and e.level > 0 and e.level <= level)
        if show then rows[#rows + 1] = self:ComputeEntry(e, mods, sig, bonus, critPct, level) end
    end
    self.lastMods = mods
    return rows, { level = level, class = class, bonus = bonus, crit = critPct, school = school }
end

-- ============================================================
-- GUI
-- ============================================================
local MainFrame
local ROWS = {}
local LH = 18
local FRAME_W, FRAME_H = 720, 540
local SCROLL_LEFT = 20          -- scroll area inset from the window's left edge
local CHILD_W = FRAME_W - SCROLL_LEFT - 40

-- Palette (r, g, b) — shared with Waylaid Crate Advisor
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
    { key = "level", label = "Lvl",      w = 30,  justify = "CENTER" },
    { key = "bonus", label = "Bonus",    w = 46,  justify = "RIGHT" },
    { key = "cast",  label = "Cast",     w = 54,  justify = "RIGHT" },
    { key = "dur",   label = "HoT",      w = 40,  justify = "RIGHT" },
    { key = "mana",  label = "Mana",     w = 48,  justify = "RIGHT",  sort = "mana" },
    { key = "heal",  label = "Avg Heal", w = 70,  justify = "RIGHT",  sort = "total" },
    { key = "hps",   label = "HPS",      w = 60,  justify = "RIGHT",  sort = "hps" },
    { key = "hpm",   label = "HPM",      w = 56,  justify = "RIGHT",  sort = "hpm" },
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
        GT:AddDoubleLine("Direct (tooltip):", ("%d - %d  (avg %s)"):format(p.min, p.max, FmtInt(r.direct)), 0.8, 0.8, 0.8, 1, 1, 1)
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
        local share = math.floor((r.bonusShare or 0) * 100 + 0.5)
        GT:AddDoubleLine("+Healing share:", ("%d%%  (%s)"):format(share, r.shareMeasured and "measured" or "estimated"),
            0.8, 0.8, 0.8, r.shareMeasured and 0.4 or 1, 1, r.shareMeasured and 0.4 or 1)
        local verb = r.tooltipHasBonus and "in tooltip" or "added by addon"
        if not DB.bonus then verb = "removed (+Healing off)" end
        GT:AddDoubleLine("+Healing " .. verb .. ":", ("%s  (of %d)"):format(FmtInt(r.bonusAmt), r.spellHealing),
            0.8, 0.8, 0.8, 0.6, 1, 0.6)
        if r.shareMeasured then
            GT:AddLine(("  measured from your tooltips at %d and %d spell healing"):format(r.slopeLo, r.slopeHi), 0.6, 0.6, 0.6)
        else
            GT:AddLine("  change your +healing by 20+ (swap gear) to measure it", 0.6, 0.6, 0.6)
        end
        if r.mult and r.mult > 1.0001 then
            GT:AddLine(("  includes +%s%% healing from talents"):format(FmtSec((r.mult - 1) * 100)), 0.6, 0.6, 0.6)
        end
        if r.level and r.level > 0 then
            local fadeStart = r.level + ns.DOWNRANK_GRACE + 1
            local gone = r.level + ns.DOWNRANK_GRACE + math.ceil(1 / ns.DOWNRANK_PER_LVL)
            if r.playerLevel >= gone then
                GT:AddLine(("  downranking: no +healing left since level %d"):format(gone), 1, 0.4, 0.3)
            elseif r.playerLevel >= fadeStart then
                GT:AddLine(("  downranking: -5%% per level since %d, none left at %d"):format(fadeStart, gone), 1, 0.6, 0.3)
            else
                GT:AddLine(("  full +healing until level %d, then -5%% per level"):format(fadeStart - 1), 0.6, 0.6, 0.6)
            end
        end
    end
    if DB.crit and r.critMult > 1 then
        GT:AddDoubleLine("Crit:", ("%.1f%%  (x%.3f on direct part)"):format(r.critPct, r.critMult), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    if r.tf > 1 then
        GT:AddDoubleLine("Targets:", DB.group and ("x%s (group heals on)"):format(FmtSec(r.tf)) or "1 (group heals off)", 0.8, 0.8, 0.8, 1, 1, 1)
    end
    GT:AddLine(" ")
    GT:AddDoubleLine("Average heal:", FmtInt(r.total), 1, 0.82, 0, 1, 1, 1)
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
    r:SetScript("OnEnter", RowOnEnter)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ROWS[i] = r
    return r
end

local OPTION_TIPS = {
    bonus = "Include your +healing. WoW Forever tooltips already include it (with the downranking penalty), so this is on by default. Turn off to see each rank's base heal.",
    crit = "Include the average value of critical heals (direct heals only; HoTs don't crit).",
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
            b:SetScript("OnClick", function() DB.sort = col.sort; HRA:Refresh() end)
            b:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine(col.sort == "spell" and "Sort by spell & rank" or ("Sort by " .. col.label))
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
    f.legend:SetText("Cast / HoT colour:  |cffe6d6aenormal|r = from game client,  "
        .. "|cffffe64dyellow|r = talent applied by addon,  "
        .. "|cff66ff66green|r = duration observed on your own aura.   Bonus: ~ = estimated, no ~ = measured.   Hover a row for details.")

    -- Options
    local x = SCROLL_LEFT
    local opts = {
        { "bonus", "+Healing" }, { "crit", "Crit" }, { "group", "Group heals" },
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
        cb:SetScript("OnClick", function(self) DB[key] = self:GetChecked() and true or false; HRA:Refresh() end)
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
    refresh:SetScript("OnClick", function() HRA:Refresh() end)

    MainFrame = f
    return f
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

function HRA:Refresh()
    local f = MakeFrame()
    local ok, rows, info = pcall(self.ComputeRows, self)
    if not ok then
        print("|cffff4040HealRankAdvisor error:|r " .. tostring(rows))
        return
    end
    SortRows(rows)

    for key, cb in pairs(f.checks) do cb:SetChecked(DB[key]) end
    for _, b in ipairs(f.headers) do
        local active = b.col.sort and b.col.sort == DB.sort
        b.fs:SetText(b.col.label .. (active and " v" or ""))
        if active then b.fs:SetTextColor(1, 0.82, 0)
        else b.fs:SetTextColor(C.header[1], C.header[2], C.header[3]) end
    end

    local hpsLo, hpsHi, hpmLo, hpmHi
    local pending = false
    for _, r in ipairs(rows) do
        if r.pending then pending = true end
        if r.known and not r.pending then
            if r.hps then hpsLo = math.min(hpsLo or r.hps, r.hps); hpsHi = math.max(hpsHi or r.hps, r.hps) end
            if r.hpm then hpmLo = math.min(hpmLo or r.hpm, r.hpm); hpmHi = math.max(hpmHi or r.hpm, r.hpm) end
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
        end
        set("name", nameText, COLOR.gold)
        set("rank", (r.rank and r.rank > 0) and tostring(r.rank) or "-")
        set("level", (r.level and r.level > 0) and tostring(r.level) or "-")

        if r.pending then
            set("bonus", ""); set("cast", ""); set("dur", ""); set("mana", ""); set("hps", ""); set("hpm", "")
            set("heal", "loading...", COLOR.grey)
        else
            local castText
            if r.channel then castText = FmtSec(r.time) .. "s ch"
            elseif r.cast <= 0 then castText = "Inst"
            else castText = FmtSec(r.cast) .. "s" end
            set("cast", castText, r.castAdjusted and COLOR.yellow or nil)

            -- Share of +healing this rank keeps (WoW Forever downranking).
            -- "~" = estimated from the formula, no "~" = measured from your tooltips.
            local share = r.bonusShare or 1
            local shareCol = share >= 0.995 and nil or { Grad(share, 0, 1) }
            if not DB.bonus then shareCol = COLOR.grey end
            set("bonus", ("%s%d%%"):format(r.shareMeasured and "" or "~", math.floor(share * 100 + 0.5)), shareCol)

            local durCol = (r.durSrc == "observed" and COLOR.green) or (r.durSrc == "talent" and COLOR.yellow) or nil
            set("dur", (r.effDur and not r.channel) and (FmtSec(r.effDur) .. "s") or "-", durCol)
            set("mana", FmtInt(r.mana))
            set("heal", FmtInt(r.total))
            set("hps", r.hps and ("%.1f"):format(r.hps) or "-", { Grad(r.hps, hpsLo, hpsHi) })
            set("hpm", r.hpm and ("%.2f"):format(r.hpm) or "-", { Grad(r.hpm, hpmLo, hpmHi) })
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

    f.info:SetText(("Level %d %s   |cff7d705a•|r   +Healing %s%s   |cff7d705a•|r   %s crit %.1f%%"):format(
        info.level, CLASS_DISPLAY[info.class] or (info.class or "?"):lower(),
        FmtInt(info.bonus), DB.bonus and "" or " |cff7d705a(off)|r",
        ns.SCHOOL_NAME[info.school] or "Spell", info.crit or 0))

    f:Show()

    -- Spell descriptions can arrive a moment later the first time
    if pending and retries < 5 then
        retries = retries + 1
        C_Timer.After(1, function() if MainFrame:IsShown() then HRA:Refresh() end end)
    elseif not pending then
        retries = 0
    end
end

local refreshQueued = false
function HRA:RequestRefresh(delay)
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(delay or 0.3, function()
        refreshQueued = false
        if MainFrame and MainFrame:IsShown() then HRA:Refresh() end
    end)
end

function HRA:Toggle()
    if MainFrame and MainFrame:IsShown() then MainFrame:Hide() else self:Refresh() end
end

-- ============================================================
-- HoT DURATION LEARNING
-- After you cast a HoT, read the real duration off the aura you applied.
-- ============================================================
local function ObserveHot(spellID, castAt)
    local units = { "target", "player", "focus", "mouseover", "party1", "party2", "party3", "party4" }
    if IsInRaid and IsInRaid() then for i = 1, 40 do units[#units + 1] = "raid" .. i end end
    for _, u in ipairs(units) do
        if UnitExists(u) then
            local found
            ForEachAura(u, "HELPFUL", function(sid, dur, exp, src)
                if sid == spellID and dur and dur > 0 and exp and (src == "player" or src == nil)
                   and math.abs((exp - dur) - castAt) < 1.5 then
                    found = dur
                    return true
                end
            end)
            if found then
                local rounded = math.floor(found * 10 + 0.5) / 10
                local prev = DB.observed[spellID]
                DB.observed[spellID] = { dur = rounded, sig = TalentSig() }
                if not prev or prev.dur ~= rounded then
                    local sub = SpellSubtext(spellID)
                    print(("|cff00ff96HealRankAdvisor:|r %s%s lasts |cffffff00%ss|r"):format(
                        SpellName(spellID) or "?", (sub and sub ~= "") and (" (" .. sub .. ")") or "", FmtSec(rounded)))
                end
                HRA:RequestRefresh()
                return
            end
        end
    end
end

-- ============================================================
-- SLASH COMMANDS
-- ============================================================
SLASH_HEALRANKADVISOR1 = "/hra"
SLASH_HEALRANKADVISOR2 = "/healranks"
SlashCmdList["HEALRANKADVISOR"] = function(msg)
    msg = strtrim and strtrim((msg or ""):lower()) or (msg or ""):lower()
    if msg == "help" then
        print("|cff00ff96HealRankAdvisor|r commands:")
        print("  /hra            Toggle the table")
        print("  /hra talents    Show talents detected as changing cast time / HoT duration")
        print("  /hra debug      Print the parsed values for every row")
        print("  /hra resetobs   Forget learned HoT durations")
        return
    elseif msg == "talents" then
        local mods = HRA:GetTalentMods()
        local any = false
        print("|cff00ff96HealRankAdvisor|r talent effects found:")
        for sp, m in pairs(mods.cast) do any = true; print(("  %s: cast time -%ss  (%s)"):format(sp, FmtSec(m.amount), table.concat(m.sources, ", "))) end
        for sp, m in pairs(mods.dur)  do any = true; print(("  %s: duration +%ss  (%s)"):format(sp, FmtSec(m.amount), table.concat(m.sources, ", "))) end
        if not any then print("  none") end
        print("  (* = read from the addon's fallback table instead of the talent tooltip)")
        return
    elseif msg == "debug" then
        local ok, rows = pcall(HRA.ComputeRows, HRA)
        if not ok then print("error: " .. tostring(rows)) return end
        for _, r in ipairs(rows) do
            local p = r.parsed or {}
            print(("[%d] %s r%s lvl%s | castNow=%s ttDur=%s effDur=%s(%s) | min=%s max=%s hot=%s tick=%s/%s | tf=%s mana=%s bonus%%=%s | HPS=%s HPM=%s"):format(
                r.id, r.name, tostring(r.rank), tostring(r.level), tostring(r.castNow), tostring(r.ttDur),
                tostring(r.effDur), tostring(r.durSrc), tostring(p.min), tostring(p.max), tostring(p.hotTotal),
                tostring(p.tick), tostring(p.interval), tostring(r.tf), tostring(r.mana),
                r.bonusShare and tostring(math.floor(r.bonusShare * 100 + 0.5)) or "-",
                r.hps and ("%.1f"):format(r.hps) or "-", r.hpm and ("%.2f"):format(r.hpm) or "-"))
        end
        return
    elseif msg == "resetobs" then
        wipe(DB.observed)
        print("|cff00ff96HealRankAdvisor:|r learned HoT durations cleared.")
        HRA:RequestRefresh(0)
        return
    elseif msg == "refresh" then
        HRA:Refresh()
        return
    end
    HRA:Toggle()
end

-- ============================================================
-- EVENTS
-- ============================================================
local ev = CreateFrame("Frame")
local function Reg(event, unit)
    pcall(function()
        if unit and ev.RegisterUnitEvent then ev:RegisterUnitEvent(event, unit) else ev:RegisterEvent(event) end
    end)
end

Reg("ADDON_LOADED")
Reg("PLAYER_LOGIN")

ev:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON_NAME then return end
        HealRankAdvisorCharDB = HealRankAdvisorCharDB or {}
        DB = HealRankAdvisorCharDB
        for k, v in pairs(DEFAULTS) do
            if DB[k] == nil then DB[k] = (type(v) == "table") and {} or v end
        end
        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_LOGIN" then
        for _, e in ipairs({ "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB", "PLAYER_LEVEL_UP",
                             "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE",
                             "PLAYER_EQUIPMENT_CHANGED", "SPELL_DATA_LOAD_RESULT" }) do
            Reg(e)
        end
        Reg("UNIT_STATS", "player")
        Reg("UNIT_SPELLCAST_SUCCEEDED", "player")
        -- Discover auto-detected HoTs in the background so their durations can be learned
        C_Timer.After(3, function() pcall(HRA.BuildEntries, HRA) end)
        print(("|cff00ff96HealRankAdvisor %s|r loaded  —  /hra to open, /hra help for options"):format(VERSION))

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit == "player" and spellID and ns.HOT_IDS[spellID] then
            local castAt = GetTime()
            C_Timer.After(0.3, function() ObserveHot(spellID, castAt) end)
        end

    elseif event == "SPELL_DATA_LOAD_RESULT" then
        HRA:RequestRefresh(0.5)

    else
        HRA:RequestRefresh(0.5)
    end
end)
