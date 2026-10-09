# Project Hades — GDD Gap Analysis & Priority List

Audited 2026-10-09 against the GDD dated the same day. The GDD is the source of
truth; everything below either confirms the code matches it, or flags a
divergence for a decision. Nothing in this document was changed in code.

Audit scope: `bfg-core/Source` (shared/client/server) and
`Places/{Dungeons,Lobby}`. **Environment art, models and animations could not be
audited** — they live in Studio, not in the repo — so every art-side estimate
here is explicitly marked as unverified.

---

## 1. Completion estimate

Three different numbers, because one number hides more than it tells.

| Axis | Estimate | Confidence |
|---|---|---|
| **Systems / code** | **~60%** | High — read directly from source |
| **Content volume** (items, enemies, Arcane, across 5 dungeons) | **~20%** | High — countable |
| **Environment art & assets** | **unknown** | None — not in repo |
| **Overall vs shipped GDD** | **~40–45%** | Medium |

Weighting behind the overall figure. Argue with the weights, not the per-row
completion — those are measured.

| Area | Weight | Done | Contribution |
|---|---|---|---|
| Core combat (melee, ranged, magic, dodge, status, auras, crits, damage) | 20% | 90% | 18.0 |
| Relic roguelite system | 12% | 90% | 10.8 |
| Procedural dungeon generation & encounters | 12% | 85% | 10.2 |
| Gear systems (rarity/level/quality/upgrade math, drops, inventory) | 8% | 70% | 5.6 |
| Progression ladder (Keystone, Ascension, difficulty scaling) | 8% | 45% | 3.6 |
| Content volume across 5 dungeons | 15% | 15% | 2.3 |
| Arcane system | 8% | 12% | 1.0 |
| Hub + POIs + economy UX | 10% | 8% | 0.8 |
| Dungeon Mastery | 4% | 5% | 0.2 |
| Keystone Trial | 3% | 0% | 0.0 |
| **Total** | **100%** | | **≈52** |

The headline 40–45% is deliberately below that 52: the table credits *systems*
at their code weight, and the single largest remaining cost in the GDD — five
dungeons of painterly environment art plus a built Hub — is the one axis the
repo cannot evidence. If the environments are further along than the code
suggests, the real number is closer to 52.

**The shape of the project:** combat and the roguelite run loop are genuinely
deep and close to done. Everything that happens *between* runs — the Hub, the
Blacksmith, the Arcane collection, Mastery — is scaffolding or absent. The game
can be played; it cannot yet be progressed through.

---

## 2. Discrepancies and the decisions made

Ordered by how much rework the answer implies. Decisions recorded 2026-10-09;
**none of them has been implemented yet** — they are queued behind the
priority list in section 4.

| # | Decision |
|---|---|
| D1 | **Rename the whole `Zombie*` family** to the GDD enemy model, not display-only. Keep **The Undead King** as the dungeon-1 boss for now. The dungeon-2 and dungeon-3 enemy sets are pure legacy — **prune them**. |
| D2 | **Keep the firearms.** They are in-fiction as BOTW-style ancient technology. The 30-ranged-weapon plan proceeds on that basis. |
| D3 | **No `Mythic`** for now; may return later. Remove it from `ItemRarity` and `RarityMultipliers` so Legendary is the ceiling the GDD states. |
| D4 | **Add the upgrade caps** exactly as the GDD lists them (+4 / +6 / +8 / +10 / +15). The +5%-per-level curve was not retuned — revisit when the caps land. |
| D5 | **Still open.** Stormcrest *Mountains* (code) vs Stormcrest *Temple* (GDD) was not decided. |
| D6 | GDD is corrected to **Emberforge Mines** and **Frostveil Castle**. The code was already right. |
| D7 | **Rename `Magic*` → `Arcane*`.** The existing ability runtime *is* the Arcane system; the collection layer (chests, scrolls, ranks, dust, Trainer, 2 slots) is built on top of it. |
| D8 | Not yet decided — shared bonus pool vs bespoke per-set bonuses. |
| D9 | Not yet decided — the 3 orphaned `RelicNames`. |

### Detail

### D1 — Enemy roster is entirely legacy, not GDD
`ZombieNames` holds `Walker`, `PotHead`, `Robombie`, `Wizard`, `ShadowWalker`,
`WaterPotHead`, and bosses `The Undead King`, `The Treacherous Kraken`,
`The Draconic Shadow Lord`. **Zero** of the GDD's Runegrove roster exists —
no Stonehorn Boar, Rootfang Wolf, Thornshot Shaman, Runebark Sentinel or
Briarhorn Caribou.

The enemy *systems* (`ZombieService`, `ZombieSpawnService`, `EnemyScalingService`,
`EnemyTypes` = Normal/Elite/Miniboss/Boss/Event) are solid and reusable. This is
a content-and-naming gap, not an architecture gap.

**Decision:** rename the enum family off `Zombie*` as part of the re-skin, or
keep the internal names and only change display strings? A rename touches many
files; display-only is cheap but leaves `ZombieService` spawning caribou.

### D2 — Weapon identity is a shooter, not arcane fantasy
`WeaponNames` includes `Light Machine Gun`, `Submachine Gun`, `Assault Rifle`,
and `DataTemplate` seeds new players with the LMG, SMG and AR. The GDD's ranged
archetypes are fixed handling profiles in a medieval arcane world (bows,
crossbows, staves implied). Comments in `GearDrop.lua` still reference
"two Common AKs".

**Decision:** are firearms intentionally in-fiction (BOTW-style ancient
technology could justify arcane launchers), or is this legacy to be replaced?
This changes the 30-ranged-weapon content plan substantially.

### D3 — `Mythic` outranks `Legendary`
GDD: Legendary is the top tier and unique-only. Code: `ItemRarity` adds
`Mythic`, `Shiny` and `Cursed`, and `RarityMultipliers` puts
**Legendary at 1.8× but Mythic at 2.0×** — so Mythic is strictly stronger than
the GDD's stated ceiling.

`Cursed` is legitimately in use by the relic system (a relic rarity, not a gear
rarity). `Shiny` appears as a per-item boolean. `Mythic` is the real conflict.

**Decision:** drop `Mythic` from gear, or amend the GDD to include it?

### D4 — No upgrade caps by rarity
GDD: Common +4 / Uncommon +6 / Rare +8 / Epic +10 / Legendary +15. The codebase
has **no cap anywhere** — no `maxUpgrade`, `UPGRADE_CAP` or equivalent.
`computeMainStat` applies `+5%` per upgrade with no ceiling, so nothing stops a
Common from reaching +50.

Not a conflict so much as an unimplemented rule, but it belongs here because the
GDD's numbers imply a specific power curve that `+5%` flat may not produce — a
Legendary +15 is only +75% post-quality.

**Decision:** confirm +5%/level is still right alongside the caps, or retune.

### D5 — `Stormcrest Mountains` vs `Stormcrest Temple`
`DungeonData` says `Stormcrest Mountains`; the GDD says **Stormcrest Temple**.
One-line fix, needs your call on which name wins.

### D6 — The GDD contradicts itself on dungeon names
The dungeon list says **Emberforge Mines** and **Frostveil Castle**, but the
Ascension and Arcane sections say **Emberforge Keep** and **Glacierfall
Citadel**. The code uses `Emberforge` / `Frostveil`, matching the list.
Flagging so the GDD can be corrected — the code is already on the right side.

### D7 — Arcane vs the existing Magic system
The GDD's Arcane spells are anime-inspired techniques, and `MagicNames` already
holds `Susanoo Armor`, `Hollow Purple`, `Domain Expansion`, `Divergent Fist`,
`Ghost Dragon` — exactly that flavour, 12 of them, with `MagicData` behind them
and a working `MagicService`.

So Arcane is **not** greenfield: the ability runtime exists. What is missing is
everything *around* it — per-dungeon pools, fixed rarity, chests, scrolls, ranks,
dust, the Trainer, and the 2-slot loadout. `Arcane = {}` exists in the profile
and `ArcaneDust` is already a currency.

**Decision:** is `Magic*` the Arcane system under an old name (rename and
extend), or does Arcane become a new layer alongside it? This is the single
highest-leverage naming decision left.

### D8 — Armor set bonuses are generic, not per-set
`ArmorSetBonuses` has three bonuses — `Explorer` (+10% coins/exp),
`Protection` (+10% mitigation), `Weapon Mastery` (+10% weapon damage) — and
`ArmorPieceData` holds 9 pieces (3 sets). The GDD wants 6 sets per dungeon
(30 sets, 90 pieces), each with identity-defining bonuses that "influence
playstyle".

**Decision:** do the three existing bonuses become a shared pool that many sets
draw from (cheap, scales to 30 sets fast), or does every set get a bespoke
bonus (expensive, far better buildcraft)?

### D9 — Relic count
90 entries in `RelicData`, 93 in `RelicNames` (3 names without data). GDD says
"around 95". Close enough to be a non-issue, but the 3 orphaned names are worth
cleaning.

---

## 3. Confirmed matches

Worth recording so these are not re-litigated.

- **Quality** rolls `0.50`–`1.00` in `GearDrop.lua` — exactly the GDD's 50–100%.
- **Main-stat formula** composes Item Level × base × Quality × upgrades × rarity
  in one shared `computeMainStat`, used by display *and* the damage path, so the
  inventory number equals the applied number.
- **Item Level by difficulty** — `DifficultyData` tiers carry `levelRange`.
- **Rarity odds by difficulty** — per-tier `rarityWeights`, Common-heavy on Easy
  through Epic-heavy later, as specified.
- **Difficulty ladder** — `Easy/Normal/Hard/Nightmare/Ascension` with
  `MAX_ASCENSION = 10`, a single comparable `Rank()` (Ascension N = 4 + N), and
  `KeystoneRank`.
- **Keystones** — `dungeonProgress.recordClear` grants the Keystone at or above
  `KeystoneRank` and returns whether it was newly earned.
- **One rung at a time** — `getHighestUnlockedRank` is clamped to
  `cleared + 1`, matching "clear the current Ascension to unlock the next".
- **15 relic slots** — `RelicCapData.MaxSlots = 15`, with 10 open by default and
  a shop unlock path, server-enforced.
- **Universal upgrade currency** — `CurrencyTypes` has `Gold`, `ForgeCrystal`,
  `ArcaneDust`; all three live on the profile, not in inventory, exactly as the
  GDD requires.
- **Five dungeons** — `DungeonIds` and `RealmData[1]` list all five with
  distinct `placeId`s.
- **Armor has no substats** — confirmed absent by design, matching the GDD.
- **Fate Cards** — correctly absent.
- **Melee archetypes** — `MeleeWeaponData` has Sword / Greatsword / Daggers
  bases with per-swing timing, range and dash profiles, which is the GDD's
  "fixed, never rolled" handling model in substance (see P7 for what's missing).

---

## 4. Priority list

**Approved 2026-10-09. Documented only — work has not started.**

Priorities assume the goal is a shippable Realm 1, and are ordered by
*unblocking* value — what else cannot be built or tested until it exists.
The D1 / D3 / D7 renames are prerequisites to P2 and should land before any
content is mass-produced under the old names.

### P0 — Blocks progression entirely

**P0.1 — Build the Hub.** `Places/Lobby` has three services
(`DebugService`, `LobbyChatCommandsService`, `LobbyLandingService`) and one
controller. None of the seven GDD POIs exist. Without the Hub there is no
between-run loop at all: no selling, no upgrading, no Arcane, no queueing by
dungeon/difficulty. Everything in P1 and P2 lands *in* the Hub, so this is the
first dependency.
Minimum viable: Keystone Portal (queue), Blacksmith, Merchant, Arcane Trainer.
Defer Guildhall, Travelling Salesman, Realm Gate.

**P0.2 — Blacksmith upgrade flow.** `ForgeCrystal` is a currency with a profile
field and a `Forge` dialogue entry, and `computeMainStat` already consumes
`upgrades` — but nothing spends the currency or increments the field. This is
the shortest path from "loot drops" to "loot matters", and it needs D4's caps
decided first.

**P0.3 — Upgrade caps by rarity (D4).** Small, but it gates P0.2 and defines
the gear power curve.

### P1 — The endgame loop the GDD is built around

**P1.1 — Ascension modifiers.** Ranks, scaling and `MAX_ASCENSION = 10` exist;
the *modifiers* (elite frequency, enemy affixes, reduced healing, hazards, boss
mechanics, stacked modifiers) do not. The GDD is explicit that pure HP/damage
scaling must not be the primary difficulty source — today it is the only source.
This is the main replayability payload and the thing that makes 10 Ascensions
per dungeon worth clearing.

**P1.2 — Arcane system.** Resolve D7 first, then build chests, the Scroll
reveal, rank-up from duplicates, Dust conversion, the Trainer shop and the
2-slot loadout. `ArcaneDust`, `Arcane = {}` and a working ability runtime are
already in place, so this is more assembly than invention.

**P1.3 — Dungeon Mastery.** `MasteryXp` exists on every `DungeonProgress` entry
and is explicitly marked "not yet earned". Needs XP sources, levels, and the
milestone rewards at 5/10/15/20/25/30. Cheap relative to its retention value,
and the GDD's constraint (prestige only, never power) keeps it from entangling
with balance.

**P1.4 — Keystone Trial.** Zero implementation. All five dungeons chained with
the run build carrying across, failure resetting. Architecturally the hardest
remaining item: it needs cross-place build persistence that nothing else in the
codebase currently does. Worth starting the design early even if built late.

### P2 — Content volume

Current vs the GDD's Realm 1 target (5 dungeons):

| Content | Have | GDD target | % |
|---|---|---|---|
| Melee weapons | 7 | 30 | 23% |
| Ranged weapons | 4 | 30 | 13% |
| Armor pieces | 9 (3 sets) | 90 (30 sets) | 10% |
| Legendary uniques | — | 10 | ~0% |
| Arcane spells | 12 | 50 | 24% |
| Enemies | 18 legacy | ~25 themed | 0% aligned |
| Relics | 90 | ~95 | 95% |

Relics are effectively done. Everything else is roughly one dungeon's worth of
content against a five-dungeon target. Blocked on D1, D2 and D8 — don't mass-
produce items before those naming and structure decisions are made, or they get
made twice.

### P3 — Cleanup and deferred

- **P3.1** — Rename `Stormcrest Mountains` → `Stormcrest Temple` (D5), and fix
  the GDD's own `Emberforge Keep` / `Glacierfall Citadel` slips (D6).
- **P3.2** — Resolve `Mythic` (D3).
- **P3.3** — Drop the 3 orphaned `RelicNames` without `RelicData` entries (D9).
- **P3.4** — Enchantments: 1 of 8 (`Looter` only). GDD marks these post-launch,
  so this is correctly deferred — but the slot, the roll (25% chance in
  `GearDrop.lua`) and the UI already exist, so adding the other 7 is cheap when
  wanted.
- **P3.5** — Guildhall, Travelling Salesman, Realm Gate, cosmetics, mounts.
- **P3.6** — Regenerate the stale `Docs/RelicBalance.md`.

---

## 5. Open tuning decisions the GDD itself leaves open

Carried here so they are not lost:

1. Do late equipment upgrades have a failure chance, or stay 100% guaranteed?
   (GDD prefers: early guaranteed, failure never destroys or downgrades.)
2. How much Arcane XP does a natural duplicate grant, per rarity?
3. What do Robux "Upgraded" Arcane Chests contain, and at what odds?
4. Sell-value refund percentage on upgraded gear.
5. Forge Crystal acquisition rates per difficulty.
