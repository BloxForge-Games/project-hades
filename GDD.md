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
  three, so a run is 6 / 8 / 10 / 12 waves (32 / 50 / 68 / 86 mobs solo). One event sits on a random door before the boss (the very first door included), and a
  second rolls at 50% on another door, never back to back (for example C E C M E C B).
- **Economy per run** (solo, Runegrove): kill EXP is scaled so a run pays what it always did
  (grunt EXP x 2.72 / 3.48 / 3.84 / 3.03). **A run pays 157 / 325 / 640 / 1274 coins** (150 / 300 /
  600 / 1200 from 2026-11-02 until the 2026-11-04 gear cut): the reward chests 82 / 175 / 340 / 674
  (40% miniboss chest / 60% boss chest), grunt
  drops 50 / 100 / 200 / 400 and the treasure chests 25 / 50 / 100 / 200. Breaking every pot adds
  up to +20% of that on top. **Crystals are 50 / 100 / 150 / 200** from the two chests, and
  breaking every crystal vein adds up to +20% on top. Prices did not move with the raise: the
  Blacksmith, gear chests, quests and treasure chests stay anchored on the old take below
  (125 / 250 / 500 / 1000, coins 52 / 125 / 270 / 589 plus gear sales); **gear drops only from the
  miniboss (1) and the boss chest (1 / 2 / 3 / 4), 2 / 3 / 4 / 5 pieces a run** (2026-11-04: treasure
  chests, the Coffin and corrupted grunts no longer drop gear, and the reward chests' coins rose
  7 / 25 / 40 / 74 to cover the lost sales; 2026-11-14 play-test lever: a treasure chest pays one
  piece 10% of the time per player, about +0.15 to +0.3 pieces a run, which the Gold ladder below
  does not count); expected gear sales are 73 / 125 / 230 / 411 Gold, so a run's
  Gold take is 125 / 250 / 500 / 1000 and Blacksmith prices follow (Gold halved and Crystals
  doubled on 2026-11-01, then the take set to that clean ladder after the first play-test;
  prices are shares of the take, so they move with it).
- **Trading** (2026-11-02, hub only; Shared/Data/TradeData, Lobby TradeService): the Trading
  tab lists the server's players; a request (20 s) opens a trade window for both, the bag on the
  left and both offers on the right. Up to 6 weapons or armour pieces a side (never spells,
  equipped or favourited gear), plus Gold and Arcane Crystals; 5% of all Gold and Crystals sent is lost to a trading fee, taken from what the receiver gets (send 100, receive 95), so passing currency back and forth drains it.
  Level 10+ only. Any offer change clears both Ready marks; both Ready unlocks Confirm after 3 s;
  both Confirmed swaps everything in one server step that re-checks both bags, wallets and bag
  space first, or cancels and moves nothing. Bags, the forge, Valencia and the queue are locked
  mid-trade; a player leaving, cancelling or idling 5 minutes ends it. Both profiles log the trade
  (TradeLog) under one id.
- **Gold sinks:** Blacksmith upgrades (0.9375 of a run for a Common up to 3.75 runs for a Legendary, +25% then +50% on 2026-11-02;
  50% of it back on a sale) and **Valencia's gear chests** (2026-11-02; Shared/Data/GearChestData).
  One chest per dungeon, the Arcane chests' window and roulette with gear in them: one piece of
  that dungeon's gear, rolled like a drop, at the tier the player has cleared there ("Power 300
  Chest (Lvl 10-15)"), for half that tier's run Gold (Easy a flat 100, since half a run sold back for more). The odds are exactly the dungeon's own drops at that tier (Easy 60 / 30 / 10 Common / Uncommon / Rare, Normal 45 / 30 / 20 / 5 with Epic, Hard 30 / 20 / 30 / 20 + a Legendary, Nightmare 15 / 50 / 35 Uncommon / Rare / Epic + a Legendary). The Luck line raises everything above Uncommon. Since 2026-11-02 the Gold chest rolls the dungeon's own drop odds at its tier (above), capped at 3 Gold rolls per player, all back half an hour after the last one is used (offline too); "Refresh!" refills them for 25 Robux. Pity: an Epic every 10 opens per chest. A run still pays about
  2 to 5 pieces plus its Gold, so running stays the way to gear up. The Imbue, gear-line rerolls and
  Artix's hourly shelves all left the same day.
- **The event pool opens by tier:** Easy has the Healing Fountain, the Forge and the **Greater Shrine**
  (an event room since 2026-11-13: one free Greater Blessing per player) and the **Mimic Vault**
  (2026-11-13: three shared chests, any player opens any; two burst 5% of the run's coins and of its
  chest crystals for every living player, one is a **mimic**, a punishment that pays nothing: a
  corrupted pack of 4 + 1 per player, and the door stays shut until it is dead. The vault seals,
  unopened chests going dead, once anyone steps past its exit) and the **Wheel of Fortune**
  (2026-11-13; WheelOfFortuneData: one free spin per player, eight slices, about 23% of the weight bad:
  Gold 5% of run coins, Crystals 10%, Heal 50%, a relic hand, a JACKPOT Epic+ hand with 15%
  coins, and the bad -25% HP, Lose Relic (one random non-Cursed relic) and Ambush (a corrupted
  pack of 3 + 1 per player, door held)) and the **Memory Shrine** (2026-11-13; MemoryShrineService,
  Slay the Spire's Match and Keep: each player plays their own board once, 6 pairs (4 relics, Gold
  for 8% of the run's coins, and one Cursed relic), every face shown for 2.5 s, then 3 misses
  allowed; a found pair is kept at once, the Cursed pair included); Normal and Hard
  add the Coffin, the Cursed Shrine and the **Merchant Shop**; Nightmare adds the Sword in the Stone.
  The Merchant (2026-11-13) sells 5 relics for **Max HP or Max Mana for the rest of the run**
  (each stand rolls one, HP 70% / Mana 30%): Rare 15%, Epic 20%, Legendary 25%, never past 75%
  of either paid in total. He is **the Soul Broker**, a necromancer, and buys nothing: relics are
  never sold, only dropped (anyone may pick a drop up; each player takes at most 3 Blessings, relics
  someone else dropped, per run).
- The exit portal rises after the boss. Chest rewards all land on that one floor.
- **Relic picks** come from the vending machines and the Cursed Shrine; the pick count and a
  Legendary pity are open tuning after the first test.
- **No relic cap (2026-11-12):** a player may hold any number of relics; the machines (one per
  cleared combat room plus the starter) bound the count. A relic dropped from the tray can be picked
  up by anyone, but each player takes at most **3 Blessings** (relics someone else dropped) per run.
- **Death, wipe or leaving before the clear ends the run.** Nothing picked up is lost: gear banks
  at pickup and the run's Gold and Arcane Crystals bank in full. Dying only costs the chests not
  yet opened. Lives: 1 on every tier. Gems no longer drop (no sink without the Merchant); grunts
  drop Gold in their place, which stays until the next combat room like Gems did. The HUD shows
  banked Gold and Crystals plus the run's gains.

## Statuses

Five enemy statuses, one per tree, plus the player's Shield. Weapon enchantments open them (a
15 / 20 / 25% chance per hit by tier, from the weapon that carries the enchantment, +10% per
relic of that status's tree up to 50%) and each tree's relics apply
their own. Same status refreshes duration, different statuses coexist. Burn and Poison stack per
player (two players each keep their own tick on one enemy); within one player nothing stacks
except Death Venom.

| Status | Effect | Notes |
|---|---|---|
| Burn | 25% of Power per second for 5s | DoT. Black Flame (Flame Ronin Katana) doubles it. |
| Chill | 30% slow for 5s | Control. |
| Poison | 15% of Power per second for 5s, target deals 10% less | DoT plus Weaken (10% on 2026-10-31, 15% since 2026-11-01). Death Venom (Skeletal Scythe) stacks to 3. |
| Shock | +10% damage taken for 5s | **The only damage-increasing status.** Coil Shocked (Coil Gun) is +20%. Vulnerability total capped at +30%. |
| Fractured | The enemy shatters on death: 40% chance to drop a Health or Mana Orb | Earth's status (2026-11-01), shown with the Stonebound aura rig on the enemy. Health or Mana on a coin flip. No tick, no slow. |
| Shield | Shield worth x% of max health | On the player. Blocks damage before health. |

- **DoTs scale off Power, never off the hit that applied them**, so a gun, a sword and a spell set
  the same Burn and a bigger weapon means a bigger Burn. Bosses take the same Burn as grunts.
  The Corrosion enchantment multiplies every tick (+6 / 12 / 18% Status Damage per weapon by tier).
- Every status lasts 5s; a reapply refreshes the timer. Melted (Burning + Poisoned) makes DoTs
  tick twice as fast. Petrified (Medusa, shelved) is a stun on the same 5s.
  Neither increases damage taken.
- **Crit** is 5% base (10% for a day from 2026-11-01, back to 5% on 2026-11-02), 1.75x damage. The Critical Hit Chance gear line
  rolls 3 to 7 points per piece (25 at most from lines) and Stormcharged adds 10 per weapon. Every
  tree has a guaranteed crit somewhere (the Bo Staff's rhythm, the Katana's dodge, the Horn's
  strike on crits), so the Critical Damage line is worth chasing.

## Relics

**No relic slots (2026-11-12).** The tray shows a column of six boxes and opens another column
per six relics; each box wears its element tree's emblem.

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
- **Roll:** pick a tree first (one ticket each, plus a quarter ticket for a tree you already hold
  a relic in, capped at one and a quarter so your tree is never more than 20% of a slot; Neutral
  stays at one), then a rarity (Rare 60 / Epic 30 / Legendary
  10), then uniformly from that bucket. Cursed come only from the Cursed Shrine. The offers, the
  Shop and the vending machines use one eligibility check (`IsRelicRollEligible`). A vending
  machine hand always holds at least one plain Neutral card: if none rolled, one random slot
  (never a starter-guaranteed one) swaps its card for a Neutral pick, and Cursed does not count.
- Statuses open from weapon enchantments (15 / 20 / 25% per hit by tier from the weapon that carries one) and from
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
| Flaming Bo Staff | Rare | NC | Every 5th / 4th / 3rd Melee hit (Daggers / Sword / Greatsword) is a guaranteed Critical Strike and Burns. (Swings that land are counted, once per swing, since 2026-11-04; a whiff never counts.) |
| Dragon's Flame Sword | Rare | NC | Every 4th / 3rd / 2nd Melee swing (Daggers / Sword / Greatsword) fires a Flame Wave that deals 75% of the swing's damage and Burns. |
| Trick Or Trap | Epic | NC | Melee Takedowns drop 1-3 Explosive Pumpkins that deal damage and Burn. |
| Phoenix (Berserker's Claymore until 2026-11-05) | Epic | NC | Your Critical Strikes erupt in flames, dealing 100% of the hit to nearby enemies (nearest 3, 7 studs). |
| Flame Ronin Katana | Legendary | C | Your Burns become Black Flame. Critical Strikes detonate it. (Black Flame is Burn at double damage; the detonation deals the remaining Burn at once.) |

**Frost** (Chill)

| Relic | Rarity | C? | Effect |
|---|---|---|---|
| Frozen Blue Ice Crossbow | Rare | NC | Every 4th Ranged shot fires an Ice Arrow that deals damage and Chills, restoring 5% of your Mana when it hits. (Shots counted, hit or miss, since 2026-11-04: the arrow fires with the shot, straight along its aim like a bullet, and hits the first mob in its path. Power-scaled, 10 per factor, since 2026-11-02.) |
| Ice Breaker | Rare | C | Chilling a Chilled enemy Shatters them for damage. |
| Ice Dragon Slayer | Epic | NC | A Frost Dragon follows you, firing icy blasts every 1.5s and with each Spell. They deal damage, +50% to Chilled enemies, and Chill. |
| Icy Arctic Fowl | Epic | NC | Enemies hit by your Spells are struck by a homing ice shard for damage. Chilled enemies take double damage. |
| Staff of Azure Ever Ice | Legendary | NC | Your Spells leave a Frost Zone that Chills and damages everything inside. (12 studs, 5 s, Chills every 2 s.) |

**Venom** (Poison)

| Relic | Rarity | C? | Effect |
|---|---|---|---|
| Korblox Evil Eye | Rare | NC | Every 3rd Ranged shot deals +50% more damage and Poisons. |
| Witches Brew | Rare | NC | Every 5th Ranged shot lobs a Brewed Potion that leaves a Poison puddle. (Every shot counted, hit or miss, since 2026-11-04: the potion flies with the shot, straight along its aim, and bursts on the first mob or wall it reaches.) |
| Foul Poison Fowl | Epic | NC | Takedowns leave a 3s Poison Cloud that deals damage, twice as big from Poisoned enemies. |
| Skeletal Scythe | Epic | NC | Your Ranged hits have a 30% chance to Poison. Your Poison becomes Death Venom, which stacks up to 3 times. (Venom's ranged opener since 2026-11-05, melee from 2026-11-01; Zombie Bomb is the tree's one C relic.) |
| Zombie Bomb | Legendary | C | Your Poison spits Goop at nearby enemies, Poisoning them too. (10% per Poison tick, one spit per 0.5 s.) |

**Storm** (Shock)

| Relic | Rarity | C? | Effect |
|---|---|---|---|
| Katana | Rare | NC | After a Perfect Dodge, your next Spell is a guaranteed Critical Strike on everything it hits, and Shocks them. (Every target the spell hits within 0.6 s of its first hit.) |
| Sparkle Time Hoverboard | Rare | NC | Your Dodge becomes a lightning dash that deals damage and Shocks enemies you pass through. |
| Deluxe Coil Gun | Epic | C | Your Shocks become Coil Shocked, making enemies take +20% more damage. |
| Lightning Bolt Sword | Epic | NC | Your Melee hits have a chance to chain lightning through nearby enemies, dealing damage and Shocking them. |
| Lightning Horn of the Heavens | Legendary | NC | Your hits may call down Lightning that Shocks nearby enemies. Critical Strikes always do. (20% of hits, 50% of spell hits, one strike per 0.2 s.) |

**Earth** (Fracture, the sustain tree since 2026-11-01)

Earth's status Fractures the enemy and the kill drops an Orb; the cards apply Fracture and spend
the Orbs. Healing never scales with damage dealt: every heal is an Orb or a rate-capped number, so
a damage build cannot turn Earth into immortality. Baseline orbs stepped back the same day (grunts
5% Health / 5% Mana, pots 10% / 10%; each Health Orb heals 10% since 2026-11-02) so Earth is the tree that turns kills into orbs. Teddy Trap
turns Health Orbs off, so Earth plus Teddy is a dead pair by design.

| Relic | Rarity | C? | Effect |
|---|---|---|---|
| Golden Steampunk Gloves | Rare | NC | Every 2nd Melee swing (every weapon, since 2026-11-04; 4th / 3rd / 2nd before) sends out a Shockwave that Fractures enemies for damage. (8 studs around the enemy the swing struck, or just ahead of you on a whiff; Power-scaled; swings counted since 2026-11-01.) |
| Earth Protection Orb | Rare | NC | Orbs you pick up when your Mana and Health are full are preserved (up to 5). They are used when needed. (Stored when the matching bar is at 90% or above, since an orb heals 10%; spent one a second, Health first; stored orbs never expire and survive a respawn; nobody else can take them. The orb floats into its slot with no pickup burst; the ring uses the drop's own model.) |
| Bundle of TNT | Epic | C | Collecting an Orb grants a +7% Shield for 5s. When it ends it explodes, dealing damage and Fracturing nearby enemies. |
| Earth Summoning Horn | Epic | NC | Collecting an Orb grants you a +5% Shield for 5s, and players within 15 studs gain the Orb's restore too. (The damage shockwave left 2026-11-08.) |
| Golem's Hammer | Legendary | NC | Orbs restore +50%. In combat the earth quakes around you, Fracturing enemies. (Every 3 s, 12 studs; Fractured enemies take double from the quake.) |

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
| Volleyball | Epic | Every 3rd Ranged shot spikes a Volleyball for 100% of the shot's damage. (Shots counted, hit or miss, since 2026-11-04: the ball flies with the shot, straight along its aim, and hits the first mob in its path. A share of the gun's damage since 2026-11-02; 2x Power before.) |
| Magenta Paintball Gun | Epic | Your Ranged damage has a chance to Paint. Painted enemies take +20% Arcane Damage. |
| Portable Justice | Epic | Your damage has a chance to Jail enemies for 3s. |
| Ban Hammer | Legendary | Enemies below 20% health are executed by a falling Ban Hammer that deals damage. |

**Cursed** (Cursed Shrine only)

| Relic | Effect |
|---|---|
| Double-Bladed Scythe | Deal +100% Weapon Damage, but your Arcane deals no damage. |
| Dragon Lantern | Gain +200% Coins, but lose Coins collected this run every time you take damage (5% of the run's average coins per hit; banked Gold is never touched since 2026-11-08). While held, the Gold readout shows "total (this run)". |
| Forbidden Box | Deal +100% Arcane Damage, but your Weapon deals 50% less. |
| Slateskin Potion | Gain +35% Damage Reduction, but lose 1 Dodge stack. |
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

### Relic unlocks

A new player has 27 relics: 3 per element tree, 8 Neutral and 4 Cursed. The other 19 unlock by
player level, one per level from 2 to 20 (2026-11-08; tree finds, boss holds, lifetime feats and
Cursed Shrine bargains before), so every relic is offered by level 20. Tree Epics come first (2 to 7),
the Cursed relics are spaced out mildest first (10, 14, 17) and the Legendaries come last (13 to 20).
The list is `RelicUnlockData.ByLevel`; the Codex shows "Unlocks at Lv X" on a locked relic, a toast
announces each one on the level up, and the run summary lists it. Relics earned under the old rules
stay unlocked.

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
| Blaze | Epic | Phoenix Dash (was Phoenix) | Your Dodge leaves a 4s fire trail that Burns and deals damage per second. |
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
| Earth | Rare | War Rocks | Weapon hits have a 12 / 20 / 30% chance to hurl a Boulder that Fractures enemies near it. (shelved 2026-11-01, Earth wanted a melee opener) |
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
| Neutral | Cursed | Pinata | Critical Hits have a 35% chance to burst Coins out of an enemy, but lose 50% of your Critical Strike damage. |

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
- **Armor:** one stat, Health, plus an optional **armor enchantment** per piece (below). Pieces
  belong to named armor sets, which only name the look: there are **no set bonuses** (removed
  2026-11-13).
- **Per-dungeon loot pool:** 6 melee, 6 ranged, 6 armor sets (18 pieces), 2 Legendary uniques.
  - Easy mostly Common; Normal better Rare; Hard makes Rare and Epic common and allows Legendary;
    Nightmare is the same pool with much better high-rarity odds. No Nightmare-exclusive gear.
  - **Runegrove as built (2026-11-14):** 10 weapons (2 swords, 2 daggers, 2 greatswords, 4 bows) and
    9 armor pieces; the starters (Steel Sword, Travelers Bow) do not drop here. **By tier:** Easy
    drops Mithiril Sword, Bluesteel Quickblades, Bluesteel Greatsword, Hunters Bow and Spiked Iron
    Bow; Normal adds Blacksteel Blade, Platinum Reavers, Gutrender Edge, Willowbark Bow and Feral
    Greenwood Bow; Hard and Nightmare drop all ten plus the uniques. Weapons of one type share that
    type's timings and step up in damage (2026-11-14): swords 30 Steel / 34 Mithiril / 38
    Blacksteel, daggers 30 Quickblades / 34 Platinum, greatswords 40 Bluesteel / 44 Gutrender, bows
    35 Travelers / 37 Hunters / 39 Spiked Iron / 41 Willowbark / 43 Feral; the uniques are 55
    Runestorm (110 DPS), 47 Runeshade (100), 72 Runeforge (120). **The guns left the game the same day** (a saved gun
    becomes a Travelers Bow; the bag's tab reads "Bows"). Every weapon a tier drops is equally likely: they share
    the weight the first 4 had (`weaponPoolWeight` 80 against armor's 225), so a drop is a weapon
    26% of the time and any one weapon 5.2% on Easy, 2.6% from Normal up. 3 Legendary uniques (Runeforge Greataxe, Runeshade
    Reavers, Runestorm Claymore) split the Legendary roll evenly (Hard 0.5%, Nightmare 1% of a
    drop). The Stormforge Breaker no longer drops (the Runeforge Greataxe is the same axe).
- **Character stats** (2026-11-19; "No character stats, ever" until then). See "Character stats"
  below.

### Character stats

Built 2026-11-19 for the MMORPG direction: a level-up should give the player a choice, and a
build should have an identity before any gear says so. Untested in play and untuned.
`Shared/Data/StatPointData` holds every number; `StatPointService` is the one writer of
`profile.StatPoints`; the Stats window opens from the hub menu.

| Stat | Does |
|---|---|
| Strength | Melee Weapon Damage |
| Dexterity | Bow (Ranged Weapon) damage |
| Intellect | Arcane Damage |
| Endurance | Max health |

- **Four stats, one job each.** No crit, speed, cooldown, luck or gold stat: those are traits, and
  a stat that repeats a trait makes the trait caps hard to hold. A crit "Luck" stat was considered
  and dropped (it also clashes with the Luck trait's name).
- **Points:** one per player level, 100 at most. Levels go on past the last point (the EXP curve
  has no cap) and give no more points.
- **Respec:** 2 Gold a point handed back, in the hub. Points are spent in the hub only.
- **Numbers (2026-11-19, untuned):** +1% per point and at most 60 points in one stat, so a full
  stat is +60% and the other 40 points go elsewhere (60 Strength + 40 Endurance is +60% melee
  damage and +40% health). +0.5% a point was proposed first and dropped: a point did not show.
  At this size level counts beside gear, not under it.
- **Balance rules to hold when it is built:**
  - The damage stats add into the same bucket as the Weapon Damage and Arcane Damage traits; they
    do not multiply on top of them.
  - Mobs pay for it, gear numbers stay: each tier's mob health rises by the damage points a
    player of the tier's expected level has, and mob damage by the Endurance points, on an
    assumed split of about 60% damage and 40% Endurance. Mob damage may rise by less than the
    full share, so skipping Endurance hurts without one-shotting.
  - Melee, bow and Arcane must pay the same per point for the risk each takes; set by play-test.
  - Triggered relics follow the hit, so they follow the stat. Relics and DoTs that scale off Power
    do not, unless that is added.
- **As built:** the points join PlayerStatsService's gear stat totals as MeleeDamage,
  RangedDamage, ArcaneDamage and Health, after the trait caps, like a race's perk. Each tier's
  mobs are scaled for the middle of its level range (`DifficultyData.StatPointScale`): health
  x1.003 / 1.010 / 1.018 / 1.026 and damage x1.006 / 1.018 / 1.033 / 1.048 on Easy / Normal /
  Hard / Nightmare. The tiers stop at level 20, so 19 of the 100 points are reachable in the
  content that exists; the rest need tiers above Nightmare.
- **Level cap:** the game is designed for level 100; the beta stops at 20 (`ExperienceService`
  `MAX_LEVEL`). EXP past the cap fills the bar and is not banked.
- **Still needed:** a play-test of all four difficulties, a painted menu icon, and the EXP curve
  past level 20.

### Enchantment tiers

Every enchantment, weapon or armor, has three **tiers: I, II, III** (2026-11-13). The UI prints the
tier after the name ("Enflamed II") and the item panel, its hover tooltip, the gear chest card and
the trade card show that tier's real numbers in one short line, numbers first, for example
"+6% weapon damage. 20% chance to Burn." or "-5% damage taken." Whenever an enchantment is
rolled, its tier is rolled too: **I 60%, II 30%, III 10%**. The tier is stored on the item
(`enchantmentTier`); an item from before tiers reads as tier I, so no save was rewritten.

**No particles for now** (2026-11-13): no enchantment, weapon or armor, shows a visual on the
item. The weapon looks authored in Studio stay in GameAssets behind one switch
(WeaponEnchantFXController ENCHANTMENT_PARTICLES_ENABLED) so they can come back.

### Enchantment scrolls

Gear **never drops enchanted** (2026-11-14). An enchantment arrives as a **scroll**: one of the ten
enchantments (five weapon, five armor) at one tier, named like "Enflamed II Scroll". The roll is
uniform over the ten, then the tier at 60 / 30 / 10. Sources, each rolled per player from that
player's own chest: **Boss chest** always 1, **Miniboss chest** 35%, **Coffin chest** 25%,
**treasure chest** 10% (a mimic pays none). In the world a scroll is a neon block in its
enchantment's colour, owned and picked up like a gear drop, and it is kept the moment it is picked
up (profile `EnchantmentScrolls`, a map of counts). The bag's **Enchants** tab shows owned scrolls as tiles, one per stack with its count and "Tier 1 / 2 / 3", in the tier's rarity colour (Rare, Epic, Legendary); selecting one shows its name, tier, effect, what it applies to and how many are owned on the detail pane. Picking one up shows no toast.
**Applying a scroll to gear arrives with the enchanter NPC**; until then scrolls only accumulate.
Gear that already carries an enchantment keeps it.

### Weapon enchantments

One per weapon: a stat plus an opener, hidden from the weapon's Damage and from Power. The **stat
is always on** while the weapon is equipped in either hand slot, whichever weapon is drawn, and
the two slots **add**: two Enflamed III weapons are +18% Weapon Damage. The **opener** fires only
from the weapon that lands the hit and does not stack: the tier's chance per hit, +10% per relic
held from that status's tree (up to 50%), times the gun's proc coefficient, plus the Status Chance
line. Spells have no enchantment opener; their statuses come from relics. The stored ids keep the
2026-10-31 names (Frostburst, Blight); the UI prints the new ones.

| Enchantment | Stat per weapon (I / II / III) | Opener (I / II / III) |
|---|---|---|
| Enflamed | +3 / 6 / 9% Weapon Damage | 15 / 20 / 25% Burn |
| Frostbite (id Frostburst) | +5 / 9 / 13% Arcane Damage | 15 / 20 / 25% Chill |
| Stormcharged | +3 / 6 / 9 Critical Chance | 15 / 20 / 25% Shock |
| Corrosion (id Blight) | +6 / 12 / 18% Status Damage (every Burn, Poison, Black Flame and Death Venom tick) | 15 / 20 / 25% Poison |
| Stonebound | 4 / 7 / 10% Damage Reduction | 15 / 20 / 25% Fracture |

- **Roll on drop (removed 2026-11-14, see Enchantment scrolls):** Rare, Epic and Legendary weapons each had a flat 20% chance (2026-11-05);
  Common and Uncommon never. Which one is uniform over the pool: Enflamed, Frostbite,
  Stormcharged, Corrosion, Stonebound; then the tier.
- An enchantment is what the weapon dropped with: the Blacksmith's Imbue left on 2026-11-02.
- Looter is gone. Saved Looter weapons became unenchanted (profile v4).

### Armor enchantments

Replaced the armor set bonuses (2026-11-13). Each armor piece (helmet, chestplate, greaves) carries
its own. Until 2026-11-14 a piece rolled one when it dropped or came out of a gear chest (Rare and
up, 20%); now they come from scrolls (Enchantment scrolls, above). Armor enchantments have **no status opener**. The
same enchantment on several worn pieces **stacks**: three Protection III pieces are -21% damage
taken. Weapons never roll an armor enchantment and armor never rolls a weapon one.

| Enchantment | Per worn piece (I / II / III) |
|---|---|
| Explorer | +3 / 5 / 7% Coins and EXP |
| Protection | -3 / 5 / 7% damage taken (inside the 75% total reduction cap) |
| Weapon Mastery | +3 / 5 / 7% Weapon Damage |
| Arcane Mastery | +3 / 5 / 7% Arcane (spell) Damage |
| Fortune | relic rarity: +4 / 7 / 10 points Epic and +1 / 2 / 3 points Legendary, taken from Rare |

Fortune applies to every relic rolled for the wearer (vending machines, chest and event offers,
the Merchant's shelf, the Wheel), once, in the central relic roll. Its points are a share of the
odds table, never past what Rare holds, so no weight goes negative; a forced-rarity roll (the
Forge) is unchanged.

- **Test commands:** `/enchant <name | random | clear> [1-3]` on the primary weapon (hub and
  dungeon); `/armorenchant <name | random | clear> [1-3]` on every worn armor piece (dungeon);
  `/bonusstat <StatKey percent | roll | clear>`; `/weapon <name | list>` adds any weapon to the bag (dungeon); `/allgear [player | all] [rarity] [level]` adds one of every weapon and armor piece to a bag (both places); `/allspells [player | all]` adds every castable spell not yet owned (both places); `/scroll <name | random> [1-3]` drops that
  enchantment scroll at your feet (dungeon); `/gear` in the hub hands out an always enchanted
  weapon or armor piece at a rolled tier. A named enchantment without a tier is tier I; `random`
  rolls the tier unless one is given.

### Gear traits (gear lines, bonus stats)

Players see these as **Traits** (2026-11-14); "line" below and in the code is the same thing.
Secondary stats rolled into a weapon or armor piece. Like enchantments they never touch the shown
Damage / Health or Power; they change the hit, the heal or the cooldown. Spells roll none. Relics
never add a percentage to the player, so lines are the only flat stats in the game.

- **One pool (2026-11-02).** Every stat rolls on every piece, weapon or armor. Every line is
  yours while the piece is worn, Weapon Damage included (it belonged to the hitting weapon
  before).
- **Count by rarity:** Common 0, Uncommon 1, Rare 1, Epic 2, Legendary 3. A full Legendary set is
  15 lines over 5 pieces; mid-game is 5 to 8.
- **Levels (2026-11-14):** every trait has three levels with fixed values: I is the range's low
  end, II its midpoint (whole percent), III its high end, shown as "+14% Critical Damage II".
  A roll is I 60% / II 30% / III 10%, the enchantments' odds, independent of Quality. Never two
  of the same stat on one item; the same stat on different items sums, up to its cap. Items
  saved before levels read, show and count as their nearest level (no data rewrite).
- **Reroll:** the Blacksmith rerolls ONE trait at a time into a new random stat and level for
  Gold: 5% of a run's Gold at the item's level, times 1 / 1.25 / 1.5 / 2 for Uncommon / Rare /
  Epic / Legendary (a Level 10 Rare 31, a Level 15 Legendary 100), flat however often. The other
  traits stay; the new stat is never one the item already has. Untested balance lever.
- **Caps are about four top rolls.** Five pieces are worn, so a stat can sit on five items; the
  fifth copy is wasted, so a set that chases one stat on every piece is no better than one that
  spreads. At the caps a pure-offence set is about +80% damage on grunts and +150% on bosses, a
  pure-defence set about +60% effective health: a little under one tier, so lines decide how
  comfortable a tier feels while Power still gates it. (The Blacksmith's line reroll left on
  2026-11-02 and returned as the trait reroll above on 2026-11-14.)

| Line | Range | Cap | Reads |
|---|---|---|---|
| Weapon Damage | +3 to 8% | 30% | every weapon hit |
| Arcane Damage | +3 to 8% | 30% | spells |
| Critical Hit Chance | +3 to 7 pts | 25 pts | on the 10 base |
| Critical Damage | +8 to 20% | 60% | on the 1.75x base |
| Boss Damage | +5 to 12% | 40% | hits on the floor's miniboss or boss |
| Health | +4 to 8% | 30% | max health |
| Damage Reduction | +2 to 5% | 20% | every hit taken |
| Movement Speed | +2 to 5% | 15% | base walkspeed |
| Cooldown Reduction | +3 to 8% | 30% | spell cooldowns |
| Mana Regen | +5 to 15% | 60% | the passive tick |
| Luck | +5 to 15% | 60% | every rarity above Common is that much more likely on gear drops |
| Fortune | +5 to 15% | 60% | run Gold (Coins), never Crystals |

Every reduction together (Slateskin, Stonebound, lines, Protection armor, shrine) caps at 75% of a hit.
Status Chance, Mana Cost Reduction, Orb Potency, Gold Find and Dodge Recovery left the pool
(2026-11-01 and 11-02); saved lines with those keys are ignored.

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
- Run income per tier (coins 150 / 300 / 600 / 1,200 across chests, grunt drops and treasure
  chests, gear sales on top; Crystals 50 / 100 / 150 / 200) with pots and crystal veins each up to
  a 20% bonus on top.

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

## Slow motion

A server-wide time scale for cinematic beats (2026-11-01). Everyone in the server shares it, the
triggering player included. Two beats ship with it: the kill that clears a Combat room (a quarter
speed for 0.8 s, then the vending machines drop as time comes back) and an encounter death (a
quarter speed for 1.5 s on the Boss, 1 s on a Miniboss, through the body's fall; the chest drops
once time is back). `TimeScaleService:Slow(scale, holdSeconds)` fires one from anywhere on the
server; `/slowmo <scale> [seconds]` for testing.

What slows: everything on the game clock (`Shared/GameClock`): the mob sim and legacy mob AI,
attack wind-ups and recoveries, hitbox telegraphs, statuses and shields, cooldowns, projectiles,
the dodge, relic gimmicks, drops and relic FX movers; and on every client, animation tracks,
particle emitters, gravity and the player's walk and jump. Sounds keep their pitch; the mix is
muffled (highs and mids down) for the beat instead, the way films do it. Not slowed: beams and
trails (no time scale in the engine), physics velocities already in flight, TweenService tweens
started before the beat (gameplay tweens use `GameClock.Tween`), the camera, UI, and real-time
windows (the revive timer, offers, gate countdowns).


## Enemies (Runegrove direction)

Stonehorn Boar (melee), Rootfang Wolf (fast melee), Thornshot Shaman (ranged), Runebark Sentinel
(tank), Briarhorn Caribou (support and healer). Readable silhouettes, stone, wood and foliage,
restrained glowing runes.

Runic Executioner, Hard and up (2026-11-02): **Tidal Requiem**, first 2 to 5 s into the fight, then every 25 to 35 s. He leaps to
the arena's centre, untargetable, and the floor splits into 10-stud lanes; Water Dragon strips
sweep the odd lanes, then the even, then the odd (1.4 s first flash, then 1 s apart), 8 base
damage a hit.

Tier scaling (2026-11-02): one health ladder for every mob, ×1 / 3 / 9 / 15 (Easy, Normal, Hard,
Nightmare), on base rows grunt 175, Elite / Support 210, Tank 285, Miniboss 1250, Boss 2500. The
per-archetype swing-count ladder of that morning was replaced after Hard and Nightmare played too
soft; with a tier-matched Common sword at median quality, grunt / elite / tank now take about
5 / 6 / 8 swings on Easy, 9 / 11 / 15 on Normal, 19 / 22 / 30 on Hard and 24 / 28 / 38 on
Nightmare. Damage ×0.75 / 2 / 4 / 6 by tier; base
hits grunts 5, Tank 6, Miniboss Cleave 8 / Ambush 9 / Water Dragon 10 / Shark Barrage 10. All from the first
play-test, 2026-11-01: Hard with a Level 1 sword +4 cleared easily, grunt hits barely registered,
the Miniboss and Boss felt right. Hard grunt now 1800 HP and a ~25 hit; a ~200 HP player dies in
~8 grunt hits. The survival sim reruns next.

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
