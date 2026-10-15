-- HealRankAdvisor / Data.lua
-- Static data. Everything here is a *fallback or hint*: the addon reads live
-- values (heal amounts, HoT durations, cast times, mana costs) from the game
-- client whenever it can, and uses this table only to
--   * find every rank of a spell (including ranks you haven't trained yet),
--   * know the BASE cast time / duration of a spell so it can tell whether a
--     talent bonus is already included in the client's numbers or not,
--   * look up +healing coefficients (WoW Forever tooltips already include your
--     +healing; coefficients are only used to show or remove that portion).
--
-- Rank tuple: { spellID, learnLevel, baseCastSeconds }
-- (learnLevel is only a fallback; the client is asked first.)

local ADDON_NAME, ns = ...

-- Spell school used for crit chance (2 = Holy, 4 = Nature)
ns.CLASS_SCHOOL = { PRIEST = 2, PALADIN = 2, DRUID = 4, SHAMAN = 4 }
ns.SCHOOL_NAME  = { [2] = "Holy", [4] = "Nature" }

-- Field reference
--   coef        number  -> +healing coefficient for the spell's single component
--               "cast"  -> baseCast / 3.5 (clamped 1.5/3.5 .. 1.0)
--   coefDirect / coefHot  -> explicit split for hybrid spells
--   hot         true if the spell leaves a HoT aura on the target (duration is
--               then learned from the aura after you cast it)
--   baseDur     untalented HoT / channel / totem duration in seconds
--   channel     channelled spell: "cast time" = channel duration
--   totem       totem: periodic healing over the totem's lifetime
--   targets     fixed number of targets when "Group heals" is enabled
--   targetsDefault  used only when the tooltip doesn't state the target count
ns.SPELLS = {
    PRIEST = {
        { name = "Lesser Heal", coef = "cast",
          ranks = { {2050,1,1.5}, {2052,4,2.0}, {2053,10,2.5} } },
        { name = "Heal", coef = "cast",
          ranks = { {2054,16,3.0}, {2055,22,3.0}, {6063,28,3.0}, {6064,34,3.0} } },
        { name = "Greater Heal", coef = "cast",
          ranks = { {2060,40,3.0}, {10963,46,3.0}, {10964,52,3.0}, {10965,58,3.0}, {25314,60,3.0} } },
        { name = "Flash Heal", coef = "cast",
          ranks = { {2061,20,1.5}, {9472,26,1.5}, {9473,32,1.5}, {9474,38,1.5},
                    {10915,44,1.5}, {10916,50,1.5}, {10917,56,1.5} } },
        { name = "Renew", hot = true, baseDur = 15, coefHot = 1.0,
          ranks = { {139,8}, {6074,14}, {6075,20}, {6076,26}, {6077,32}, {6078,38},
                    {10927,44}, {10928,50}, {10929,56}, {25315,60} } },
        { name = "Prayer of Healing", targets = 5, coef = 3.0 / 3.5 / 3,
          ranks = { {596,30,3.0}, {996,40,3.0}, {10960,50,3.0}, {10961,60,3.0}, {25316,60,3.0} } },
        { name = "Holy Nova", targets = 5, coef = 1.5 / 3.5 / 3,
          ranks = { {15237,20}, {15430,28}, {15431,36}, {27799,44}, {27800,52}, {27801,60} } },
        { name = "Desperate Prayer", coef = 1.5 / 3.5,
          ranks = { {13908,10}, {19236,18}, {19238,26}, {19240,34}, {19241,42}, {19242,50}, {19243,58} } },
    },

    DRUID = {
        { name = "Healing Touch", coef = "cast",
          ranks = { {5185,1,1.5}, {5186,8,2.0}, {5187,14,2.5}, {5188,20,3.0}, {5189,26,3.5},
                    {6778,32,3.5}, {8903,38,3.5}, {9758,44,3.5}, {9888,50,3.5}, {9889,56,3.5},
                    {25297,60,3.5} } },
        { name = "Regrowth", hot = true, baseDur = 21, coefDirect = 0.286, coefHot = 0.7,
          ranks = { {8936,12,2.0}, {8938,18,2.0}, {8939,24,2.0}, {8940,30,2.0}, {8941,36,2.0},
                    {9750,42,2.0}, {9856,48,2.0}, {9857,54,2.0}, {9858,60,2.0} } },
        { name = "Rejuvenation", hot = true, baseDur = 12, coefHot = 0.8,
          ranks = { {774,4}, {1058,10}, {1430,16}, {2090,22}, {2091,28}, {3627,34},
                    {8910,40}, {9839,46}, {9840,52}, {9841,58}, {25299,60} } },
        { name = "Tranquility", channel = true, targets = 5, baseDur = 10, coef = 1 / 3,
          ranks = { {740,30}, {8918,40}, {9862,50}, {9863,60} } },
    },

    PALADIN = {
        { name = "Holy Light", coef = "cast",
          ranks = { {635,1,2.5}, {639,6,2.5}, {647,14,2.5}, {1026,22,2.5}, {1042,30,2.5},
                    {3472,38,2.5}, {10328,46,2.5}, {10329,54,2.5}, {25292,60,2.5} } },
        { name = "Flash of Light", coef = "cast",
          ranks = { {19750,20,1.5}, {19939,26,1.5}, {19940,34,1.5}, {19941,42,1.5},
                    {19942,50,1.5}, {19943,58,1.5} } },
        { name = "Holy Shock", coef = 1.5 / 3.5,
          ranks = { {20473,40}, {20929,48}, {20930,56} } },
    },

    SHAMAN = {
        { name = "Healing Wave", coef = "cast",
          ranks = { {331,1,1.5}, {332,6,2.0}, {547,12,2.5}, {913,18,3.0}, {939,24,3.0},
                    {959,32,3.0}, {8005,40,3.0}, {10395,48,3.0}, {10396,56,3.0}, {25357,60,3.0} } },
        { name = "Lesser Healing Wave", coef = "cast",
          ranks = { {8004,20,1.5}, {8008,28,1.5}, {8010,36,1.5}, {10466,44,1.5},
                    {10467,52,1.5}, {10468,60,1.5} } },
        { name = "Chain Heal", coef = "cast", targetsDefault = 1.75,
          ranks = { {1064,40,2.5}, {10622,46,2.5}, {10623,54,2.5} } },
        { name = "Healing Stream Totem", totem = true, targets = 5, baseDur = 60, coef = 0,
          ranks = { {5394,20}, {6375,30}, {6377,40}, {10462,50}, {10463,60} } },
    },
}

-- ---------------------------------------------------------------------------
-- TALENTS
-- The addon reads your talent tooltips and understands lines like
--   "Reduces the casting time of your Heal and Greater Heal spells by 0.5 sec"
--   "Increases the duration of your Rejuvenation spell by 3 sec, your Regrowth spell by 6 sec"
--   "Increases the amount healed by your Renew spell by 15%"            (heal = { spell = pct })
--   "Reduces the mana cost of your Smite, Holy Fire, and instant cast spells by 9%"   (cost)
--   "Increases the critical effect chance of your Holy spells by 5%"     (crit)
--   ("*" = all heals, "@instant" = instant casts, "@holy" / "@nature" = that school)
-- so new WoW Forever talents are picked up automatically.
-- The table below is only used if a talent's tooltip can't be read/understood.
-- perRank = true  -> value is multiplied by the talent's current rank.
-- Spell names are lower-case.
-- ---------------------------------------------------------------------------
ns.TALENT_FALLBACK = {
    ["Nature's Splendor"]      = { dur  = { ["rejuvenation"] = 3, ["regrowth"] = 6 } },
    ["Divine Fury"]            = { perRank = true, cast = { ["heal"] = 0.1, ["greater heal"] = 0.1 } },
    ["Improved Healing Wave"]  = { perRank = true, cast = { ["healing wave"] = 0.1 } },
    ["Improved Healing Touch"] = { perRank = true, cast = { ["healing touch"] = 0.1 } },
    ["Naturalist"]             = { perRank = true, cast = { ["healing touch"] = 0.1 } },
    -- Healing %
    ["Improved Renew"]         = { perRank = true, heal = { ["renew"] = 5 } },
    ["Spiritual Healing"]      = { perRank = true, heal = { ["*"] = 3 } },
    ["Twin Disciplines"]       = { perRank = true, heal = { ["@instant"] = 1 } },
    ["Improved Rejuvenation"]  = { perRank = true, heal = { ["rejuvenation"] = 5 } },
    ["Gift of Nature"]         = { perRank = true, heal = { ["*"] = 2 } },
    ["Healing Light"]          = { perRank = true, heal = { ["holy light"] = 4, ["flash of light"] = 4 } },
    ["Purification"]           = { perRank = true, heal = { ["*"] = 2 } },
    -- Mana cost %
    ["Mental Agility"]         = { perRank = true, cost = { ["@instant"] = 3 } },
    ["Improved Healing"]       = { perRank = true, cost = { ["lesser heal"] = 5, ["heal"] = 5, ["greater heal"] = 5 } },
    ["Tranquil Spirit"]        = { perRank = true, cost = { ["healing touch"] = 2, ["tranquility"] = 2 } },
    ["Moonglow"]               = { perRank = true, cost = { ["healing touch"] = 3, ["regrowth"] = 3, ["rejuvenation"] = 3 } },
    ["Tidal Focus"]            = { perRank = true, cost = { ["*"] = 1 } },
    -- Crit chance %
    ["Holy Specialization"]    = { perRank = true, crit = { ["@holy"] = 1 } },
    ["Holy Power"]             = { perRank = true, crit = { ["@holy"] = 1 } },
    ["Improved Regrowth"]      = { perRank = true, crit = { ["regrowth"] = 5 } },
    ["Tidal Mastery"]          = { perRank = true, crit = { ["*"] = 1 } },
}

-- Spells that mention healing but don't belong in a heal-efficiency table.
-- (Used only for auto-detecting spells that aren't in ns.SPELLS above.)
ns.AUTO_BLACKLIST = {
    ["first aid"] = true, ["mend pet"] = true, ["health funnel"] = true,
    ["drain life"] = true, ["drain soul"] = true, ["siphon life"] = true,
    ["death coil"] = true, ["cannibalize"] = true, ["lay on hands"] = true,
    ["swiftmend"] = true, ["power word: shield"] = true, ["frenzied regeneration"] = true,
    ["lifeblood"] = true, ["vampiric embrace"] = true, ["devouring plague"] = true,
    ["victory rush"] = true, ["bloodthirst"] = true, ["seal of light"] = true,
    ["judgement of light"] = true, ["judgement"] = true, ["blessing of light"] = true,
    ["mana tide totem"] = true, ["resurrection"] = true, ["redemption"] = true,
    ["rebirth"] = true, ["revive"] = true, ["ancestral spirit"] = true,
    ["regeneration"] = true, ["shadowmeld"] = true,
}
