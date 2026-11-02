# Hub Gear Merchant (spec, 2026-10-31)

A Gold sink and a catch-up: an NPC in the Lobby who sells a few random pieces of gear at the
player's tier, restocked every run. The Minecraft Dungeons Luxury Merchant, the Dungeon Quest shop.
Written from the `RyanChang25/feature-mob-rework` session for the `feature/lobbybranch` worktree to
build the UI and the NPC; the server pieces it needs are listed at the end and can be built in
either branch.

## What the player sees

- An NPC in the hub next to the Blacksmith (reuse the Merchant NPC model and prompt if one exists;
  the in-dungeon Merchant Shop event is retired, so its assets are free).
- A window with **4 stock slots**. Each slot is one gear piece: weapon or armor, shown as an
  ordinary inventory tile (name, rarity colour, level, the main stat, its enchantment badge, its
  lines) with a **Gold price** under it and a Buy button.
- A **Restock** line at the bottom: "New stock after your next run" and, under it, a paid
  **Reroll stock** button for Arcane Crystals (optional, see below).
- Buying moves the piece into the inventory exactly like a pickup (it banks at once, no escrow) and
  the slot shows "Sold". Sold slots stay empty until the restock.
- A player with no cleared tier yet sees Easy stock, so the first visit works before the first run.

## Stock rules

| Rule | Value |
|---|---|
| Slots | 4 |
| Tier | The highest difficulty the player has cleared (DungeonProgress), Easy before any clear |
| Pool | That tier's `dungeonDrops` of the player's **most recently run dungeon** (or Runegrove), weapons and armor only, never Legendary uniques |
| Rarity | The tier's `rarityWeights` with Common removed (the shop never sells Commons) |
| Level | Uniform over the tier's `levelRange`, like a drop |
| Quality, enchantment, lines | Rolled exactly like a drop: `scalarMultiplier` 0.5 to 1.0, `rollWeaponEnchantment`, `rollBonusStats` |
| Restock | On every run end for that player (clear, death or leave), and on first login of a day |
| Reroll stock | Optional button: 10 Arcane Crystals, rerolls all unsold slots. Leave it out of the first cut if Crystals feel tight |

Stock is **per player** and persisted on the profile so it survives a rejoin and does not reroll on
every window open: `profile.MerchantStock = { tier, dungeonId, restockedAt, slots = { entry | false, ... } }`
where `entry` is a normal inventory entry (uuid, name, rarity, level, enchantment, scalarMultiplier,
bonusStats). Four slots, `false` for a sold one (never a hole: the table crosses a remote).

## Prices

Half a run of the stock's tier for a Rare, scaled by rarity, so one purchase is always a real
choice against an upgrade:

| Rarity | Price as a share of the tier's run income | Easy / Normal / Hard / Nightmare |
|---|---|---|
| Uncommon | 0.30 | 60 / 120 / 230 / 445 |
| Rare | 0.50 | 105 / 200 / 385 / 745 |
| Epic | 0.90 | 185 / 360 / 695 / 1335 |
| Legendary | 1.50 | 310 / 600 / 1155 / 2230 |

"Run income" is `DifficultyData.RunGoldTake(tier)` (205 / 400 / 770 / 1485 since 2026-11-01, when
run Gold was halved and Crystals doubled), the same number
the Blacksmith prices against, so the shop and the forge move together when the economy is retuned.
Put the shares in a shared data module (`MerchantStockData`) next to `BlacksmithData`, never in the
UI.

## Why these numbers

- A Rare at half a run means a player who had a dry run can still buy one upgrade-worthy piece.
- An Epic at 0.9 runs is about what it costs to max a Rare, so "buy an Epic" and "max my Rare" are
  the same money and a real decision.
- Legendary stock is rare by the rarity weights (0.5 to 1%) and priced like a project; it is the
  thing a player saves for when it appears, which is the point of a restock timer.

## Server pieces needed

1. `MerchantStockData` (bfg-core Shared/Data): the shares table, slot count, the reroll Crystal
   price, and `PriceFor(entry, tier)`.
2. `MerchantStockService` (bfg-core Server/Services, hub-only in practice but place-agnostic like
   BlacksmithService): `Restock(player)`, `GetStock(player)`, `Buy(player, slotIndex)`,
   `RerollStock(player)`. Buy charges Gold through CurrencyService, inserts the entry into the
   profile inventory (the same code path GearDrop uses at pickup: `RunEscrowService.AddItem` banks to
   the profile now), and sets the slot to `false`. Restock listens to the run-end signal the hub
   already gets (the run history write in `DungeonProgressService` is the natural hook) and to the
   daily-first-login check.
3. Blink, `Player.blink`: `GetMerchantStock` (function, returns the four slots), `BuyMerchantStock`
   (function, slot index, returns Accepted / Gold / Message), `RerollMerchantStock` (function,
   returns Accepted / Message), and a `MerchantStockChanged` event for the live window.
4. Profile: a `MerchantStock` key on `DataTemplate` with a `Migrations` step (coordinate: the
   migration file is a shared hotspot; the next free version is 5).

## Out of scope for the first cut

Haggling, buy-back of sold gear, cosmetics, Robux restocks. If the shop proves popular the
natural next step is a second NPC selling spells for Crystals, which would replace the Arcane
Chest gamble with a choice.
