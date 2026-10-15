# Heal Rank Advisor

A table of every healing spell rank available to your character, with average **Healing per Second (HPS)** and **Healing per Mana (HPM)**, so you can pick the right rank to downrank to.

## Installation

Copy the `HealRankAdvisor/` folder into your WoW Forever `Interface/AddOns/` directory (the same place `WaylaidCrateAdvisor` lives), then `/reload`.

## Commands

| Command | Effect |
|---|---|
| `/hra` or `/healranks` | Toggle the table |
| `/hra talents` | List your talents (and how they were read) plus every effect found on your heals |
| `/hra debug` | Print the raw parsed values for every row (useful for bug reports) |
| `/hra resetobs` | Forget learned HoT durations, mana costs and coefficient measurements |
| `/hra errors` | Show caught errors in a window you can copy from |
| `/hra help` | Show help |

## When the table updates

The addon does nothing in the background. The table is calculated only when:

- you open it for the first time in a session,
- you click **Refresh**, or
- you tick or untick one of the options.

Re-opening the window shows the last results, and the top line shows the time they were calculated ("Updated 14:32"). Click Refresh after levelling, training, respeccing or changing gear. Sorting by a column only re-orders the existing rows.

Learning HoT durations from your casts only listens while the window is open. Learned values appear the next time you click Refresh.

Errors are caught instead of being shown on screen. The first one prints a single chat line, and `/hra errors` opens a window where you can select and copy them all.

## The table

Columns: Spell, Rank, level learned, Bonus (share of your +healing the rank keeps; ~ = estimated), Cast time, HoT duration, Mana, Crit, Average heal, HPS, HPM. HPS and HPM are colour-graded red → yellow → green across your trained ranks. Click the Spell, Mana, Avg Heal, HPS or HPM header to sort. Hover any row for a full breakdown including the spell's tooltip text.

Options along the bottom:

- **+Healing** — on by default (tooltips already include it). Untick to see each rank's base heal with your spell healing removed.
- **Crit** — includes the average value of crits on the direct part of heals.
- **Group heals** — multiplies Prayer of Healing, Holy Nova, Tranquility, Chain Heal (1 + 0.5 + 0.25), etc. by the targets they hit.
- **Untrained ranks** — also lists ranks your level allows but you haven't trained yet (in grey).
- **HoT HPS by duration** — HoT HPS = heal / HoT duration (healing per second on the target) instead of heal / time spent casting (1.5 s GCD for instants).

## How +healing is handled

WoW Forever's spell tooltips **already include** your spell healing, the downranking penalty and healing talents like Improved Renew. This was verified in game on a level 30 priest at 16 and 151 spell healing. The addon therefore uses each rank's tooltip value as-is for Avg Heal, HPS and HPM.

It still works out the +healing portion of each heal, to show it in the **Bonus** column and to remove it when the **+Healing** box is unticked:

- **Measured (no ~).** The addon remembers every rank's tooltip at the lowest and highest spell healing it has seen at your current level and talents. Once those are 20+ apart (swap a healing item on and off once), the change in heal ÷ change in spell healing is the rank's exact coefficient.
- **Estimated (~).** Until then it uses the vanilla coefficient (cast time / 3.5, HoT duration / 15) × talent healing % × WoW Forever's downranking share `1 - (L - 17 - T) x 0.05` (clamped 0-100%, L = your level, T = the rank's learn level).

The original game's below-level-20 penalty is not used. It does not exist in WoW Forever: Heal rank 1 (learned at 16) and Renew rank 2 (learned at 14) keep their full coefficient. The downranking formula matched the in-game tooltips for 9 of 10 ranks tested. Lesser Heal rank 1 kept about 24% where the formula predicts 40%, which is why measured values take priority.

If the tooltip doesn't change at all with spell healing, the addon concludes that tooltip excludes +healing and adds the estimate itself.

## How talents are handled

**Cast time.** The game client's reported cast time already includes talents like Divine Fury, Improved Healing Wave, or Naturalist (and haste). The addon uses it directly. As a safety net, if a cast-time talent is detected but the client still reports the spell's untalented base cast time, the addon subtracts the talent itself and shows the cast in yellow.

**HoT duration.** Durations come from three sources, best first:

1. **Observed (green)** — whenever you cast a HoT, the addon reads the real duration off the aura you applied and remembers it per rank. This is always correct, whatever talents WoW Forever ends up having. Cast each HoT rank once to lock it in. Respeccing invalidates the stored values automatically.
2. **Talent-adjusted (yellow)** — the addon reads your talent tooltips and understands text such as "Increases the duration of your Rejuvenation spell by 3 sec, your Regrowth spell by 6 sec" (Nature's Splendor). If the spell tooltip still shows the base duration, the bonus is added.
3. **Tooltip (white)** — the spell tooltip's own duration.

Extra HoT time adds extra ticks, so total HoT healing (and its +healing share) is scaled up with the duration.

New WoW Forever talents worded in the usual "Reduces the cast time of your X spell by N sec" / "Increases the duration of your X spell by N sec" way are picked up automatically. `Data.lua` contains a small fallback table (`ns.TALENT_FALLBACK`) used only if a talent's tooltip can't be read.

**How talents are read.** WoW Forever has no `GetNumTalentTabs` / `GetTalentInfo`. Its talent frame uses the modern trait system, so the addon reads your talents the same way: through `C_ClassTalents` and `C_Traits` (config → trees → nodes → rank and spell). Each talent's text comes from its trait tooltip at your current rank. The old Classic functions are still tried as a fallback on other clients. If a tooltip can't be read, the fallback table in `Data.lua` is used and marked with `*` in `/hra talents`.

**Secret values.** Like Midnight, Forever can return "secret" values (for example your mana in combat) that addons can't compare. The cast-learning code checks for them and skips that cast instead of raising an error.

**Healing %, mana cost and crit talents.** The addon reads every talent you have points in and understands wording such as:

- "Increases the amount healed by your Renew spell by 15%" / "Increases the damage and healing of your instant cast spells by 5%" (Improved Renew, Twin Disciplines, Spiritual Healing, ...)
- "Reduces the mana cost of your Smite, Holy Fire, and instant cast spells by 9%" (Mental Agility, Improved Healing, Moonglow, ...)
- "Increases the critical effect chance of your Holy spells by 5%" (Holy Specialization, Improved Regrowth, ...)

"Instant cast spells" means heals with no cast time (Renew, Holy Nova, ...). "Holy spells" / "Nature spells" means every heal of your class's school. Effects that depend on a condition (Renewed Hope's Weakened Soul bonus, Inner Focus, Illumination's mana refund) are not counted.

Each effect is only applied if the game hasn't already applied it, so nothing is counted twice:

- **Healing %** is already in WoW Forever's tooltips (verified for Improved Renew). Once a spell's coefficient has been measured, the addon checks the tooltip actually contains the talent multiplier and applies it itself if it doesn't.
- **Mana cost.** The game's spell cost already includes cost talents (verified in game: Lesser Heal rank 3 costs 64 mana with Improved Healing 3/3, which is 75 minus 15%). The addon uses the game's cost as-is and lists which talents lowered it when you hover a row.
- **Crit.** The character sheet shows only your base spell crit. Talents are never included (verified in game: 6.9% with 0 and with 5 points in Holy Specialization). The addon adds every crit talent that applies to a spell on top. The **Crit** column shows each heal's crit chance (yellow = includes talents, "-" for HoTs), and the header shows your crit with talents.

`/hra talents` lists every talent effect found and whether mana cost talents are in the game's costs. Hover a row to see which talents affect that spell.

## Where the numbers come from

- Heal amounts and durations: parsed from each rank's live spell tooltip, so WoW Forever's changed base values are used.
- Mana cost and cast time: read from the game client.
- Spell ranks: `Data.lua` lists vanilla spell IDs (to find untrained ranks), and the spellbook is scanned as well. Any healing spell not in the list, such as WoW Forever additions like Wild Growth, Prayer of Mending, or Binding Heal, is auto-detected from its tooltip and marked "(auto)". Those use generic coefficient and target-count guesses.

## Known limitations

- Estimated +healing shares use vanilla coefficients until the addon has measured a rank. This only affects the Bonus column and the +Healing-off view, not Avg Heal/HPS/HPM.
- Conditional talent effects (Renewed Hope, Illumination, Litany of Light, Inner Focus) aren't modelled.
- Tooltip parsing assumes an English client.


## Example Images

<img width="922" height="691" alt="HealRankAdvisor screenshot" src="https://github.com/user-attachments/assets/dc3c6398-4af8-4a37-9df1-e6fad1404437" />

Note how Holy Light Rank 4 is greyed out as it has not been trained.

<img width="732" height="364" alt="HealRankAdvisor screenshot 2" src="https://github.com/user-attachments/assets/d3e40d8e-d112-4673-9a70-090977520c6a" />

Holy Light Rank 4 not yet trained.

<img width="857" height="669" alt="HealRankAdvisor screenshot 3" src="https://github.com/user-attachments/assets/0ba2a27b-18e1-43ae-905d-90182c3ad28c" />

HRA as shown on an undead level 30 discipline priest. (OLD GUI)

<img width="933" height="717" alt="HealRankAdvisor screenshot 2" src="https://github.com/user-attachments/assets/2161e752-534b-4960-ad44-7252b62a349b" />

HRA as shown on an undead level 30 holy priest.
