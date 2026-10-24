# UI style spec — anime-cartoon "bubbly" refactor (2026-10-22)

Source: `Roblox-2026-10-22T03_49_52.054Z.mp4` (41.7 s, 2560×1472, 27.78 fps, 1157 frames). Frames and contact sheets are in the session scratchpad under `uiref\` (2 fps survey, full-rate bursts `A_backpack_open`, `B_backpack_close`, `C_profile_open`, `D_codes_cycle`, `E_hover`, `F_quests_open`, `G_daily_close`, `H_hover_zoom`, plus `zoom\` stills). Times below are seconds into the clip; one frame is 36 ms.

## Summary

The reference is a dark, pastel-on-black lobby UI: near-black panels with a faint checkerboard, thin light strokes, big rounded corners, Montserrat-style bold caps, and one saturated pastel per element. Its juice is four things: (1) a full-screen white diagonal **slash** that wipes left-to-right while the HUD slides off and the 3D scene blurs, (2) a panel that **flies in** tilted and settles with overshoot, (3) a **fold-out** close where the panel tips over in perspective and drops off the bottom, and (4) HUD tiles that on hover turn their stroke and glyph white, get a diagonal light streak, and spawn two four-point sparkles at the corners. Everything else is static: no idle bobbing on panels or HUD, no number pops, no bar-fill animation seen.

One honest caveat: the fly-in and fold-out are true 3D (keystoned perspective, see `zoom\profile_entry_C013.jpg` and `zoom\daily_fold_G010.jpg`), so the reference almost certainly renders panels on a camera-locked SurfaceGui or similar. A 2D React-lua approximation (Rotation + Position + UIScale, optional Y-squash) gets 85% of the feel for a fraction of the cost; true 3D is an optional phase 2.

Headline costs: image generation $1–8 total; Claude implementation roughly 0.9M–1.6M tokens across five screens plus a shared helper (4–7 sessions).

## Video breakdown

| Effect | Where seen | Timing | What happens |
|---|---|---|---|
| HUD icon click + HUD hide | 7.34–7.45 (A f005–f008), 9.48–9.52 (C) | 3 frames, ~110 ms, Quad-In feel | Clicked tile whitens; left cluster slides off left, right cluster off right, bottom row off bottom. No fade, pure translate. |
| Slash (open) | 7.38–7.63 (A f006–f013), 9.55–9.73 (C), 34.14–34.32 (F) | 7–8 frames, ~270 ms, near-linear speed | A "/"-leaning band (≈52° from horizontal, steeper than 45°) enters from off-screen left and exits bottom-right, travelling ~1.6 screen widths. Band is three stripes: wide pure white (~22% of screen height), solid navy gap (~7%), thin white (~6%). Flat colour, no texture or glow. |
| Scene blur | lands at ~7.52 (A f010), off instantly at close (B f011→f012) | ~4 frames in, 1 frame out | A post-process blur on the 3D scene only (the GUI stays crisp). Starts mid-slash, so the slash covers the pop. |
| Panel fly-in (bottom variant) | Backpack 7.63–8.03 (A f013–f024), Quests 34.43–34.86 (F f013–f025) | 11–12 frames, ~400–430 ms, Back-Out feel | Panel appears partly off the bottom-left, rotated about −10° (left edge low), scale ~0.85; rises to final position, passes ~3% above it, rotation crosses 0 and settles. Fully opaque throughout. Starts while the slash is still exiting (3-frame overlap). |
| Panel fly-in (side variant) | Profile 9.73–10.45 (C f013–f033) | ~18 frames, ~650 ms, spring-like | Enters from the right edge rotated about −18° with strong perspective keystoning (a 3D plane turning to face the camera), swings past centre to the upper-left, then eases back. Longer and loopier than the bottom variant. |
| Panel drop-in (small modal) | Codes 11.8–12.2 (D f001–f005) | ~0.4 s, Quad-Out | Drops from the top with a ±3° wobble, no slash, no HUD hide beyond the blur. |
| Fold-out close | Daily 16.14–16.36 (G f005–f011), Codes 13.6–13.9 (D f019–f021) | 6–7 frames, ~250 ms, Quad-In (accelerating fall) | Panel rotates 0 → about −25°, tips away (top edge wider than bottom), and falls off the bottom-left. No slash. Blur releases the frame it leaves; HUD slides back in over ~5 frames (~180 ms) after that. |
| Slash-cut close | Backpack 8.62–8.80 (B f007–f012), Areas 23.5, Level Road 33.0 | ~8 frames | Reverse slash (enters bottom-right, exits top-left). The panel simply vanishes while the band covers it (f010→f011); no fold. So the reference has two close variants; the fold-out is the one worth copying. |
| HUD tile hover | 20.02–20.45 (H f003–f015) | in: 2–3 frames (~90 ms); out: 3–4 frames | Stroke goes white, glyph goes white, label pill lightens. A soft diagonal light streak crosses the tile over ~5 frames. A four-point white sparkle scales in at the bottom-right corner just outside the tile (≈30% of tile width), a smaller one at the top-left; they linger ~6 frames and shrink. Tile scale change, if any, is under 3%. |
| Button press, number pops, bar fills, idle motion | Close X, tabs, XP bar, currency, panels | none resolvable or none present | Press shows only a colour change at 27.78 fps; bars and currency never change; settled panels and the HUD hold to the pixel. Assume the project's existing 1.15 press pulse. |

Sounds cannot be judged from stills; the loading-screen logo shatter (0–3.6 s) is out of scope.

## Visual language

| Element | Observed (at 2560 wide) | Build as |
|---|---|---|
| Panel body | Near-black `#141414`, faint ~8% white checkerboard (~24 px squares), 1.5–2 px light stroke (`#CFCFCF`→white gradient, ~30% transparent), corner radius ~14 px, soft dark drop shadow | Frame + UICorner `UDim.new(0,12)` at 1080p + `panelStroke()` from Blacksmith + UIShadow; checker is an optional tiled ImageLabel at `ImageTransparency 0.92` |
| HUD tile | Dark body, 3 px vertical pastel-gradient stroke, pastel flat glyph (~45% of tile width), full-width pastel label pill at the bottom (~22% of tile height) with bold white text and a thin dark text stroke | Frame + UIStroke with UIGradient (Rotation 90) + ImageLabel + Frame pill; no plate art |
| Palette | One pastel per tile: sky `#8EDBFF`, coral `#F4785A`, lavender `#A88BFF`, sand `#E8CFA0`, pink `#F2A4D6`, mint `#8FE3A8`, gold `#FFD15C`; accents: hot pink `#F0568A` (close X, "!" pins), coral gradient `#FFA07A→#F4785A` (primary buttons, XP bar), lavender `#B9A1FF→#8F77E6` (PLAY) | Color3 constants in one `UITheme` table |
| Typography | Geometric bold sans, titles ALL CAPS white, subtitles grey `#9A9A9A`; values on pills have a dark 1 px stroke | Montserrat Bold / ExtraBold (`FONT_BOLD` already used in Blacksmith) + `textStroke()` |
| Buttons | Rounded 8 px, gradient fill lighter at top, 1 px white stroke at ~40%; active tab = coral fill, inactive = dark pill; an orange underline fading to transparent under tab rows | Frame + UIGradient + UIStroke |
| Bars | Thin (~8 px), fully rounded, dark track `#0A0A0A` with 1 px stroke, coral→peach fill | Current `ValueBar` tree with a UIGradient on the fill |
| Currency pill | Dark pill, icon left, white bold number, a coloured "+" circle hanging off the right end | Frames |
| Cards / rows | Sky-blue gradient header strip with white text, dark body, 1 px stroke | Frames |
| Rank badges, item icons | Pre-rendered 3D-look emblems and flat item icons with a soft shadow | Image assets (only where the project needs equivalents) |
| Saturation / glow | High saturation, no bloom; depth comes from the scene blur and drop shadows, not from glows | BlurEffect + UIShadow |

## Build recipes (React-lua)

Conventions to reuse: imperative TweenService on refs inside `useEffect` (Inventory `Container.luau` 352–366, 408–460); `CanvasGroup` wrapper with `GroupTransparency` for whole-panel fades; `useIntroPop` (`Shared/Functions/VFX/useIntroPop.luau`) for UIScale pops; `tweenGui` (`Shared/Functions/UI/tweenGui.luau`) for position/size; `uiSound` (`Shared/Functions/VFX/uiSound.lua`) for open/hover/click; the OfferCard handle pattern (`OfferCard.lua` header) for anything with several named motions; `panelStroke()`/`textStroke()` from Blacksmith for strokes. All panel ScreenGuis already use `ScreenInsets = DeviceSafeInsets`.

**Panel fly-in.** Tree: `ScreenGui > Wrapper (CanvasGroup, AnchorPoint 0.5,0.5) > UIScale + UIShadow + Panel`. Never declare `Rotation`, `Position`, `GroupTransparency` or `UIScale.Scale` in JSX once they are tween-owned (same rule `useIntroPop` states). On open: snap `Position = final + UDim2.fromScale(-0.25, 0.6)`, `Rotation = -12`, `Scale = 0.85`, `GroupTransparency = 0`; then tween `Position` and `Rotation` with `TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out)` and `Scale → 1` with `TweenInfo.new(0.35, Back, Out)`. For the side variant use `from = right`, `Rotation = -18`, 0.55 s. Optional fake perspective: tween the Panel's `Size.Y` from 0.75× to 1× with Quad-Out 0.3 s. Start the fly-in 100 ms after the slash starts so they overlap as in the clip.

**Fold-out close.** Tween `Rotation 0 → -24`, `Position → final + UDim2.fromScale(-0.1, 0.9)`, `Scale 1 → 0.9`, optional `Size.Y → 0.6×`, all `TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)`; set `Interactable = false` on the first frame; on `Completed`, hide and reset. Do not fade: the fall reads better opaque.

**Slash.** One module-level `ScreenGui` (`IgnoreGuiInset = true`, `ScreenInsets = None`, `DisplayOrder` above every panel, `ResetOnSpawn = false`). Child: a `Frame` sized `UDim2.fromScale(2.2, 2.2)`, `AnchorPoint 0.5,0.5`, white, `Rotation = -52`, with a `UIGradient` whose `Transparency` sequence is `1 | 0 (0.38–0.60) | 1 | 0 (0.67–0.73) | 1` with adjacent keypoints for hard edges and a `Color` sequence that paints the gap navy `#1A1F5A`. Tween `UIGradient.Offset` from `Vector2(-1,0)` to `Vector2(1,0)` with `TweenInfo.new(0.28, Enum.EasingStyle.Linear)`; reverse the two offsets for close. This is one instance and one tween, no overdraw. Fire `uiSound` here (a new "UISlash" template).

**Scene blur and HUD shift.** A `BlurEffect` in `Lighting` tweened `Size 0 → 18` over 0.15 s Quad-Out, released over 0.05 s. HUD clusters are already positioned by `scaleUI`/`tweenGui.position` in the Toolbar; add a `hidden` pose per cluster (left cluster X − 0.2, bottom row Y + 0.2) and tween with `TweenInfo.new(0.12, Quad, In)` out and `TweenInfo.new(0.18, Quad, Out)` in.

**Hover glow (tiles and buttons).** Each tile owns refs to its `UIStroke`, glyph `ImageLabel`, label pill, a `Streak` Frame and two `Sparkle` ImageLabels. On enter: tween stroke `Color → white` and glyph `ImageColor3 → white` with `TweenInfo.new(0.09, Quad, Out)`; run the OfferCard sweep (`Streak` is a Frame with a 45° UIGradient white-at-centre, tweened `Position.X -0.6 → 1.2` over 0.2 s inside a `CanvasGroup` tile so UICorner clips it); each sparkle snaps `Scale 0`, tweens to `1.15` in 0.08 s Back-Out, holds 0.15 s, shrinks to 0 in 0.12 s. On leave: colours back over 0.14 s. Keep the existing 1.075 hover size and the 1.15/0.08/0.12 press pulse; they are the "pop". Sparkles are two `ImageLabel`s per tile (eight tiles → sixteen labels, invisible at rest); no pool or Heartbeat needed. Reuse the Heartbeat ember driver only if the owner wants drifting sparkles on the open panel.

**Press, number pop, bar fill.** Press: the Inventory pulse as is. Number pop: `UIScale 1 → 1.25 → 1` (0.08 Back-Out / 0.15 Quad-Out) on the readout plus the Toolbar's existing green/red colour flash. Bar fill: keep `ValueBar`'s 0.25 s Quad-Out size tween and add a white "ghost" fill behind it that catches up 0.35 s later (damage reads as a white sliver draining).

**Mobile.** Touch has no hover: wire the glow to `MouseButton1Down`/`TouchTap` (snap on, release off) and never gate functionality on it. The slash ScreenGui ignores insets while panels keep `DeviceSafeInsets`. Each `CanvasGroup` costs a render target: keep one per panel (the Inventory already nests some for cross-fades) and skip `BlurEffect` on `ScreenSizes.Mobile`. `Rotation` on a plain Frame with `ClipsDescendants` clips to the unrotated box; rotate the CanvasGroup instead.

## Shared UIJuice helper API

New module `bfg-core/Source/Shared/Functions/UI/UIJuice.luau` (shared by bfg-core and Dungeons via `ReplicatedStorage.Submodules.Core`). Sketch, not implementation:

```
UIJuice.flyIn(group: CanvasGroup, scale: UIScale?, opts: { from: "bottom"|"left"|"right"|"top", rotation: number?, seconds: number?, final: UDim2 }): Tween
UIJuice.foldOut(group: CanvasGroup, scale: UIScale?, opts: { seconds: number? }): Tween
UIJuice.slash(direction: "open"|"close"): ()           -- owns its ScreenGui; coalesces double calls
UIJuice.blur(on: boolean, size: number?): ()            -- no-op on Mobile unless forced
UIJuice.hoverGlow(refs: { stroke, glyph, pill?, streak?, sparkles? }, on: boolean): ()
UIJuice.pop(scale: UIScale, peak: number?): ()          -- press / number pop
UIJuice.useHover(ref): (hovered: boolean, handlers: { [React.Event]: fn })   -- mouse + touch fallbacks
UIJuice.usePanelJuice(groupRef, scaleRef, visible: boolean, opts): ()
   -- sequences slash → HUD hide → blur → flyIn on true; foldOut → blur off → HUD show on false;
   -- fires uiSound:PlayOpen / a new PlaySlash; cancels in-flight tweens on reopen
UIJuice.TweenInfos = { FLY_IN, FOLD_OUT, SLASH, GLOW_IN, GLOW_OUT, SPARKLE_IN, SPARKLE_OUT, POP_UP, POP_DOWN }
```

HUD hide/show needs a registry (`UIJuice.registerHudCluster(ref, hiddenOffset)`) so a panel in Dungeons can shift the Toolbar without requiring its controller directly — the same OptionalService discipline the services use.

## Per-screen refactor plan

| Screen | Replace | Effects | Sequence and effort |
|---|---|---|---|
| **UIJuice + theme** (first) | — | slash, blur, flyIn, foldOut, hoverGlow, pop, HUD registry, `UITheme` colours | 1. module + slash ScreenGui; 2. prove on the Inventory; 3. sparkle asset. **Medium** (new code, ~400 lines, 2–3 visual rounds). |
| **Inventory** (`InventoryInterfaceController`, 1,719 + ItemGrid/ItemFrame/CategoryFrame) | panel plate → Frame+stroke+corner+shadow; slot plates → dark tiles with pastel rarity stroke; tab row → pills + orange underline; X → hot-pink square; Equip → coral gradient | usePanelJuice replaces the Position/GroupTransparency open; keep `useIntroPop` sweep; hoverGlow on tiles and tabs; pop on X/Equip | 1. wrapper rotation/scale refs; 2. swap plates; 3. tiles; 4. tabs/buttons; 5. mobile pass. **High** (largest file, shared grid). |
| **Blacksmith** (1,418, shares ItemGrid) | same plates; stat rows keep `statRow`; result lines → sky-blue header strip; wallet chips → currency pills | usePanelJuice; hoverGlow on tiles; number pop on the upgraded stat; bar ghost on the chance bar | After Inventory so the grid work is inherited. **Medium-high**. |
| **Toolbar / HUD** (683 + fragment) | hotbar slots → pastel-stroke tiles with label pills; currency readouts → pills with "+" circle; dodge pips → mint pills | hoverGlow (desktop) and press glow (touch) on slots; number pop on currency change (keep colour flash); HUD hide/show registry | 1. register clusters; 2. tiles; 3. pills. **Medium**. |
| **Health and mana** (`PlayerVitalsInterface`, 428) | track → dark rounded with stroke; fill → coral/sky gradient; text → bold white with stroke; optional heart/drop glyph at the left end | bar ghost fill; low-health pulse (UIScale 1 → 1.04 loop) | 1. ValueBar gradient + ghost; 2. glyphs. **Low**. |
| **Relic tray** (`RelicInterfaceController`, 932 + entries) | tray body → panel plate; relic entries → tiles with rarity stroke; description card → dark card with sky header; Sell/Reforge/Drop → gradient buttons | usePanelJuice with `from = left` (it is a side tray); hoverGlow on entries; keep the ±15° icon wobble; pop on buttons | 1. plate; 2. entries; 3. buttons. **Medium**. |

Order: UIJuice → Inventory → Blacksmith → Toolbar → Relic tray → Vitals, then one integration pass (stylua, selene, luau-lsp both places, a Studio mobile-emulation check).

## Asset list

Prefer frames; only these need images.

| Asset | Purpose | Size | Alpha | Nine-slice |
|---|---|---|---|---|
| `ui_sparkle_4pt.png` | hover sparkle | 128×128 | yes | no |
| `ui_checker_tile.png` | optional panel texture, tiled | 64×64 | yes | no |
| `icon_hud_inventory.png`, `icon_hud_blacksmith.png`, `icon_hud_relics.png`, `icon_hud_map.png`, `icon_hud_settings.png`, `icon_hud_shop.png` | HUD tile glyphs, flat pastel | 256×256 | yes | no |
| `icon_currency_gem.png`, `icon_currency_coin.png`, `icon_currency_ore.png` | restyled currency icons (existing ones can stay) | 256×256 | yes | no |
| `icon_vitals_heart.png`, `icon_vitals_drop.png` | bar end glyphs | 128×128 | yes | no |
| `icon_slot_helmet/chest/melee/ranged.png` | empty-slot glyphs in the bag | 256×256 | yes | no |
| `art_blacksmith_header.png` | optional decorative header | 1024×512 | yes | no |

Eighteen images (fifteen without the optional ones). Everything else (panel plates, slot plates, bar casings, buttons, pills, tabs, close X, "!" pins, slash, streak, underline) is Frame + UICorner + UIStroke + UIGradient + UIShadow and looks the same.

## Cost estimate

**(a) Image generation.** Per asset: two gpt-image-1-mini candidates ($0.02) + one gpt-image-1 medium final ($0.04) + 30% redo ($0.012) = about $0.07. Eighteen assets ≈ **$1.30**; with high-quality finals ($0.17 + redo) ≈ **$4.30**. Allow a second exploration pass on the six HUD glyphs for consistency: **$1.50–$8** total. The real cost is cleanup (background removal, trimming, consistent stroke weight), which is Claude or human time, not API spend.

**(b) Claude (Fable) tokens.** By analogy with today's Blacksmith panel (one ~1,400-line screen, six rounds, 150k–300k tokens; 20k–40k per screenshot round).

| Work | Low | High |
|---|---|---|
| UIJuice module + slash/blur/HUD registry + theme | 120k | 220k |
| Inventory (plus grid components) | 200k | 350k |
| Blacksmith | 150k | 280k |
| Toolbar / HUD | 120k | 220k |
| Relic tray | 150k | 260k |
| Health and mana | 60k | 120k |
| Integration, lint, mobile check, regressions | 80k | 150k |
| **Total** | **~0.9M** | **~1.6M** |

That is four to seven sessions of ~250k. To stay near the low end: export the final geometry (positions, sizes, corner radii) from Studio before each screen instead of iterating on screenshots; decide the art and palette once in `UITheme` before any screen is touched; batch feedback per screen into one round rather than one note per round; approve the UIJuice motion on the Inventory alone and then forbid re-tuning it per screen; keep the shared ItemGrid changes to one pass so Blacksmith inherits them.

## Open questions for the owner

1. **2D approximation or true 3D panels?** The reference's keystoning is real perspective. 2D (Rotation + scale + optional Y-squash) is cheap and fits the React trees; a camera-locked SurfaceGui host is a separate phase with its own input, text-crispness and mobile costs.
2. **Which close?** The clip has two: fold-out (Daily, Codes) and slash-cut (Backpack, Areas). Fold-out for every panel, slash on open only, is the recommendation; slash on both is possible.
3. **Does the slash play in dungeons?** It hides the HUD and blurs the scene for ~0.4 s; fine in the hub, questionable mid-combat for the Relic tray. Suggest hub-only or a short variant for Dungeons.
4. **Does the HUD style extend beyond the five screens** (lives, encounter bar, dialogue, run inventory)? They will look mismatched otherwise, and the cost above excludes them.
5. **Keep the checkerboard texture?** It is subtle in the reference and is the one panel asset that must be tiled; dropping it removes an image and a draw.
6. **Fonts and colours:** confirm Montserrat Bold and the pastel set in the table above before any screen work, since every screen reads from `UITheme`.
7. **Sounds:** a slash whoosh, a hover tick and a close thud are implied; should they be sourced from the clip's audio track or the existing `GameAssets.Sounds` set?
