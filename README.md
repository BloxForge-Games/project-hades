# Game Design Document — Project Hades

**Engine:** Roblox
**Genre:** Isometric Roguelike / Action
**Perspective:** Fixed isometric (top-down)
**Inspiration:** Hades (Supergiant Games)
**Internal Codename:** Project Hades
**Status:** In Development

---

## Table of Contents

1. [Game Overview](#1-game-overview)
2. [Core Design Pillars](#2-core-design-pillars)
3. [Gameplay Loop](#3-gameplay-loop)
4. [Player Systems](#4-player-systems)
5. [Combat](#5-combat)
6. [Magic System](#6-magic-system)
7. [Relic System](#7-relic-system)
8. [Enemy Design](#8-enemy-design)
9. [Build System](#9-build-system)
10. [Room & Dungeon Structure](#10-room--dungeon-structure)
11. [Progression & Data](#11-progression--data)
12. [UI & Feedback](#12-ui--feedback)
13. [Multiplayer](#13-multiplayer)
14. [Planned / Stub Systems](#14-planned--stub-systems)

---

## 1. Game Overview

Project Hades is a co-op isometric roguelike on Roblox. Players clear rooms of zombies and supernatural enemies using a combination of weapons, magic spells, and passive relics that stack into powerful synergistic builds — inspired directly by Hades's boon system. Each run rewards players with relics from defeated rooms; no two runs feel identical.

The game blends:
- **Roguelike itemization** (stackable relics with set bonuses)
- **Action combat** (directional dodges, melee combos, ranged weapons)
- **Tower defense layer** (placeable barricades, spike traps, turrets)
- **Anime-inspired spectacle** (Jujutsu Kaisen–themed legendary abilities with cutscenes)

---

## 2. Core Design Pillars

### 2.1 Every Run Feels Different
Relics are the heart of the game. With 22+ relics, each stackable up to 3–5 times, and set bonuses that unlock at max stacks, players build completely different characters across runs. A run might focus on crit-stacking with Silver Ninja Stars, sustain tanking with Cheeseburger + Riot Shield, or burst mana cycling with Korblox Spell Book + Overcharged aura.

### 2.2 Moment-to-Moment Combat Is Expressive
Combat is not just "click enemy." The dodge system rewards timing (Perfect Dodge mechanic), weapons have multi-hit combos with precise hitbox windows, and magic abilities have meaningful cooldowns and positioning requirements. Players must choose *when* to commit to an attack and when to evade.

### 2.3 Risk / Reward Escalation
Each cleared room presents a relic machine (vending machine) offering new relics. Players spend coins earned from combat to acquire them. Building out toward a set bonus is a risk — spending coins on stacks of one relic means forgoing others.

### 2.4 Cooperative, Not Competitive
Enemy HP scales with player count. Shared room-clear rewards (relic machines appear at each player's position). The build system is per-player (barricades, traps, turrets are owned by the builder). Assists count toward progression statistics.

---

## 3. Gameplay Loop

```
Spawn → Clear Room → Collect Drops (coins/mana) → Relic Machine Appears
  → Purchase Relic → Next Room → (repeat)
      ↓
  Dungeon Event (e.g. Merchant Shop)
      ↓
  Boss Room → Run Complete → Persistent Progression (EXP, unlocks)
```

### 3.1 In-Room Loop
1. Players enter a room; the `RoomService` registers their `ActiveRoom` attribute and fires entry bonuses (Pot of Gold coin grant, Teddy Bloxpin heal).
2. Zombies spawn continuously up to a per-player cap (`MAX_ZOMBIE_COUNT_PER_PLAYER = 6`). Spawn locations are chosen within 60 studs of a random player.
3. Players fight using weapons, magic, and buildables.
4. When all zombies are eliminated, a relic machine drops at each player's position.
5. Players spend coins to buy relics, then move to the next room.

### 3.2 Dungeon Events (Between Rooms)
After certain rooms, a dungeon event triggers:
- **Merchant Shop** (implemented) — Offers 5 relics per player for purchase via ProximityPrompt teleport.
- **Treasure Hunt** (planned)
- **Wheel of Fortune** (planned)
- **Corrupted Mobs** (planned)

---

## 4. Player Systems

### 4.1 Base Stats

| Stat | Default Value |
|------|--------------|
| Max HP | 100 (expandable via relics) |
| Walk Speed | 18 studs/s |
| Jump Power | 0 (no jumping; isometric) |
| Jetpack Speed | 27 studs/s |
| Max Mana | 100 (expandable via relics) |
| Crit Chance | 5% |
| Crit Multiplier | 1.5x |

### 4.2 Currency

| Currency | Earned By | Spent On |
|----------|-----------|----------|
| Coins | Killing enemies, room entry (Pot of Gold relic) | Relics, builds |
| Gems | Meta-progression (shop/unlock purchases) | Cosmetics, unlocks |
| Tickets | Dragon Lantern relic (+50% gain) | TBD |

Starting coins: 100. Starting gems: 25.

### 4.3 Inventory Slots

| Slot | Key | Content |
|------|-----|---------|
| Primary Weapon | 1 | Melee or ranged |
| Secondary Weapon | 2 | Melee or ranged |
| Magic Slot A | 3 | Spell |
| Magic Slot B | 4 | Spell |
| Build | B | Barricade / Trap / Turret |

### 4.4 Dodge

- **2 dodge charges**, each recharging in 3 seconds.
- Directional: 8-way relative to the camera.
- Distance: 15 studs over 0.25 seconds.
- Grants **invulnerability frames** during the roll (AfterImage visual).
- **Perfect Dodge:** If a zombie attack lands during the dodge window, the `Experimental Jetpack` relic effect triggers (launch into the air), and "Perfect Dodge!" text displays to the player.

### 4.5 Status Conditions

| Condition | Source | Effect |
|-----------|--------|--------|
| Burn | Fire Blast magic | 5 ticks over 5 seconds: `clamp(maxHP × 2.5%, 1, level × 25)` per tick |
| Slowed | Aura system | Reduced walk speed |

---

## 5. Combat

### 5.1 Server Authority
All damage is calculated server-side (DamageService). The client fires requests; the server validates, applies modifiers, and replicates results. This prevents exploit-driven one-shots.

### 5.2 Melee Weapons

All melee weapons use a **3-hit combo system** with per-hit hitbox delay, animation delay, and VFX timing.

| Weapon | Type | Rarity | Damage Range | Walk Speed |
|--------|------|--------|-------------|------------|
| Wooden Bat | Sword | Uncommon | 35–40 | 12.5 |
| Dragonbone Katana | Sword | Uncommon | 45–55 | 12.5 |
| Jujutsu Cleaver | Sword | Uncommon | 45–55 | 12.5 |
| Samehada Greatsword | Greatsword | Uncommon | 80–100 | 10.5 |

Hitboxes use `RaycastHitbox` (sweep-based), ensuring accurate collision even at high frame variance.

Enchantments: `None`, `Looter` (additional enchantments planned).

### 5.3 Ranged Weapons

Projectiles are simulated with the `ProjectileCast` library (ballistic, gravity-affected).

| Weapon | Rarity | Damage | Fire Rate | Ammo | Reload |
|--------|--------|--------|-----------|------|--------|
| Ruger SR9 (pistol) | Uncommon | 30–40 | 0.30s | 20 | 1.5s |
| MP5K (SMG) | Rare | 40–50 | 0.175s | 45 | 2.5s |
| AK-47 | Epic | 50–60 | 0.20s | 80 | 2.5s |

### 5.4 Damage Modifiers (Applied in Order)

1. Base weapon damage (random in damage range)
2. `scalarMultiplier` (item level scaling)
3. Relic modifiers (Linked Sword, Murder Knife, Phoenix Bow, Hyperlaser Gun, Fluffy Unicorn)
4. Aura modifiers (Frenzy, Overcharged)
5. Critical hit roll (5% base + relic bonuses)
6. On-hit procs (Portable Justice / Jail, Volleyball, Trick Or Trap pumpkin drop)

### 5.5 Critical Hits

- Default: 5% chance, 1.5× multiplier.
- Silver Ninja Star adds +10% crit chance per stack.
- At 5 stacks of Silver Ninja Star: additional +25% crit damage multiplier.

### 5.6 Ragdoll

Heavy hits and certain relics/spells can ragdoll enemies and players:
- Applied with a `BodyVelocity` knockback of 25 units.
- Auto-recovers after 2 seconds.
- Players with 5× Riot Shield are **immune to ragdoll**.
- Players in **super armor** (Domain Expansion) are immune during ability duration.

---

## 6. Magic System

### 6.1 Overview

Players equip up to 2 spells (keys 3 and 4). Spells are cast in the direction of the mouse cursor. Each spell has its own cooldown, mana cost, and damage type.

Mana regenerates passively and via the Korblox Spell Book relic (weapon hits restore mana). The Overcharged aura procs when mana is full with that relic equipped.

### 6.2 Spell Roster

| Spell | Rarity | Type | Damage | Cooldown | Special |
|-------|--------|------|--------|----------|---------|
| Wind Bomb | Common | Melee AOE | 100–125 | 12s | Knockback 350, ragdolls |
| Fire Blast | Rare | Ranged projectile | 125–150 | 12s | Applies Burn status |
| Lightning Shatter | Epic | AOE burst | 50–60 ×3 | 5s | 3 sequential hitboxes |
| Divergent Fist | Rare | Melee thrust | 150–175 | 3s | JJK-themed |
| Hollow Purple | Epic | Ranged beam | 200–250 | 4s | Long range, step-cast |
| Domain Expansion | Legendary | AOE field | 15–25 | 35s | 6.5s duration, super armor, cutscene |
| Susanoo Armor | Legendary | Aura summon | 25–35 | 45s | 25s lifetime, attacks every 3s, cutscene |

### 6.3 Legendary Ability Cutscenes

Domain Expansion and Susanoo Armor trigger client-side cutscenes (camera transitions, animation sequences) before the ability activates, creating a cinematic moment in the midst of combat.

### 6.4 Relic-Triggered Magic (Internal)

These are not player-equipped spells — they fire automatically from relic procs:

| Source Relic | Triggered Ability |
|---|---|
| Trick Or Trap | Pumpkin Explosion / Big Pumpkin Explosion on enemy death |
| Summer Fireworks | Periodic AOE fireworks projectiles |
| Ghost Dragon | Periodic % max HP damage to nearby enemies |

---

## 7. Relic System

Relics are the roguelike's core identity — passive items that stack and combine into powerful builds.

### 7.1 Acquisition

- Dropped by **Relic Machines** (vending machines) that appear at each player's position after clearing all zombies in a room.
- Offered by the **Merchant Shop** dungeon event (5 relics per player).
- Purchased with **Coins**.

### 7.2 Stacking Rules

| Rarity | Max Stacks |
|--------|-----------|
| Rare | 5 |
| Epic | 3 |
| Unique | 1 |

A player is only offered relics that still have available stacks (their pool excludes fully-stacked relics).

### 7.3 Rare Relics

| Relic | Effect per Stack | Set Bonus (max stacks) |
|-------|-----------------|----------------------|
| Bloxy Cola | -10% magic cooldown | TBD |
| Cheeseburger | +25 max HP | TBD |
| Teddy Bloxpin | +3% max HP heal on room entry | TBD |
| Fluffy Unicorn | +10% damage vs Minibosses/Bosses | TBD |
| Gear Recycler | +10% mana orb drop chance | Spellburst aura on mana orb pickup |
| Phoenix Bow | +15% damage to distant targets | TBD |
| Wizard Orb | +20% magic damage | TBD |
| Hyperlaser Gun | +10% damage when above 85% HP | Damage bonus threshold drops to 65% |
| Linked Sword | +10% weapon damage | Frenzy aura on kill/assist |
| Murder Knife | +20% damage to nearby enemies | TBD |
| Pot Of Gold | +25 coins on room entry | TBD |
| Riot Shield | +10% damage reduction | Ragdoll immunity |
| Silver Ninja Star | +10% crit chance | +25% additional crit multiplier |
| Starblox Latte | +25 max mana | TBD |

### 7.4 Epic Relics

| Relic | Effect per Stack | Set Bonus (max stacks) |
|-------|-----------------|----------------------|
| Experimental Jetpack | Jetpack on Perfect Dodge | TBD |
| Korblox Spell Book | Weapon hits restore mana; Overcharged aura at full mana | TBD |
| Dragon Lantern | +50% coins and tickets gained | TBD |
| Portable Justice | Chance to Jail enemies on weapon hit | TBD |
| Summer Fireworks | Periodic fireworks AOE projectiles | TBD |
| Trick Or Trap | Enemies drop explosive pumpkins on death | TBD |
| Volleyball | Every 3rd weapon hit fires a Volleyball projectile | TBD |
| Ghost Dragon | Periodic % max HP damage to nearby enemies | TBD |

### 7.5 Auras (Active Buffs)

Auras are temporary, visually distinct buff states triggered by relic set bonuses or in-game actions.

| Aura | Trigger | Duration | Effect |
|------|---------|----------|--------|
| Frenzy | Linked Sword ×5 — kill or assist | 10s | Damage boost (via DamageService modifier) |
| Spellburst | Gear Recycler ×5 — mana orb pickup | 10s | Magic damage boost |
| Overcharged | Korblox Spell Book ×3 — full mana | Until mana depleted | Magic power enhanced |
| Slowed | Various enemy/status effects | Variable | Walk speed reduced |

---

## 8. Enemy Design

### 8.1 Enemy Type Hierarchy

```
Normal → Elite → Miniboss → Boss
```

Miniboss and Boss types are defined in the enum system but not yet implemented as live enemy variants.

### 8.2 Current Enemy Roster

| Enemy | Type | Base HP | HP per Additional Player | Damage | Range | Special |
|-------|------|---------|--------------------------|--------|-------|---------|
| Walker | Normal | 100 | +1500 | 5 | 8 studs | Standard pathing |
| PotHead | Normal | 200 | +2000 | 5 | 8 studs | Standard pathing |
| Robombie | Elite | 5000 | +1000 | 5 | 15 studs | Can ragdoll players |

### 8.3 AI Behavior

- Pathfinding via Roblox `PathfindingService`.
- Targets **both players and buildables** (barricades, turrets, traps).
- Custom hitbox functions prevent server-side hit registration abuse.
- Enemies drop coins and EXP on death via the `LootPlan` weighted loot system.
- Death triggers drop rolls: 10% chance of a healing orb, remaining split between coins and mana orbs.

### 8.4 Spawn Rules

- Spawn cap: `6 zombies per player` simultaneously.
- Spawn location: within 60 studs of a randomly selected player.
- When all zombies are dead: relic machines drop for each player.

---

## 9. Build System

The build system adds a tower defense layer to combat. Players toggle build mode with **B**.

### 9.1 Buildables

| Build | Cost | Max Owned | Max HP | Function |
|-------|------|-----------|--------|----------|
| Barricade | 500 coins | 4 | 25 HP | Blocks zombie pathfinding routes, repairable |
| Spike Trap | 750 coins | 3 | 50 HP | Deals 50 base damage on trigger, multi-trigger |
| Turret | 1,000 coins | 2 | 25 HP | Auto-targets and shoots nearby zombies |

### 9.2 Placement

- Build mode shows a grid overlay. Player's own builds are highlighted.
- Placement is **server-validated** (collision checks prevent overlapping or illegal placements).
- Each build stores an `OwnerId` attribute (per-player ownership).
- Zombie AI detects buildables as valid targets.

### 9.3 Build Persistence

Build levels load from player data on join (`DataTemplate`). Players can invest in builds across sessions (planned upgrade path).

---

## 10. Room & Dungeon Structure

### 10.1 Room Types

| Type | Description |
|------|-------------|
| None | Transitional / lobby space |
| Standard | Regular zombie-clearing room |
| Miniboss | Features a Miniboss enemy (planned) |
| Boss | End-of-dungeon boss encounter (planned) |

### 10.2 Room Entry Effects

On entering a room, the following fire immediately:
- **Pot of Gold** relic: grants bonus coins per stack.
- **Teddy Bloxpin** relic: heals % max HP per stack.

### 10.3 Workspace Layout

The game world uses a structured folder hierarchy:

```
workspace/
  Map/
    Buildings/        -- Environmental structures
    Buildables/       -- Player-placed buildables
    RelicMachines/    -- Post-room relic vendors
    Events/           -- Dungeon event zones
    SpawnLocations/   -- Zombie spawn points
  Boundaries/         -- Map edge colliders
  Walls/              -- Transparent-on-approach walls
  Terrain/            -- Roblox terrain
  MagicSpells/        -- Active spell instances
  IgnoreInstances/
    Zombies/          -- Live zombie models
```

### 10.4 Camera

The game uses a **fixed isometric camera** (not the default Roblox follow cam) implemented via a custom `IsometricCamera` library. Jump power is set to 0 — no jumping; the camera framing would break. The camera supports shake (CameraShaker) on hits and magic casts.

Walls and buildings between the camera and the player **auto-become transparent** (WallsTransparencyController, BuildingTransparencyController) to keep the player visible at all times.

---

## 11. Progression & Data

### 11.1 Per-Run Tracking

| Stat | Tracked |
|------|---------|
| Kills + Assists | Yes |
| Elite kills | Yes |
| Miniboss kills | Yes |
| Boss kills | Yes |
| Deaths | Yes |
| Coins collected | Yes |

### 11.2 Persistent Data (ProfileService / DataStore)

| Field | Type | Default |
|-------|------|---------|
| Coins | int | 100 |
| Gems | int | 25 |
| Tickets | int | 0 |
| CurrentExp | int | 0 |
| TotalExp | int | 100 |
| Level | int | 1 |
| Builds | table | {} |
| Weapon inventory | table | {} |
| Magic inventory | table | {} |
| Pets | table | {} |
| Cosmetics | table | {} |
| Missions | table | {} |

DataStore key: `TestData-098` (test key; must change before production launch).

### 11.3 Item Schema

Each weapon/magic item stores:
- `name` — item identifier
- `level` — item upgrade level
- `equipSlot` — which slot it occupies
- `scalarMultiplier` — damage scaling factor
- `enchantment` (weapons only) — e.g., Looter

---

## 12. UI & Feedback

All UI is built with **React (Lua port) + ReactRoblox**, managed via Knit controllers.

### 12.1 HUD Elements

| Element | Description |
|---------|-------------|
| Player Vitals | HP bar and mana bar (ValueBar component) |
| Relic Interface | Currently held relics with stack counts (top-level HUD) |
| Build Toolbar | Buildable selection in build mode |
| Mobile Action Buttons | On-screen dodge and action buttons for mobile |
| Preload Screen | Loading screen before gameplay begins |

### 12.2 Feedback Systems

| System | Trigger | Output |
|--------|---------|--------|
| Damage Indicators | Enemy or player takes damage | Floating number at hit location |
| Text Indicators | Status events (Perfect Dodge!, Burned!, etc.) | Billboard text |
| Drop Indicators | Pickup spawns | 3D icon showing pickup type |
| User Notifications | System events (room clear, event starts) | Toast notification |
| Camera Shake | Taking damage, casting magic | Screen trauma shake |
| AfterImage | Dodging | Ghost trail on character |

### 12.3 Mobile Support

The `InputPlatformController` detects the platform (PC vs mobile). Mobile players get on-screen action buttons. Certain spells have `uniqueMobileIndicator` flags for touch-compatible targeting UI.

---

## 13. Multiplayer

- Co-op focused; all players share the same room and fight together.
- Enemy HP scales linearly with player count.
- Relic machines spawn at **each individual player's position** (no competition for drops).
- Build system is per-player (no sharing or griefing of others' structures).
- Round stats (kills, assists) are tracked per-player for post-run screens.
- All server-side; no peer-to-peer. Authority lives entirely on the server.

---

## 14. Planned / Stub Systems

The following systems have enum definitions, collision groups, or partial service stubs indicating planned but unimplemented content:

### 14.1 Enemy Types
- **Miniboss** — enum defined, no data or AI implemented yet.
- **Boss** — enum defined, no data or AI implemented yet.
- **PotHead** — data exists, not yet registered in the spawn service.

### 14.2 Dungeon Events
- **Treasure Hunt** — enum defined, not implemented.
- **Wheel of Fortune** — enum defined, not implemented.
- **Corrupted Mobs** — enum defined, not implemented.

### 14.3 Build Upgrades
- Build levels are stored in `DataTemplate`. An upgrade system is implied but not yet wired up.

### 14.4 Escort Missions
- `EscortObject` collision group defined in the collision setup. Suggests a future escort mission room type.

### 14.5 Lobby System
- A separate Lobby place (`lobby.project.json`) exists with `Places/Lobby/` scripts but minimal content. Planned as a hub between runs.

### 14.6 Cosmetics & Pets
- Both `Pets` and `Cosmetics` fields exist in the DataTemplate, no system implemented yet.

### 14.7 Missions
- `Missions` field in DataTemplate; no mission service exists yet.

### 14.8 Twitter Codes
- `TwitterCodes` field in DataTemplate; code redemption service not implemented.

### 14.9 Relic Set Bonuses (Partially Implemented)
Many relic set bonuses are described but their callback logic hasn't been connected. Priority completions:
- Bloxy Cola × 5 bonus
- Cheeseburger × 5 bonus
- Fluffy Unicorn × 5 bonus
- Pot of Gold × 5 bonus
- Wizard Orb × 5 bonus
- Dragon Lantern × 3 bonus
- Portable Justice × 3 bonus
- Summer Fireworks × 3 bonus
- Trick Or Trap × 3 bonus
- Ghost Dragon × 3 bonus

---

*Document generated from codebase analysis — April 2026.*
