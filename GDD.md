# Project Hades: Game Design (condensed)

Condensed from the full GDD as of 2026-09-25. This is the **design target**, not a description of
the code. Where the code differs, the code is behind the design unless a decision below says
otherwise. For how the code is built, read `REFACTOR-2026-09.md` and `bfg-core/Docs/Architecture.md`.

Isometric top-down roguelite dungeon crawler for roughly ages 9 to 18+. Inspirations: Hades,
Ravenswatch, Minecraft Dungeons, Breath of the Wild, Genshin Impact, Risk of Rain 2. Players climb
the Arcane Spire, a living celestial megastructure, one **Realm** at a time.

## Three systems, three roles

| System | Lifetime | Role |
|---|---|---|
| Gear | Permanent | Combat foundation: weapon feel, survivability, Set Bonus |
| Arcane | Permanent | Collectible active abilities, 2 equipped, ranked by duplicates |
| Relics | One run | The run-defining build; resets after every run |

## Realms and dungeons

- Each Realm has **5 standalone dungeons**, one per element: **Earth, Blaze, Ice, Poison, Storm**.
  Dungeons have their own names, not the element's.
- Realm 1 (names updated 2026-09-25; these supersede the full GDD's):

| Dungeon | Element | Place id |
|---|---|---|
| Realm 1 Hub (Lobby) | none | 104900904749892 |
| Runegrove Forest | Earth | 139780156059811 |
| Emberforge Mines | Blaze | 116703877182196 |
| Frostveil Castle | Ice | 91639163066308 |
| Blightroot Swamp | Poison | 111154414672179 |
| Stormcrest Mountains | Storm | 73538227657906 |

- Every dungeon is its own place running the same Dungeons codebase.
- Each dungeon is **independently queueable** from the Hub's Keystone Portal.
- Difficulties per dungeon, unlocked in order and tracked per dungeon:
  **Easy, Normal, Hard, Nightmare, Ascension 1 to 10.**
  - Clearing **Hard** grants that dungeon's permanent **Keystone**.
  - Clearing **Nightmare** unlocks Ascension 1; clearing Ascension N unlocks N+1.
- **Keystone Trial:** owning all 5 Keystones unlocks it. All five dungeons chained into one
  continuous run with the relic build carried across. Failure resets the Trial; success completes
  the Realm and opens the **Realm Gate** to the next Realm.

## A normal run

Enter one dungeon, procedural encounters, gain relics, boss, loot, return to Hub. The relic build
resets afterwards. Roughly **6 to 15 gear drops** per run.

- A run is **one floor**: two combat rooms, the miniboss, two combat rooms, the boss, with two event
  rooms placed between them. The exit portal rises after the boss.
- Relic rarity odds are one flat table for the whole run.

## Relics

- About **95 relics**, up to **15 relic slots** per run.
- Fire, Ice, Storm, Earth, Poison and neutral weapon or magic synergies.

## Gear

**Slots:** 1 Melee, 1 Ranged, Helmet, Chestplate, Greaves, plus 2 Arcane slots.

**Rarity:** standard gear is Common, Uncommon, Rare, Epic. **Legendary** is a separate tier of
individually designed unique items that exist only at Legendary. No Mythic.

| Rarity | Max upgrade |
|---|---|
| Common | +4 |
| Uncommon | +6 |
| Rare | +8 |
| Epic | +10 |
| Legendary | +15 |

- **Item Level:** set by the dungeon and difficulty the item dropped from.
- **Quality:** a permanent 50 to 100 roll on every weapon and armor piece, high values increasingly
  rare. Affects only the primary stat.
- **Weapons:** one stat, Damage = f(Item Level, Rarity, Quality, Upgrade). No random substats.
  - Melee handling, fixed per named weapon: Attack Speed, Melee Range, Mobility.
  - Ranged handling, fixed per named weapon: Fire Rate, Reload Speed, Mobility.
  - Light, Medium, Heavy archetypes; different weapons are sidegrades, not strict upgrades.
  - **Enchantments** are post-launch: one rolled per weapon, a small permanent bias.
- **Armor:** one stat, Health. No substats or enchantments. Pieces belong to named **Armor Sets**;
  wearing all three pieces activates the **Set Bonus**, which is armor's real identity.
- **Per-dungeon loot pool:** 6 melee, 6 ranged, 6 armor sets (18 pieces), 2 Legendary uniques.
  - Easy mostly Common; Normal better Rare; Hard makes Rare and Epic common and allows Legendary;
    Nightmare is the same pool with much better high-rarity odds. No Nightmare-exclusive gear.

## Economy and the Blacksmith

- Currencies on the profile, never inventory items: **Gold**, **Forge Crystal** (working name, the
  one universal upgrade material), **Arcane Dust**.
- **Blacksmith** upgrades cost Gold plus Forge Crystal. Early upgrades are guaranteed; if later ones
  can fail, failure never destroys or downgrades.
- Forge Crystal comes from clears, bosses, higher difficulties, and salvaging gear.
- Selling upgraded gear refunds part of the upgrade spend.

## Arcane

- Permanently owned active spells; **2 equipped** before a dungeon.
- **10 spells per dungeon: 5 Rare, 4 Epic, 1 Legendary.** Fixed rarity and identity per spell.
- Power = base values + internal coefficient + source dungeon's tier + Arcane Rank.
  **Player level never scales Arcane damage.** Newer dungeons' spells are gradually stronger.
- **Arcane Chests**, one per dungeon, sold by the **Arcane Trainer** in the Hub: standard for Gold,
  upgraded for Robux. Each gives one spell from that dungeon's pool.
- Reveal: chest opens, an **Arcane Scroll** themed to the dungeon floats out and unrolls, the spell is
  added to the **Arcane Index** at Rank 1.
- Duplicates give Arcane XP to that exact spell; **Rank cap 5** (tentative); rank-ups are modest.
- A duplicate of a max-rank spell becomes **Arcane Dust**. Dust levels any spell, deliberately
  inefficiently, and costs scale with rarity.

| Arcane rarity | Dust per 1 XP | XP, Rank 1 to 2 |
|---|---|---|
| Rare | 10 | 50 |
| Epic | 25 | 75 |
| Legendary | 100 | 100 |

## Ascension and Dungeon Mastery

- **Ascension 1 to 10:** difficulty from modifiers, not just stats: elite frequency, enemy affixes,
  reduced healing, hazardous rooms, extra boss mechanics, cursed encounters, aggression, stacked
  modifiers. Rewards: better rarity odds, more Forge Crystal, Gold, EXP and Mastery XP. Efficiency
  and prestige, never mandatory power gating.
- **Dungeon Mastery**, per dungeon, levels 1 to 30, never resets. XP from clears, bosses,
  difficulty, elites, challenges, Keystone Trial. Rewards are only Gold, EXP, titles and cosmetics
  (milestones at 5, 10, 15, 20, 25, and a title plus mount at 30). **Never combat power or drop
  rate.**

## Hub (Lobby place)

Each Realm has a Hub town; Realm 1's is a floating settlement above the clouds. Points of interest:
Merchant (sell), Blacksmith (upgrade), Arcane Trainer (chests), Guildhall (guilds), Travelling
Salesman (rotating cosmetics), Realm Gate, and the **Keystone Portal** as the central landmark and
main dungeon queue.

## Enemies (Runegrove direction)

Stonehorn Boar (melee), Rootfang Wolf (fast melee), Thornshot Shaman (ranged), Runebark Sentinel
(tank), Briarhorn Caribou (support and healer). Readable silhouettes, stone, wood and foliage,
restrained glowing runes.

## Art and production

- Locked direction: **Painterly Arcane Fantasy**. Stylised, painterly, on light Roblox-friendly
  geometry. Every environment layers the Ancient Spire (pale stone, aged gold, cyan arcane energy),
  Nature, and a medieval Civilization layer. Technology reads as ancient magic, never cyberpunk.
- Rooms: gameplay shape first, then a landmark readable from the isometric camera, then decoration.
- Scale through systems and reuse: weapon classes, rigs, animations, modular environments, VFX
  frameworks, procedural layouts, the relic system, the Ascension system.

## Open design points

- The GDD's Arcane Chest section still says eight spells split Common 3, Rare 2, Epic 2,
  Legendary 1, and its Dust table prices Common. The rest of the GDD says 10 spells, 5 Rare,
  4 Epic, 1 Legendary, no Commons. The 5/4/1 split is assumed.
- Gold is the currency name everywhere (the code's old Coins was renamed 2026-09-25).
- Unresolved tuning: failure chances on late upgrades, Arcane XP per duplicate by rarity, and the
  Robux chest's contents and odds.
- Explicitly postponed: Fate Cards.
