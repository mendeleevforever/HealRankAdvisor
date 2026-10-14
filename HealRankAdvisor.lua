-- HealRankAdvisor.lua
-- Table of every healing spell rank for your class/level with average
-- Healing per Second (HPS) and Healing per Mana (HPM).

local ADDON_NAME, ns = ...
local HRA = {}
_G.HealRankAdvisor = HRA
ns.HRA = HRA

local VERSION = "1.0.0"
local GCD     = 1.5
local DB

local DEFAULTS = {
    bonus         = true,   -- add +healing (spell power) using coefficients
    crit          = true,   -- include average crit contribution on direct heals
    group         = true,   -- multiply group heals by number of targets
    untrained     = true,   -- show ranks available at your level but not trained
    hotByDuration = false,  -- HoT HPS = total / HoT duration instead of / cast time
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

function ns.ParseTalentText(text, cast, dur, src)
    local t = text:lower() .. ". "
    local found = false
    for clause in t:gmatch("(.-)%.%s") do
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
    local mods = { cast = {}, dur = {} }
    pcall(function()
        for tab = 1, (GetNumTalentTabs() or 0) do
            for i = 1, (GetNumTalents(tab) or 0) do
                local name, _, _, _, rank = GetTalentInfo(tab, i)
                if name and rank and rank > 0 then
                    local src  = ("%s %d"):format(name, rank)
                    local text = TalentText(tab, i)
                    local found = text ~= "" and ns.ParseTalentText(text, mods.cast, mods.dur, src)
                    local fb = ns.TALENT_FALLBACK[name]
                    if not found and fb then
                        local mult = fb.perRank and rank or 1
                        for sp, v in pairs(fb.cast or {}) do AddMod(mods.cast, sp, v * mult, src .. "*") end
                        for sp, v in pairs(fb.dur  or {}) do AddMod(mods.dur,  sp, v * mult, src .. "*") end
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
function HRA:ComputeEntry(e, mods, sig, bonus, critPct)
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
    if hot > 0 and ttDur and effDur and ttDur > 0 and math.abs(effDur - ttDur) > 0.05 then
        hot = hot * effDur / ttDur       -- extra ticks heal for the same amount
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
    local penalty = 1
    if e.level and e.level > 0 and e.level < 20 then penalty = 1 - (20 - e.level) * 0.0375 end
    cd, ch = cd * penalty, ch * penalty

    local bD, bH = 0, 0
    if DB.bonus and bonus > 0 then
        if direct > 0 then bD = cd * bonus end
        if hot > 0 then
            local baseD = def.baseDur or ttDur
            local ratio = (baseD and effDur and baseD > 0) and (effDur / baseD) or 1
            if def.channel or def.totem then ratio = 1 end
            bH = ch * bonus * ratio
        end
    end

    -- ---- Crit (direct portion only) ----
    local critMult = 1
    if DB.crit and direct > 0 then critMult = 1 + (critPct / 100) * 0.5 end

    local directAvg = (direct + bD) * critMult
    local hotAvg    = hot + bH
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
    row.cd, row.ch, row.penalty = cd, ch, penalty
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
        if show then rows[#rows + 1] = self:ComputeEntry(e, mods, sig, bonus, critPct) end
    end
    self.lastMods = mods
    return rows, { level = level, class = class, bonus = bonus, crit = critPct, school = school }
end

-- ============================================================
-- GUI
-- ============================================================
local MainFrame
local ROWS = {}
local LH = 16
local FRAME_W, FRAME_H = 680, 520

local COLS = {
    { key = "name",  label = "Spell",    w = 168, justify = "LEFT",   sort = "spell" },
    { key = "rank",  label = "Rank",     w = 36,  justify = "CENTER" },
    { key = "level", label = "Lvl",      w = 30,  justify = "CENTER" },
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
    white  = { 1.00, 1.00, 1.00 },
    grey   = { 0.55, 0.55, 0.55 },
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
    if DB.bonus then
        local coefText = (r.cd > 0 and ("%.0f%% direct"):format(r.cd * 100) or "")
        if r.ch > 0 then coefText = coefText .. (coefText ~= "" and ", " or "") .. ("%.0f%% HoT"):format(r.ch * 100) end
        if coefText == "" then coefText = "none" end
        GT:AddDoubleLine("+Healing added:", ("+%s  (coef %s)"):format(FmtInt(r.bD + r.bH), coefText), 0.8, 0.8, 0.8, 0.6, 1, 0.6)
        if r.penalty < 1 then GT:AddLine(("  below-level-20 penalty: x%.2f"):format(r.penalty), 0.6, 0.6, 0.6) end
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
    r.sep:SetColorTexture(0.55, 0.40, 0.12, 0.6)
    r.sep:SetHeight(1)
    r.sep:SetPoint("BOTTOMLEFT", r, "TOPLEFT", 0, 1)
    r.sep:SetPoint("BOTTOMRIGHT", r, "TOPRIGHT", 0, 1)
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.85, 0.4, 0.15)
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
    bonus = "Add your +healing (spell power) to each rank using standard spell coefficients.",
    crit = "Include the average value of critical heals (direct heals only; HoTs don't crit).",
    group = "Multiply group heals (Prayer of Healing, Chain Heal, Tranquility, ...) by the number of targets they hit.",
    untrained = "Also list ranks you could train at your level but haven't yet (shown in grey).",
    hotByDuration = "HoT HPS = total heal / HoT duration (healing per second on the target) instead of total heal / time spent casting.",
}

local function MakeFrame()
    if MainFrame then return MainFrame end
    local f = CreateFrame("Frame", "HRAMainFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(FRAME_W, FRAME_H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, "HRAMainFrame")

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        f:SetBackdropColor(1, 0.88, 0.65, 1)
    else
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Background")
        bg:SetPoint("TOPLEFT", 12, -12)
        bg:SetPoint("BOTTOMRIGHT", -12, 12)
        bg:SetVertexColor(1, 0.88, 0.65, 1)
    end

    local titleBg = f:CreateTexture(nil, "ARTWORK")
    titleBg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    titleBg:SetPoint("TOP", 0, 12)
    titleBg:SetSize(360, 64)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -2)
    title:SetText("Heal Rank Advisor")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)

    f.info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.info:SetPoint("TOP", 0, -30)

    -- Column headers (click to sort)
    local HX, HY = 16, -50
    f.headers = {}
    for _, col in ipairs(COLS) do
        local b = CreateFrame("Button", nil, f)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", HX + col.x, HY)
        b:SetSize(col.w, 16)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetAllPoints()
        fs:SetJustifyH(col.justify)
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
    local div = f:CreateTexture(nil, "ARTWORK")
    div:SetColorTexture(0.55, 0.40, 0.12, 0.8)
    div:SetPoint("TOPLEFT", 16, HY - 17)
    div:SetPoint("TOPRIGHT", -36, HY - 17)
    div:SetHeight(1)

    local scroll = CreateFrame("ScrollFrame", "HRAScrollFrame", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", HX, HY - 20)
    scroll:SetPoint("BOTTOMRIGHT", -36, 64)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(FRAME_W - HX - 36, 10)
    scroll:SetScrollChild(child)
    f.scroll, f.child = scroll, child

    f.empty = child:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.empty:SetPoint("TOP", 0, -40)
    f.empty:SetWidth(FRAME_W - 100)

    f.legend = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.legend:SetPoint("BOTTOMLEFT", 20, 44)
    f.legend:SetPoint("BOTTOMRIGHT", -20, 44)
    f.legend:SetJustifyH("LEFT")
    f.legend:SetText("HoT/Cast colour: |cffffffffwhite|r = from game client, |cffffe64dyellow|r = talent applied by addon, "
        .. "|cff66ff66green|r = duration observed on your own aura.  Hover a row for the full breakdown.")

    -- Options
    local x = 18
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

    local refresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refresh:SetSize(80, 22)
    refresh:SetPoint("BOTTOMRIGHT", -18, 16)
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
        b.fs:SetText((active and "|cffffffff" or "|cffd4a017") .. b.col.label .. (active and " v" or "") .. "|r")
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
        if grouped and newGroup and i > 1 then y = y - 5 end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f.child, "TOPLEFT", 0, y)
        row:SetPoint("TOPRIGHT", f.child, "TOPRIGHT", 0, y)
        row.sep:SetShown(grouped and newGroup and i > 1)
        if i % 2 == 0 then row.bg:SetColorTexture(0.2, 0.15, 0.05, 0.25) else row.bg:SetColorTexture(0, 0, 0, 0) end
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
            if r.tf and r.tf > 1 and DB.group then nameText = nameText .. ("  |cff999999x%s|r"):format(FmtSec(r.tf)) end
            if r.e.def.auto then nameText = nameText .. " |cff999999(auto)|r" end
        end
        set("name", nameText, COLOR.gold)
        set("rank", (r.rank and r.rank > 0) and tostring(r.rank) or "-")
        set("level", (r.level and r.level > 0) and tostring(r.level) or "-")

        if r.pending then
            set("cast", ""); set("dur", ""); set("mana", ""); set("hps", ""); set("hpm", "")
            set("heal", "loading...", COLOR.grey)
        else
            local castText
            if r.channel then castText = FmtSec(r.time) .. "s ch"
            elseif r.cast <= 0 then castText = "Inst"
            else castText = FmtSec(r.cast) .. "s" end
            set("cast", castText, r.castAdjusted and COLOR.yellow or nil)

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

    f.info:SetText(("Level %d %s   |cff888888•|r   +Healing %s%s   |cff888888•|r   %s crit %.1f%%"):format(
        info.level, CLASS_DISPLAY[info.class] or (info.class or "?"):lower(),
        FmtInt(info.bonus), DB.bonus and "" or " |cff888888(off)|r",
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
            print(("[%d] %s r%s lvl%s | castNow=%s ttDur=%s effDur=%s(%s) | min=%s max=%s hot=%s tick=%s/%s | tf=%s mana=%s | HPS=%s HPM=%s"):format(
                r.id, r.name, tostring(r.rank), tostring(r.level), tostring(r.castNow), tostring(r.ttDur),
                tostring(r.effDur), tostring(r.durSrc), tostring(p.min), tostring(p.max), tostring(p.hotTotal),
                tostring(p.tick), tostring(p.interval), tostring(r.tf), tostring(r.mana),
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
