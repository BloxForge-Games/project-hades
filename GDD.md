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

- A run is **one floor on every tier** (several floors made runs too long). Combat rooms by
  tier: Easy 3, Normal 4, Hard 5, Nightmare 5, with the miniboss after the middle one and the
  boss last. Every combat room is two waves, except that Nightmare's rooms past the miniboss are
  three, so a run is 6 / 8 / 10 / 12 waves (32 / 50 / 68 / 86 mobs solo). One event sits on a random door between the first combat room and the boss, and a
  second rolls at 50% on another door, never back to back (for example C E C M E C B).
- **Economy per run** (solo, Runegrove): kill EXP is scaled so a run pays what it always did
  (grunt EXP x 2.72 / 3.48 / 3.84 / 3.03); run Gold 125 / 250 / 500 / 1000 is 60% chests (75 /
  150 / 300 / 600, split 40% miniboss chest / 60% boss chest) and 40% grunt drops (50 / 100 /
  200 / 400, about 1 to 3 a kill on Easy and 6 to 9 on Nightmare, scaled from the old Gem rows);
  Crystals 50 / 100 / 200 / 400 are per run from the two chests; the boss chest drops 1 / 2 / 3 /
  4 gear pieces and the miniboss 1; expected gear sales are 80 / 150 / 270 / 485 Gold, so a run's
  Gold take is 205 / 400 / 770 / 1485 and Blacksmith prices follow (Gold halved and Crystals
  doubled on 2026-11-01; prices are shares of the take, so they halved with it).
- **Gold sinks:** Blacksmith upgrades (half a run for a Common up to two runs for a Legendary,
  50% of it back on a sale) and **line rerolls** (one gear line becomes another stat from its slot's
  pool with a fresh roll, a quarter of a run of the item's level, flat). A hub gear merchant for
  Gold is specced separately.
- **The event pool opens by tier:** Easy has the Healing Fountain and the Forge; Normal and Hard
  add the Coffin and the Cursed Shrine; Nightmare adds the Sword in the Stone. The Merchant Shop
  is out of the pool (its code stays).
- The exit portal rises after the boss. Chest rewards all land on that one floor.
- **Relic picks** come from the vending machines and the Cursed Shrine; the pick count and a
  Legendary pity are open tuning after the first test.
- **Death, wipe or leaving before the clear ends the run.** Nothing picked up is lost: gear banks
  at pickup and the run's Gold and Arcane Crystals bank in full. Dying only costs the chests not
  yet opened. Lives: 1 on every tier. Gems no longer drop (no sink without the Merchant); grunts
  drop Gold in their place, which stays until the next combat room like Gems did. The HUD shows
  banked Gold and Crystals plus the run's gains.

## Statuses

Five enemy statuses, one per tree, plus the player's Shield. Weapon enchantments open them (a
20% chance per hit from the weapon that carries the enchantment) and each tree's relics apply
their own. Same status refreshes duration, different statuses coexist. Burn and Poison stack per
player (two players each keep their own tick on one enemy); within one player nothing stacks
except Death Venom.

| Status | Effect | Notes |
|---|---|---|
| Burn | 25% of Power per second for 5s | DoT. Black Flame (Flame Ronin Katana) doubles it. |
| Chill | 30% slow for 5s | Control. |
| Poison | 15% of Power per second for 5s, target deals 10% less | DoT plus Weaken (10% on 2026-10-31, 15% since 2026-11-01). Death Venom (Skeletal Scythe) stacks to 3. |
| Shock | +10% damage taken for 5s | **The only damage-increasing status.** Coil Shocked (Coil Gun) is +20%. Vulnerability total capped at +30%. |
| Fractured | The enemy shatters on death: 50% chance to drop an Orb | Earth's status (2026-11-01), shown with the Stonebound aura rig on the enemy. Health Orb if its applier is under 90% Health, Mana Orb otherwise. No tick, no slow. |
| Shield | Shield worth x% of max health | On the player. Blocks damage before health. |

- **DoTs scale off Power, never off the hit that applied them**, so a gun, a sword and a spell set
  the same Burn and a bigger weapon means a bigger Burn. Bosses take the same Burn as grunts.
  The Corrosion enchantment multiplies every tick (+20% Status Damage per weapon).
- Every status lasts 5s; a reapply refreshes the timer. Melted (Burning + Poisoned) makes DoTs
  tick twice as fast. Petrified (Medusa, shelved) is a stun on the same 5s.
  Neither increases damage taken.
- **Crit** is 10% base (5% before 2026-11-01), 1.75x damage. The Critical Chance gear line rolls 5
  to 12 points per weapon and Stormcharged adds 10 per weapon. Every tree has a guaranteed crit
  somewhere (the Bo Staff's rhythm, the Katana's dodge, the Horn's strike on crits), so the
  Critical Damage line is worth chasing.

## Relics

**Relic slots: 5 at most.** Easy opens 3, Normal 4, Hard and Nightmare 5. The tray always draws
five boxes; a locked one shows a lock and says which tier opens it. The Merchant's slot stand is
retired (slots come from the tier, not Gems).

**45 live relics.** Five per element (Blaze, Frost, Venom, Storm, Earth: 2 Rare, 2 Epic,
1 Legendary), 14 Neutral (8 Rare, 5 Epic, 1 Legendary) and 6 Cursed. Everything else in
`RelicData` is `retired`: shelved, never rolled, sold, forged or audited, its code dormant, kept
for a later rotation. Duos are shelved too until the pool is tested.

**Rules**

- A relic is never a percentage on the player. No +% damage, crit, speed, mana or reduction.
  The exceptions are Cursed relics (a big number with a cost) and the two Neutral utility coils.
- **Triggered relics scale off the hit** that fired them (Flame Wave 75% of the swing, Volleyball
  250% of the shot). **Passive relics and DoTs scale off Power.** Each damage relic is budgeted
  at about +20% of gear DPS.
- **NC / C.** Four relics per tree are **NC** (no condition). One is **C**, offered only once the
  player holds any relic of that tree, so no one is locked out of a tree on pick one.
- **Roll:** pick a tree first (one ticket each, plus half a ticket per relic you already hold in
  that tree, capped at two; Neutral stays at one), then a rarity (Rare 77 / Epic 18 / Legendary
  5), then uniformly from that bucket. Cursed come only from the Cursed Shrine. The offers, the
  Shop and the vending machines use one eligibility check (`IsRelicRollEligible`). A vending
  machine hand always holds at least one plain Neutral card: if none rolled, one random slot
  (never a starter-guaranteed one) swaps its card for a Neutral pick, and Cursed does not count.
- Statuses open from weapon enchantments (20% per hit from the weapon that carries one) and from
  each tree's own relics. The 2026-10-31 "chance to apply" openers (Ye Olde Fire Breath Potion,
  Static Shock Sheep, Zombie Axe) are shelved; each tree's Rare enabler now does something on a
  rhythm or a trigger and applies the status for certain. Relic bursts (pumpkins, Shatter,
  strikes, the Volleyball) ride the universal lane: Power-scaled, no weapon or arcane lines, no
  enchantment, no crit; Shock and Abyss still multiply them.
- **Lanes.** Blaze's enabler is melee, Frost's is ranged, Storm's and Venom's are spells, Earth's
  is any weapon, so every weapon style has a home tree and a mage has two.
- **Gear stats on relics:** a relic may condition or multiply a stat ("every 5th hit is a crit",
  "double against Chilled"), never add flat points to it. Flat numbers belong on gear.
- Card text is the source of truth for the number.

**Blaze** (Burn)

| Relic | Rarity | C? | Effect |
|---|---|---|---|
| Flaming Bo Staff | Rare | NC | Every 6th / 5th / 4th Melee hit (Daggers / Sword / Greatsword) is a guaranteed Critical Strike and Burns. |
| Dragon's Flame Sword | Rare | NC | Every 3rd Melee swing fires a Flame Wave that deals 75% of the swing's damage and Burns. |
| Trick Or Trap | Epic | NC | Takedowns drop 1-3 Explosive Pumpkins that deal damage and Burn. |
| Berserker's Claymore | Epic | NC | Your Critical Strikes on Burning enemies erupt in flames, dealing 100% of the hit to nearby enemies (nearest 3, 7 studs). |
| Flame Ronin Katana | Legendary | C | Your Burns become Black Flame, doubling their damage. Critical Hits detonate the Black Flame, dealing the remaining Burn damage at once. |

**Frost** (Chill)

| Relic | Rarity | C? | Effect |
|---|---|---|---|
| Frozen Blue Ice Crossbow | Rare | NC | Every 3rd Ranged hit fires an Ice Arrow that deals 75% of the hit's damage and Chills. |
| Ice Breaker | Rare | C | Chilling a Chilled enemy Shatters them for damage. |
| Ice Dragon Slayer | Epic | NC | A Frost Dragon follows you, firing icy blasts that deal damage and Chill. |
| Icy Arctic Fowl | Epic | NC | Every 3s, fire ice shards at nearby enemies for damage. Chilled enemies take double damage. |
| Staff of Azure Ever Ice | Legendary | NC | Spells leave a 12-stud Frost Zone that Chills and deals damage to enemies inside. |

**Venom** (Poison)

| Relic | Rarity | C? | Effect |
|---|---|---|---|
| Korblox Evil Eye | Rare | NC | Every 2nd Arcane Spell costs 50% less Mana and Poisons every enemy it hits. |
| Witches Brew | Rare | NC | Every 5th Ranged shot lobs a Brewed Potion that leaves a Poison puddle. |
| Foul Poison Fowl | Epic | NC | Takedowns leave a Poison Cloud for 3s dealing damage each second. |
| Skeletal Scythe | Epic | C | Your Poison becomes Death Venom, which is Poison that can stack up to 3 times. |
| Zombie Bomb | Legendary | NC | Your Poison ticks have a 10% chance to spit Poison Goop at nearby enemies, dealing damage and Poisoning them (one spit per 0.5s). |

**Storm** (Shock)

| Relic | Rarity | C? | Effect |
|---|---|---|---|
| Katana | Rare | NC | After a Perfect Dodge, your next Arcane damage is a guaranteed Critical Strike and Shocks. |
| Sparkle Time Hoverboard | Rare | NC | Your Dodge becomes a lightning dash that deals damage and Shocks enemies you pass through. |
| Deluxe Coil Gun | Epic | C | Your Shocks become Coil Shocked, making enemies take +20% more damage. |
| Lightning Bolt Sword | Epic | NC | Your damage has a chance to chain lightning through nearby enemies, dealing damage and Shocking them. |
| Lightning Horn of the Heavens | Legendary | NC | Your damage has a chance, and Critical Strikes always, to call down a lightning strike that Shocks and deals damage to nearby enemies. |

**Earth** (Fracture, the sustain tree since 2026-11-01)

Earth's status Fractures the enemy and the kill drops an Orb; the cards apply Fracture and spend
the Orbs. Healing never scales with damage dealt: every heal is an Orb or a rate-capped number, so
a damage build cannot turn Earth into immortality. Baseline orbs stepped back the same day (grunts
5% Health / 3% Mana, pots 15% / 10%) so Earth is the tree that turns kills into orbs. Teddy Trap
turns Health Orbs off, so Earth plus Teddy is a dead pair by design.

| Relic | Rarity | C? | Effect |
|---|---|---|---|
| War Rocks | Rare | NC | Weapon hits have a 12 / 20 / 30% chance (Daggers / Sword / Greatsword; 20% ranged) to hurl a Boulder that deals damage and Fractures enemies near it. Boulders deal +50% to Fractured enemies. |
| Earth Protection Orb | Rare | NC | Orbs when your bars are full, float around you (up to 5). They get used when your bars drop below 90%. (One a second, Health first. The orb floats into its slot with no pickup burst; the ring uses the drop's own model.) |
| Bundle of TNT | Epic | C | Collecting an Orb grants a 10% Shield for 5s. When it ends it explodes, dealing damage and Fracturing nearby enemies. |
| Earth Summoning Horn | Epic | NC | Collecting an Orb sends out a shockwave that deals damage, and players within 15 studs gain the Orb's restore too. |
| Golem's Hammer | Legendary | NC | Orbs restore double. In combat the earth quakes around you every 3s, dealing damage and Fracturing enemies. Fractured enemies take double damage from the quake. |

**Neutral** (all NC)

| Relic | Rarity | Effect |
|---|---|---|
| Gravity Coil | Rare | Gain +1 Dodge stack. |
| Newtrat's Tuskinator | Rare | Gain +15 Ammo Capacity, and reload 35% faster. |
| Pot Of Gold | Rare | Gain +50% Gold, and auto-collect it. |
| Fuse Bomb | Rare | On Takedown, drop a Fuse Bomb dealing damage. |
| Speed Coil | Rare | Gain +8 Movement Speed. |
| Experimental Jetpack | Rare | Perfect Dodges grant an invulnerable Jetpack for 2s. |
| Summer Fireworks | Rare | Every 3s, launch 3 Fireworks that deal damage. |
| Super Stomp Boots | Rare | Your Dodge ends with a Ground Stomp that deals damage. |
| Korblox Mage Staff | Epic | Every 3rd Arcane Spell you cast costs no Mana and resets its cooldown. |
| Midnight Sword | Epic | Your Weapon damage restores 2% of your Mana. |
| Volleyball | Epic | Every 3rd Ranged hit spikes a Volleyball that deals damage. |
| Magenta Paintball Gun | Epic | Your Ranged damage has a chance to Paint. Painted enemies take +20% Arcane Damage. |
| Portable Justice | Epic | Your damage has a chance to Jail enemies for 3s. |
| Ban Hammer | Legendary | Enemies below 20% health are executed by a falling Ban Hammer that deals damage. |

**Cursed** (Cursed Shrine only)

| Relic | Effect |
|---|---|
| Double-Bladed Scythe | Deal +100% Weapon Damage, but your Arcane deals no damage. |
| Dragon Lantern | Gain +200% Gold, but lose 10% of it when you take damage. |
| Forbidden Box | Deal +100% Arcane Damage, but your Weapon deals 50% less. |
| Slateskin Potion | Gain +50% Damage Reduction, but lose 1 Dodge stack. |
| Sword of Eternal Abyss | Deal +50% damage, but you can't apply Statuses. |
| Teddy Trap | Gain 5% Lifesteal, but Health Orbs don't heal you and you take double damage. |

**Shelved (`retired = true`, models and code kept):** every aura opener and "while <aura>" relic,
every flat +% relic, the five Duos, Pinata, and the Neutral Legendaries Astral Cloak, Holiday Ham,
Mystical Staff of Cyan, Glorious Sword, Neon Rainbow Phoenix, and the two lane converters Orinthian
Blaster 3777 and Sword of the Epicredness (redundant without auras) and Regeneration Coil (its job
is the Orb Potency line). Korblox Mage Staff and Newtrat's Tuskinator returned as Neutral cards and
Midnight Sword is new, all 2026-10-31. On 2026-11-01 the three "chance to apply" openers (Ye Olde
Fire Breath Potion, Static Shock Sheep, Zombie Axe) and the Shield Earth cards (Robloxian Battle
Shield, Golden Steampunk Gloves, Spartan Sword and Shield) joined the shelf, and Flaming Bo Staff,
Katana, Korblox Evil Eye, War Rocks, Earth Protection Orb and Earth Summoning Horn came back with
new cards.

## Roguelite mode (future)

The 2026-10-31 relic cut shelved 57 relics to make the gear-first game. They are not deleted: every
one keeps its data row with `retired = true`, its gimmick code where it had one, and its model in
Studio, and the aura system that half of them keyed off is dormant rather than removed. A separate
**Roguelite** mode could bring them back as-is: longer runs, no gear chase, a big relic pool with
auras, duos and the percentage relics, picked from the same vending machines. The card text below is
what each said when it was shelved, so the design is recoverable without digging through history.

| Tree | Rarity | Relic | Card at the time |
|---|---|---|---|
| Blaze | Rare | Faux Firebrand | While Enflamed, gain +25% Weapon Damage. |
| Blaze | Rare | Fire Breathing Dragon Friend | Deal +20% Weapon Damage to Burning enemies. |
| Blaze | Rare | Ye Olde Fire Breath Potion | Your damage has a chance to apply Burn. (shelved 2026-11-01) |
| Blaze | Rare | Flaming Mace | While Enflamed, Burns last 50% longer and deal 25% more damage. |
| Blaze | Rare | Linked Sword | Gain +20% Weapon Damage. Weapon hits on Burning enemies extend the Burn by 1s (up to 8s). |
| Blaze | Rare | Red Hyperlaser Gun | Ranged Weapon Damage has +25% chance to Burn, and deals +20% damage to Burning enemies. |
| Blaze | Epic | Phoenix | Your Dodge leaves a 4s fire trail that Burns and deals damage per second. |
| Blaze | Epic | Red Laser Scythe | Gain +30% Melee Weapon Damage. While Enflamed, swing 25% faster. |
| Blaze | Duo | HEX Spitter | While Enflamed and Stormcharged, Critical Hits burst in a plasma nova dealing 60% of the hit to nearby enemies, Burning and Shocking them. |
| Frost | Rare | Frostbrand | While Frostburst, gain +25% Arcane Damage. |
| Frost | Rare | Frozen Flail | Deal +20% Arcane Damage to Chilled enemies. |
| Frost | Rare | Hyperlaser Gun | Ranged Weapon Damage has +20% chance to Chill. While Frostburst, gain +30% Ranged Weapon Damage. |
| Frost | Rare | Ice Cream | While Frostburst, Arcane Spells Chill every enemy hit. |
| Frost | Rare | Korblox Spell Book | Arcane Damage has a 20% chance to grant Frostburst. |
| Frost | Rare | Wizard Orb | Gain +25% Arcane Damage. While Frostburst, Arcane costs 20% less Mana. |
| Frost | Epic | Blue Laser Scythe | While Frostburst, your Melee Weapon Damage becomes Arcane Damage and gains +30%. |
| Frost | Duo | Blizzard Wand | Arcane Spells call a 4s hailstorm where they land. Its shards deal Arcane Damage, can Critically Hit, and Chill. |
| Frost | Duo | Korblox Ice Claws | Your Barriers become an ice shell. When your last one ends, it shatters outward for Arcane Damage and Chills nearby enemies (once every 3s). |
| Venom | Rare | Zombie Axe | Your damage has a chance to apply Poison. (shelved 2026-11-01) |
| Venom | Rare | Murder Knife | Deal +25% damage to nearby enemies. Your hits on nearby enemies have +15% chance to Poison. |
| Venom | Rare | Noxious Chocolate | Your Poison lasts 3s longer, and Poisoned enemies are slowed 15%. |
| Venom | Rare | Overseer's Short Sword | While Blighted, gain +25% chance to apply your Elemental Statuses. |
| Venom | Rare | Poison Picnic | While Blighted, applying any Status also applies Poison. |
| Venom | Rare | Poisonous Butterfly | Deal +25% damage to Poisoned enemies. |
| Venom | Epic | Mechatronic Spider | Each Status you apply has a 40% chance to also apply another random Status. |
| Venom | Epic | Overseer's Battleaxe | You deal +15% more damage to enemies for each Status on them. |
| Venom | Duo | Fire Breathing Friend | Enemies both Burning and Poisoned are Melted, taking +40% damage from all sources. |
| Storm | Rare | Lightning Orb | All damage has a +10% chance to grant Stormcharged (+20% on Critical Hits). |
| Storm | Rare | Lightning Wand | While Stormcharged, gain +40% Critical Damage. |
| Storm | Rare | Ninja Whip | While Stormcharged, Critical Hits apply Shock. |
| Storm | Rare | Shuriken of the Crescent Moon | Gain +10% Critical Hit Chance. Critical Hits on Shocked enemies restore 3% Maximum Mana. |
| Storm | Rare | Silver Ninja Star | Gain +15% Critical Hit Chance. While Stormcharged, gain +30% Critical Damage. |
| Storm | Rare | Throwing Bolts | Gain +10% Critical Hit Chance against Shocked enemies. |
| Storm | Rare | Static Shock Sheep | Your damage has a chance to apply Shock. (shelved 2026-11-01) |
| Storm | Epic | Rubber Chicken Launcher | Ranged Critical Hits stick a static charge on the enemy. After 1.5s it detonates for 100% of the hit and Shocks nearby enemies. |
| Earth | Rare | Cheezburger | Taking damage grants a 5% Barrier for 3s (once every 5s). |
| Earth | Rare | Golden Steampunk Gloves | Your Weapon damage has a chance to grant you a +5% Shield. (shelved 2026-11-01) |
| Earth | Rare | Robloxian Battle Shield | Casting an Arcane Spell gives you a +10% Shield. (shelved 2026-11-01) |
| Earth | Rare | Leland the Lolturtle | Your Stonebound gives its users +20% Damage Reduction. |
| Earth | Rare | Riot Shield | Melee Weapon Damage has a 20% chance to grant Stonebound. |
| Earth | Rare | Rolling Pin | Melee hits while Stonebound deal +25% damage. |
| Earth | Rare | Space Sandwich | While Stonebound, taking damage grants a +15% Barrier for 4s, once every 8s. |
| Earth | Rare | Stonefist Gauntlet | While Stonebound, your Damage Reduction is added to your damage too (+30%, more with Leland). |
| Earth | Epic | Spartan Sword and Shield | You gain 2 shields that circle around you, dealing damage and granting you +5% Shields. (shelved 2026-11-01) |
| Earth | Duo | Medusa Head | While Stonebound, your Poison Petrifies enemies for 4s: they are slowed 75% and take +25% damage from all sources. |
| Neutral | Rare | Fluffy Unicorn | Deal +30% damage to Minibosses and Bosses. |
| Neutral | Rare | Regeneration Coil | Health Orbs heal you 50% more, and heal nearby allies too. |
| Neutral | Epic | Ghost Dragon | Every 1s, deal damage to nearby enemies. |
| Neutral | Epic | Orinthian Blaster 3777 | Ranged Weapon Damage becomes Arcane Damage. |
| Neutral | Epic | Sword of the Epicredness | Spells deal Weapon Damage instead. |
| Neutral | Legendary | Astral Cloak Of Transportation | Gain +1 Dodge stack and Dodge 35% further. Dodging heals 50% of damage taken in the last 2s. |
| Neutral | Legendary | Glorious Sword | Deal 40% more Melee Weapon Damage and gain 8 studs of Melee Range. |
| Neutral | Legendary | Holiday Ham | Gain +50% max health and +50% healing from all sources, and grow bigger. |
| Neutral | Legendary | Mystical Staff of Cyan | Deal 40% more Arcane Damage. Spells create a large 10s Sigil giving anyone inside +25% Arcane Damage. |
| Neutral | Legendary | Neon Rainbow Phoenix | Gain +25% chance to apply any Status on all damage. |
| Neutral | Cursed | Flaming Orb of Divine Pain | Double the base effects of your Auras, but take +50% more damage while an Aura is active. |
| Neutral | Cursed | Pinata | Vending Machines offer only 2 Relic choices, but all are Epic or higher. |

## Auras

**Auras are cosmetics.** No relic grants or reads one any more (2026-10-31); `AuraService` and its
five rigs (Enflamed, Frostburst, Blighted, Stormcharged, Stonebound) stay in the codebase, dormant,
until the Wardrobe wears them. They will play on the character in the Hub and the dungeon and
change no number. The base aura of each
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

### Weapon enchantments

One per weapon: a stat plus an opener, hidden from the weapon's Damage and from Power (the card
says 50, the hit says 55). The **stat is always on** while the weapon is equipped in either hand
slot, whichever weapon is drawn, and the two slots **add**: two Enflamed weapons are +20% Weapon
Damage, no exception text anywhere. The **opener** fires only from the weapon that lands the hit:
a 20% chance per hit (times the gun's proc coefficient, plus the Status Chance line). Spells have
no enchantment opener; their statuses come from relics. The stored ids keep the 2026-10-31 names
(Frostburst, Blight); the UI prints the new ones.

| Enchantment | Stat per weapon | Two of the same | Opener |
|---|---|---|---|
| Enflamed | +10% Weapon Damage | +20% | 20% Burn |
| Frostbite (id Frostburst) | +15% Arcane Damage | +30% | 20% Chill |
| Stormcharged | +10 Critical Chance | +20 | 20% Shock |
| Corrosion (id Blight) | +20% Status Damage (every Burn, Poison, Black Flame and Death Venom tick) | +40% | 20% Poison |
| Stonebound | +20% Orb Potency (shares the line's 100% cap) | +40% | 20% Fracture |

Why these sizes: two Frostbite is the strongest pure-mage pair at +30%, but Frostbite plus
Stormcharged lands close behind through crit synergies in three trees, so it is a preference and
not a lock. If a single pair becomes the rule, the fix is one number, not a new stacking rule.

- **Roll on drop** by rarity: Common 0%, Uncommon 5%, Rare 10%, Epic 25%, Legendary 60%; which
  one is uniform over the live pool: Enflamed, Frostbite, Stormcharged, Corrosion. Stonebound is
  built and works on a weapon that has one; it joins the pool with the Earth tree's look.
- **Imbue** at the Blacksmith adds or rerolls one for Gold: half a run of the weapon's level, flat
  (about 100 / 200 / 385 / 740 at each tier's entry level). Never fails, never destroys, a reroll
  never repeats. Equipped weapons allowed.
- **Look:** weapon particles per enchantment are Studio work (the code-cloned status rigs were
  taken off on 2026-11-01 to make room for authored ones). Hovering the Enchantment row in the
  bag shows a tooltip with the enchantment's sentence, for example "Your weapon hits deal +10%
  damage and have a 20% chance to Burn."
- **Test commands:** `/enchant <name | roll | clear>` and `/bonusstat <StatKey percent | roll |
  clear>` on the primary weapon, in the hub and the dungeon.
- Looter is gone. Saved Looter weapons became unenchanted (profile v4). The Gold Find and Dodge
  Recovery lines left on 2026-11-01 (Luck took the slot); saved lines with those keys are
  ignored and reroll away.

### Gear lines (bonus stats)

Secondary stats rolled into a weapon or armor piece. Like enchantments they never touch the shown
Damage / Health or Power; they change the hit, the heal or the cooldown. Spells roll none.

- **Count by rarity:** Common 0, Uncommon 1, Rare 1, Epic 2, Legendary 3. A full Legendary set is
  15 lines; mid-game is 5 to 8.
- **Roll:** uniform inside the range, independent of Quality. Never two of the same stat on one
  item; the same stat on different items sums. Reroll at the Blacksmith for Gold is still to come.
- **Weapons roll offence, armor rolls defence and casting.** Weapon Damage lines belong to the
  weapon that landed the hit, like Enflamed; every other line is yours while the piece is worn.

| Weapon line | Range | Armor line | Range |
|---|---|---|---|
| Weapon Damage | +4 to 10% | Health | +4 to 10% |
| Arcane Damage | +5 to 12% | Damage Reduction | +2 to 5% |
| Critical Chance | +5 to 12 pts | Movement Speed | +2 to 5% |
| Critical Damage | +10 to 25% | Cooldown Reduction | +3 to 8% (cap 40%) |
| Status Chance | +3 to 8 pts | Mana Cost Reduction | +3 to 8% (cap 40%) |
| | | Mana Regen | +5 to 15% |
| | | Orb Potency | +10 to 25% (cap 100%) |
| | | Luck | +5 to 15% (cap 60%): every rarity above Common is that much more likely on gear drops |

Every reduction together (Slateskin, Stonebound, lines, set bonus, shrine) caps at 75% of a hit.
A perfect 15-line Legendary set with Enflamed is about +85% weapon output and +50% effective
health over no lines: a little under one tier, so lines decide how comfortable a tier feels while
Power still gates it.

- **Post-launch, after the first test:**
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
- Selling gear refunds 50% of its Gold upgrade spend. Sales pay Gold only.
- Run income per tier (Gold 205 / 400 / 770 / 1,485 across chests, grunt drops and gear sales;
  Crystals 50 / 100 / 200 / 400) with treasure chests and pots as a 20% bonus on top.

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

Tier scaling: mob health ×1.2 / 2.4 / 4.8 / 9.6 (×0.8 from 1.5 / 3 / 6 / 12 on 2026-10-31, the
aura stat half having left every build) and damage ×1 / 1.47 / 1.68 / 2.14 by tier. A first-order
re-solve; the survival sim reruns after the first play-test.

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
4. Relic refactor: the 45 above, NC/C gating, tree-first roll, every proc and DoT on Power;
   auras dormant until the Wardrobe wears them. (Done 2026-10-31; Duos shelved.)
5. Mob re-solve against the new damage composition. (First-order ×0.8 done 2026-10-31.)
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
