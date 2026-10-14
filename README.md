# Heal Rank Advisor

A table of every healing spell rank available to your character, with average **Healing per Second (HPS)** and **Healing per Mana (HPM)**, so you can pick the right rank to downrank to.

## Installation

Copy the `HealRankAdvisor/` folder into your WoW Forever `Interface/AddOns/` directory (the same place `WaylaidCrateAdvisor` lives), then `/reload`.

## Commands

| Command | Effect |
|---|---|
| `/hra` or `/healranks` | Toggle the table |
| `/hra talents` | List talents detected as changing cast time or HoT duration |
| `/hra debug` | Print the raw parsed values for every row (useful for bug reports) |
| `/hra resetobs` | Forget learned HoT durations |
| `/hra help` | Show help |

## The table

Columns: Spell, Rank, level learned, Cast time, HoT duration, Mana, Average heal, HPS, HPM. HPS and HPM are colour-graded red → yellow → green across your trained ranks. Click the Spell, Mana, Avg Heal, HPS or HPM header to sort. Hover any row for a full breakdown including the spell's tooltip text.

Options along the bottom:

- **+Healing** — adds your bonus healing using standard vanilla coefficients (cast time / 3.5, HoT duration / 15, and the below-level-20 penalty).
- **Crit** — includes the average value of crits on the direct part of heals.
- **Group heals** — multiplies Prayer of Healing, Holy Nova, Tranquility, Chain Heal (1 + 0.5 + 0.25), etc. by the targets they hit.
- **Untrained ranks** — also lists ranks your level allows but you haven't trained yet (in grey).
- **HoT HPS by duration** — HoT HPS = heal / HoT duration (healing per second on the target) instead of heal / time spent casting (1.5 s GCD for instants).

## How talents are handled

**Cast time.** The game client's reported cast time already includes talents like Divine Fury, Improved Healing Wave, or Naturalist (and haste). The addon uses it directly. As a safety net, if a cast-time talent is detected but the client still reports the spell's untalented base cast time, the addon subtracts the talent itself and shows the cast in yellow.

**HoT duration.** Durations come from three sources, best first:

1. **Observed (green)** — whenever you cast a HoT, the addon reads the real duration off the aura you applied and remembers it per rank. This is always correct, whatever talents WoW Forever ends up having. Cast each HoT rank once to lock it in. Respeccing invalidates the stored values automatically.
2. **Talent-adjusted (yellow)** — the addon reads your talent tooltips and understands text such as "Increases the duration of your Rejuvenation spell by 3 sec, your Regrowth spell by 6 sec" (Nature's Splendor). If the spell tooltip still shows the base duration, the bonus is added.
3. **Tooltip (white)** — the spell tooltip's own duration.

Extra HoT time adds extra ticks, so total HoT healing (and its +healing share) is scaled up with the duration.

New WoW Forever talents worded in the usual "Reduces the cast time of your X spell by N sec" / "Increases the duration of your X spell by N sec" way are picked up automatically. `Data.lua` contains a small fallback table (`ns.TALENT_FALLBACK`) used only if a talent's tooltip can't be read.

## Where the numbers come from

- Heal amounts and durations: parsed from each rank's live spell tooltip, so WoW Forever's changed base values are used.
- Mana cost and cast time: read from the game client.
- Spell ranks: `Data.lua` lists vanilla spell IDs (to find untrained ranks), and the spellbook is scanned as well. Any healing spell not in the list, such as WoW Forever additions like Wild Growth, Prayer of Mending, or Binding Heal, is auto-detected from its tooltip and marked "(auto)". Those use generic coefficient and target-count guesses.

## Known limitations

- +Healing coefficients are vanilla values. WoW Forever may have adjusted them, and talents that add flat healing percentages (e.g. Spiritual Healing) are only included if the game's tooltip already includes them.
- Crit uses your school crit chance. Spell-specific crit talents (e.g. Improved Regrowth) and mana-on-crit effects (Illumination) aren't modelled.
- Tooltip parsing assumes an English client.

## Example Images
<img width="1667" height="642" alt="HealRankAdvisor screenshot 1" src="https://github.com/user-attachments/assets/4c4e2a8b-b76a-48c5-9804-f37283526d84" />

Note how Holy Light Rank 4 is greyed out as it has not been trained.

<img width="732" height="364" alt="HealRankAdvisor screenshot 2" src="https://github.com/user-attachments/assets/d3e40d8e-d112-4673-9a70-090977520c6a" />

Holy Light Rank 4 not yet trained.

<img width="857" height="669" alt="HealRankAdvisor screenshot 3" src="https://github.com/user-attachments/assets/0ba2a27b-18e1-43ae-905d-90182c3ad28c" />

HRA as shown on an undead level 30 discipline priest.

<img width="839" height="651" alt="HealRankAdvisor screenshot 4" src="https://github.com/user-attachments/assets/738fe531-e6a4-43f4-a5e3-f3ea046d910a" />

HRA as shown on an undead level 30 holy priest.
