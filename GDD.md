# Project Hades: Game Design (condensed)

Condensed from the full GDD as of 2026-09-25, redirected on 2026-10-31. This is the **design
target**, not a description of the code. Where the code differs, the code is behind the design
unless a decision below says otherwise. For how the code is built, read `REFACTOR-2026-09.md` and
`bfg-core/Docs/Architecture.md`.

Isometric top-down **action RPG dungeon crawler with a run loop**, for roughly ages 9 to 18+.
Progression like Dungeon Quest and Minecraft Dungeons: permanent gear is the game, a run is the
content loop, and relics are the per-run spice. Combat feel from Hades. Players climb the Arcane
Spire, a living celestial megastructure, one **Realm** at a time.

**Design freeze (2026-10-31).** The decisions in this document are frozen for 30 days after the
first external play-test. Exceptions: bugs, and problems the test shows. New systems wait.

## Three systems, three roles

| System | Lifetime | Role |
|---|---|---|
| Gear | Permanent | All of the player's numbers: damage, health, later secondary stats. The chase. |
| Arcane | Permanent | Collectible active spells, 2 equipped, ranked by duplicates. The burst. |
| Relics | One run | Visible effects that change how a run plays. Never a stat. |

Nothing the player buys with Robux changes a combat number.

## Power and Level

Two numbers, two jobs, shown together ("Lv 14 · Power 820").

| | Level | Power |
|---|---|---|
| What it is | Account XP, earned per run | Strength of what is equipped right now |
| Measures | How much you have played | How hard you hit |
| Gates | Unlocks only: relic slots, Mastery, dungeon tiers, Arcane slots, the gear level you can equip | Nothing hard. The tier-select warning only |
| Changes when | A run ends | You equip, upgrade or swap anything |

- **Power = the equipped weapon's damage per second at its type's base cadence** (the higher of
  melee and ranged). A 50-damage sword at 1.2 swings a second is 60; a 20-damage gun at 4 shots a
  second is 80. Spell rank is not in the number.
- Tier select shows a recommended Power per difficulty with a warning below it, never a lock.
- **Level never multiplies damage.** Power never unlocks anything.

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
  **Easy, Normal, Hard, Nightmare.** (Ascension was cut on 2026-10-30.) Easy is the tutorial,
  Normal is moderate, Hard and Nightmare are meant to kill under-geared players. Nightmare stays
  in; the Power warning is its gate.
  - Clearing **Hard** grants that dungeon's permanent **Keystone**.
- **Keystone Trial:** owning all 5 Keystones unlocks it. All five dungeons chained into one
  continuous run with the relic build carried across. Failure resets the Trial; success completes
  the Realm and opens the **Realm Gate** to the next Realm.

## A normal run

Enter one dungeon, procedural encounters, pick relics, boss, loot, return to Hub. The relic build
resets afterwards. Roughly **6 to 15 gear drops** per run.

- A run is **one to three floors by difficulty** (Easy 1, Normal 2, Hard and Nightmare 3).
  Every floor before the last is four combat rooms, one event, the Merchant Shop and the boss:
  a combat room first, the boss last, and the event and the shop at random doors in between, never
  back to back (for example C E C C S C B). Its event never rolls a second shop.
- **Only the run's last floor has a miniboss:** two combat rooms, the miniboss, two combat rooms,
  the boss. Its shop sits at the last door before the boss and its event before the miniboss
  (never a second shop on Easy's single floor). Normal and above may roll a third event there
  (30 / 40 / 50%).
- A floor's boss room ends on a Descend pad to the next floor; the exit portal rises only after the
  final floor's boss. Gems, relics and the loot escrow carry across floors. Chest rewards are
  back-loaded (40/60 on two floors, 25/35/40 on three).
- **Relic picks: one per floor plus one from the final boss** (Easy 2, Normal 3, Hard and Nightmare
  4; the Merchant Shop and Cursed Shrine add to that). Each pick is 1 of 3. A Legendary pity
  guarantees one by the last pick.
- **Death, wipe or leaving before the clear ends the run.** Gear in escrow is **kept**. Half the
  run's Gold and Arcane Crystals are lost; Gems are lost. Lives: 1 on every tier.

## Statuses

Five statuses. Relics apply them; gear never does. Same status refreshes duration, different
statuses coexist. No stacking except Death Venom.

| Status | Effect | Notes |
|---|---|---|
| Burn | 25% of Power per second for 4s | DoT. Black Flame (Katana) doubles it. |
| Chill | 30% slow for 4s | Control. |
| Poison | 12% of Power per second for 6s, target deals 10% less | DoT plus Weaken. Death Venom (Skeletal Scythe) stacks to 3. |
| Shock | +10% damage taken for 6s | **The only damage-increasing status.** Coil Shocked (Coil Gun) is +20%. Vulnerability total capped at +30%. |
| Barrier | Shield worth x% of max health | On the player. Blocks damage before health. |

- **DoTs scale off Power, never off the hit that applied them**, so a gun, a sword and a spell set
  the same Burn and a bigger weapon means a bigger Burn. Bosses take the same Burn as grunts.
- Melted (Burning + Poisoned) makes DoTs tick twice as fast. Petrified (Medusa) is a 2s stun.
  Neither increases damage taken.

## Relics

**46 relics plus 5 Duos.** Five per element (Blaze, Frost, Venom, Storm, Earth), ten Ancient
(no element), six Cursed. Each element tree is 2 Rare, 2 Epic, 1 Legendary.

**Rules**

- A relic is never a percentage on the player. No +% damage, crit, speed, mana or reduction.
  The exceptions are Cursed relics (a big number with a cost) and Ancient utility (Speed Coil,
  Gravity Coil), which gear does not roll.
- **Triggered relics scale off the hit** that fired them (Flame Wave 75% of the swing). **Passive
  relics scale off Power** (Wyrm orbs, Fireworks, puddles, every DoT). Each damage relic is
  budgeted at about +20% of gear DPS, so five of them roughly double it and a utility pick costs a
  fifth of that.
- **NC / C.** Four relics per tree are **NC** (no condition, work on their own). One is **C** and
  needs the tree's status; it is offered only once the player holds a relic from that tree, so no
  one is locked out of half the pool on pick one.
- **Roll:** pick a tree first (six, equal weight), then a card by rarity (Rare 80 / Epic 18 /
  Legendary 1 / Duo 1). Cursed come only from the Cursed Shrine. The offer, the Shop and the vending
  machines use one eligibility check.
- **Duos** need a relic from both trees this run and roll at Legendary weight.
- Co-op: a relic reads the status on the enemy whoever applied it. Barrier relics read your own.
- Card text is one sentence, one coloured keyword, and is the source of truth for the number.

**Blaze** (Burn)

| Relic | Rarity | C? | Effect |
|---|---|---|---|
| Ye Olde Fire Breath Potion | Rare | NC | Hits have a chance to Burn (25% weapon hits, 50% spell hits). |
| Dragon's Flame Sword | Epic | NC | Every 3rd Melee swing fires a Flame Wave for 75% of the swing that Burns. |
| Berserker's Claymore | Epic | NC | Weapon hits on Burning enemies splash 40% of the hit to nearby enemies. |
| Trick Or Trap | Epic | NC | Takedowns drop an Explosive Pumpkin that deals damage and Burns. |
| Flame Ronin Katana | Legendary | C | Burn becomes Black Flame, dealing double. Crits on Black-Flamed enemies detonate it. |

**Frost** (Chill)

| Relic | Rarity | C? | Effect |
|---|---|---|---|
| Frozen Blue Ice Crossbow | Rare | NC | Hits have a chance to Chill (25% weapon hits, 50% spell hits). |
| Ice Breaker | Rare | C | Chilling a Chilled enemy Shatters it for damage, removing the Chill. |
| Ice Dragon Slayer | Epic | NC | A Frost Wyrm follows you, firing an orb every 1.5s that deals Power damage and Chills. |
| Icy Arctic Fowl | Epic | NC | Every 3s, fire 3 ice shards at nearby enemies for Power damage. |
| Staff of Azure Ever Ice | Legendary | NC | Spells leave a 5s Frost Zone that Chills and deals Power damage per second. |

**Venom** (Poison)

| Relic | Rarity | C? | Effect |
|---|---|---|---|
| Zombie Axe | Rare | NC | Hits have a chance to Poison (25% weapon hits, 50% spell hits). |
| Witches Brew | Rare | NC | Every 5th Ranged shot lobs a poison bubble that leaves a 3s Poison puddle. |
| Foul Poison Fowl | Epic | NC | Takedowns leave a 5s Poison cloud that damages and Poisons. |
| Skeletal Scythe | Epic | C | Poison becomes Death Venom, stacking up to 3 times. |
| Zombie Bomb | Legendary | NC | Hits have 20% chance to spit poison goop at nearby enemies, Poisoning them. |

**Storm** (Shock)

| Relic | Rarity | C? | Effect |
|---|---|---|---|
| Static Shock Sheep | Rare | NC | Hits have a chance to Shock (25% weapon hits, 50% spell hits). |
| Sparkle Time Hoverboard | Rare | NC | Your dodge becomes a longer lightning dash that damages and Shocks enemies you pass through. |
| Deluxe Coil Gun | Epic | C | Shock becomes Coil Shocked: +20% damage taken from all sources. |
| Lightning Bolt Sword | Epic | NC | Hits have a chance to chain lightning to up to 3 enemies for 50% of the hit, Shocking them. |
| Lightning Horn of the Heavens | Legendary | NC | Hits have 20% chance to call a lightning strike for area Power damage (0.25s cooldown). |

**Earth** (Barrier)

| Relic | Rarity | C? | Effect |
|---|---|---|---|
| Robloxian Battle Shield | Rare | NC | Casting a spell grants a 10% Barrier for 5s. |
| Golden Steampunk Gloves | Rare | NC | Weapon hits have a chance to grant a 5% Barrier for 3s and knock back harder. |
| Bundle of TNT | Epic | C | Barriers explode when they end, dealing damage to nearby enemies. |
| Spartan Sword and Shield | Epic | NC | 2 shields orbit you, dealing damage and granting a 1% Barrier per hit for 3s. |
| Golem's Hammer | Legendary | NC | Taking damage grants a 10% Barrier for 3s. While Barriered, the earth quakes under you each second. |

**Ancient** (no element, all NC)

| Relic | Rarity | Effect |
|---|---|---|
| Fuse Bomb | Rare | Takedowns drop a Fuse Bomb. |
| Speed Coil | Rare | +8 Movement Speed. |
| Gravity Coil | Rare | +1 Dodge stack. |
| Summer Fireworks | Rare | Every 3s, launch 3 Fireworks for Power damage. |
| Experimental Jetpack | Rare | Perfect Dodges grant an invulnerable Jetpack for 2s. |
| Orinthian Blaster 3777 | Epic | Ranged Weapon Damage becomes Arcane Damage. |
| Sword of the Epicredness | Epic | Spells deal Weapon Damage instead. |
| Super Stomp Boots | Epic | Your dodge ends in a Ground Stomp. |
| Volleyball | Epic | Every 3rd Ranged attack spikes a Volleyball for 250% of the shot. |
| Portable Justice | Epic | Hits have 10% chance (50% spells) to Jail non-Boss enemies for 3s, 5s cooldown per enemy. |
| Ban Hammer | Legendary | Enemies below 20% health (5% on Bosses) are executed by a falling Ban Hammer. |

**Duo** (hold a relic from both trees)

| Relic | Trees | Effect |
|---|---|---|
| HEX Spitter | Blaze + Storm | When a Shocked enemy starts Burning it bursts in a plasma nova for 100% Power nearby. |
| Fire Breathing Friend | Blaze + Venom | Enemies both Burning and Poisoned are Melted: your DoTs on them tick twice as fast. |
| Blizzard Wand | Frost + Storm | Shocking a Chilled enemy calls a 3s hailstorm on it; shards deal Power damage and Chill. |
| Korblox Ice Claws | Frost + Earth | When your Barrier ends it shatters for Power damage, Chilling nearby enemies. |
| Medusa Head | Earth + Venom | Poisoning an enemy while Barriered Petrifies it for 2s. |

**Cursed** (Cursed Shrine only)

| Relic | Effect |
|---|---|
| Double-Bladed Scythe | +100% Weapon Damage, but Arcane deals no damage. |
| Dragon Lantern | +200% Gold and Gems, but lose 10% of both when you take damage. |
| Forbidden Box | +100% Arcane Damage, but Weapon Damage −50%. |
| Slateskin Potion | +50% Damage Reduction, but lose 1 Dodge stack. |
| Sword of Eternal Abyss | +50% damage, but you can't apply Statuses. |
| Teddy Trap | +5% Lifesteal, but Health Orbs don't heal you and you take +100% damage. |

**Shelved, not deleted** (models and data kept behind a flag for a later rotation): Astral Cloak,
Holiday Ham, Mystical Staff of Cyan, Glorious Sword, Neon Rainbow Phoenix, Flaming Orb of Divine
Pain, Magenta Paintball Gun, Rubber Chicken Launcher, Mechatronic Spider, Overseer's Battleaxe,
Earth Summoning Horn, War Rocks, Korblox Mage Staff, Frozen Flail, Shuriken of the Crescent Moon,
Regeneration Coil, Pot Of Gold, Wizard Orb, Linked Sword, Red Laser Scythe, Blue Laser Scythe.
Retired outright: every aura opener and "while <aura>" relic, every flat +% relic.

## Auras

**Auras are cosmetics.** The five rigs (Enflamed, Frostburst, Blighted, Stormcharged, Stonebound)
play on the character in the Hub and the dungeon and change no number. The base aura of each
element unlocks from that element's Mastery or a Nightmare clear with its weapon; colour and
particle variants sell for Robux and rank up on duplicates like Arcane. A purchased aura never
changes a combat number.

## Gear

**Slots:** 1 Melee, 1 Ranged, Helmet, Chestplate, Greaves, plus 2 Arcane slots.

**Rarity:** standard gear is Common, Uncommon, Rare, Epic. **Legendary** is a separate tier of
individually designed unique items that exist only at Legendary. No Mythic.

| Rarity | Max upgrade |
|---|---|
| Common | +4 |
| Uncommon | +5 |
| Rare | +6 |
| Epic | +8 |
| Legendary | +10 |

Each upgrade counts as one Item Level (+15% of base), so a +2 Level 1 item
beats a Level 2 one of the same quality.

- **Item Level:** set by the dungeon and difficulty the item dropped from.
- **Quality:** a permanent 50 to 100 roll on every weapon and armor piece, high values increasingly
  rare. Affects only the primary stat: 50 is ×0.85, 100 is ×1.25. It is the chase, on every
  difficulty.
- **Weapons:** one stat, Damage = f(Item Level, Rarity, Quality, Upgrade). Power is this number
  at the type's cadence.
  - Melee handling, fixed per named weapon: Attack Speed, Melee Range, Mobility.
  - Ranged handling, fixed per named weapon: Fire Rate, Reload Speed, Mobility.
  - Light, Medium, Heavy archetypes; different weapons are sidegrades, not strict upgrades.
- **Armor:** one stat, Health. Pieces belong to named **Armor Sets**; wearing all three pieces
  activates the **Set Bonus**.
- **Per-dungeon loot pool:** 6 melee, 6 ranged, 6 armor sets (18 pieces), 2 Legendary uniques.
  - Easy mostly Common; Normal better Rare; Hard makes Rare and Epic common and allows Legendary;
    Nightmare is the same pool with much better high-rarity odds. No Nightmare-exclusive gear.
- **No character stats**, ever. What a stat point would do, a gear line does.
- **Post-launch, after the first test:**
  - **Secondary lines** rolled by rarity (Common 0, Rare 1, Epic 2, Legendary 3), magnitude by
    quality: weapons roll Critical Chance, Critical Damage, Attack Speed, Status Chance, Ammo;
    armor rolls Damage Reduction, Movement Speed, Dodge Recovery, Healing Received, Gold Find;
    spells roll Cooldown Reduction, Mana Cost. The Set Bonus folds into lines. The Blacksmith
    rerolls lines for Gold.
  - **A Staff weapon type** whose mana-free bolt deals Arcane Damage, so a mage's Power is their
    staff. Only if testers ask to be a pure mage; Minecraft Dungeons never did this.

## Economy and the Blacksmith

- Currencies on the profile, never inventory items: **Gold**, **Arcane Crystals** (was Forge Ore)
  and **Gems** (in-run only).
- **Gold buys Power:** Blacksmith upgrades cost Gold only. The old Ore share is folded into the
  Gold price so runs-to-max per tier is unchanged. Early upgrades are guaranteed; failure, if any,
  never destroys or downgrades.
- **Arcane Crystals buy spells:** Arcane Chests are priced in Crystals, and Crystals can be fed
  straight into an owned spell as rank XP at a worse rate than the chest's expected value.
  Crystals come from ore veins, chests, bosses and higher difficulties.
- Selling gear refunds 80% of its Gold upgrade spend. Sales pay Gold only.
- Run income per tier (Gold 500 / 1,000 / 2,000 / 4,000 split between chests and gear sales;
  Crystals 25 / 50 / 100 / 200) with treasure chests and pots as a 20% bonus on top.

## Arcane

- Permanently owned active spells; **2 equipped** before a dungeon.
- **10 spells per dungeon: 5 Rare, 4 Epic, 1 Legendary.** Fixed rarity and identity per spell.
- Power = base values + internal coefficient + source dungeon's tier + Arcane Rank.
  **Player level never scales Arcane damage.** Spell rank scales spells and nothing else; it is
  not part of the player's Power number.
- **Arcane Chests**, one per dungeon, sold by the **Arcane Trainer** in the Hub: standard for
  Arcane Crystals, premium for Robux (Runegrove 25) that is always Epic or better (Epic 90 /
  Legendary 10). Each gives one spell from that dungeon's pool.
- Reveal: chest opens, an **Arcane Scroll** themed to the dungeon floats out and unrolls, the spell is
  added to the **Arcane Index** at Rank 1.
- Duplicates give Arcane XP to that exact spell (Rare 50 / Epic 100 / Legendary 500 a copy);
  **Rank cap 10**. Rank 1 deals base damage and each Rank after adds 50% (Rank 10 is x5.5). Rank 1
  to 2 costs Rare 50 / Epic 75 / Legendary 100 XP, each later step that times the current Rank.
- A duplicate of a max-rank spell **refunds 75% of the chest's price**. (Arcane Dust was cut on
  2026-10-30.)
- Post-launch: high ranks gain a perk beyond numbers (an extra projectile, a longer zone, a shorter
  cooldown), as Minecraft Dungeons does with artifact rarity.

## Dungeon Mastery

- **Dungeon Mastery**, per dungeon, levels 1 to 30, never resets. XP from clears, bosses,
  difficulty, elites, challenges, Keystone Trial. Rewards are only Gold, EXP, Arcane Crystals
  (every third level), titles, aura cosmetics and other cosmetics (milestones at 5, 10, 15, 20,
  25, and a title plus mount at 30; a milestone pays both Gold and EXP). A level pays at most two
  currencies: a milestone on a Crystals level pays Gold and Crystals. **Never combat power or
  drop rate.**
- **Wardrobe** (hub menu, 2026-10-31; built, its button held back until the cosmetics are ready
  to show): every cosmetic the player owns, a tab per kind (Titles,
  Banners, Cloaks, Mounts; armor, weapon and aura skins later), one worn per kind. Banners and
  cloaks are worn on the back in both places; a mount is summoned in the hub (M, or the Wardrobe's
  button) and carries the player faster. The three Runegrove pieces are placeholder models.

## Hub (Lobby place)

Each Realm has a Hub town; Realm 1's is a floating settlement above the clouds. Points of interest:
Merchant (sell), Blacksmith (upgrade), Arcane Trainer (chests), Guildhall (guilds), Travelling
Salesman (rotating cosmetics), Realm Gate, and the **Keystone Portal** as the central landmark and
main dungeon queue.

## Enemies (Runegrove direction)

Stonehorn Boar (melee), Rootfang Wolf (fast melee), Thornshot Shaman (ranged), Runebark Sentinel
(tank), Briarhorn Caribou (support and healer). Readable silhouettes, stone, wood and foliage,
restrained glowing runes.

Tier scaling: mob health ×1.5 / 3 / 6 / 12 and damage ×1 / 1.47 / 1.68 / 2.14 by tier, re-solved
after the relic refactor removes the aura stat half from every build.

## Art and production

- Locked direction: **Painterly Arcane Fantasy**. Stylised, painterly, on light Roblox-friendly
  geometry. Every environment layers the Ancient Spire (pale stone, aged gold, cyan arcane energy),
  Nature, and a medieval Civilization layer. Technology reads as ancient magic, never cyberpunk.
- Rooms: gameplay shape first, then a landmark readable from the isometric camera, then decoration.
- Scale through systems and reuse: weapon classes, rigs, animations, modular environments, VFX
  frameworks, procedural layouts, the relic system.

## Roadmap to the first test

1. Currencies: Forge Ore becomes Arcane Crystals; upgrades Gold-only; chests priced in Crystals;
   direct-feed; migration.
2. Power: computed, stamped, shown on nameplate and tier select; warning gate; relic scaling reads
   Power instead of player level.
3. Death keeps gear.
4. Relic refactor: the 46 + 5 above, NC/C gating, tree-first roll, Duos, every proc and DoT on
   Power; auras converted to cosmetics.
5. Mob re-solve against the new damage composition.
6. External play-test: 10 to 20 players, half on phones, no explanations. Then the 30-day freeze.

After the test: gear secondary lines, Staff weapon type, aura variants for Robux, rank perks,
the shelved relics as a rotation.

## Open design points

- The GDD's Arcane Chest section still says eight spells split Common 3, Rare 2, Epic 2,
  Legendary 1. The rest of the GDD says 10 spells, 5 Rare, 4 Epic, 1 Legendary, no Commons. The
  5/4/1 split is assumed; Runegrove's authored pool is still work in progress.
- Gold is the currency name everywhere (the code's old Coins was renamed 2026-09-25).
- Unresolved tuning: failure chances on late upgrades; the exact Crystal price of an Arcane Chest
  and the direct-feed rate; Earth's numbers once Nightmare is tested.
- Explicitly postponed: Fate Cards.
