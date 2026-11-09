--!strict
--[[
	Module: RunSummaryInterfaceController.lua
	Description:
	The end-of-run summary (2026-11-08), drawn from the JSON the server's
	RunSummaryService sends (DungeonNetwork.RunSummaryShow) at the exit gate
	(CLEARED) or after a wipe (DEFEATED, over the game-over screen):

	  header      result, dungeon, difficulty, run time
	  stats       kills, damage dealt
	  party       in co-op, every player's kills and damage, the top
	              damage dealer marked MVP
	  rewards     Gold, Crystals, EXP (the friend bonus noted), and the gear
	              found (only when there was some)
	  build       the relics held
	  progress    what the run unlocked (a level, a difficulty, a dungeon, a
	              stronger gear chest) and the quests it moved forward
	  Continue    sends the player on (DungeonNetwork.RunSummaryContinue);
	              the server also does after `autoContinue` seconds.

	One fixed design size, scaled to the screen (UIScale), above every other
	screen GUI (the game-over gradient is 100000).
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])
local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RarityColors)
local FriendBonusData = require(ReplicatedStorage.Submodules.Core.Shared.Data.FriendBonusData)
local Theme = require(ReplicatedStorage.Submodules.Core.Source.Interfaces.PlayInterfaceController.ReactComponents.Theme)

local DISPLAY_ORDER = 100001
local WIDTH, HEIGHT = 780, 560
local PAD = 22
local COLUMN_GAP = 20
local COLUMN_WIDTH = (WIDTH - PAD * 2 - COLUMN_GAP) / 2
local CLEARED_COLOR = Color3.fromRGB(85, 255, 127)
local DEFEATED_COLOR = Color3.fromRGB(255, 92, 92)
local GOLD_COLOR = Color3.fromRGB(255, 200, 70)
local CRYSTAL_COLOR = Color3.fromRGB(150, 140, 255)
local EXP_COLOR = Color3.fromRGB(108, 196, 255)
local BAR_FILL_COLOR = Color3.fromRGB(105, 190, 255)
local RELIC_ICON = 34
local RELIC_GAP = 6
-- The co-op party strip, under the stats (only with 2+ players).
local PARTY_HEIGHT = 52
local PARTY_GAP = 12
local MVP_COLOR = Color3.fromRGB(255, 200, 70)

local RunSummaryInterfaceController = {
	Name = "RunSummaryInterfaceController",
}

type Summary = { [string]: any }

local function label(props: { [string]: any })
	return React.createElement("TextLabel", {
		AnchorPoint = props.anchor,
		BackgroundTransparency = 1,
		FontFace = props.font or Theme.FONT_BOLD,
		Position = props.position,
		RichText = true,
		Size = props.size,
		Text = props.text,
		TextColor3 = props.color or Theme.TEXT_COLOR,
		TextSize = props.textSize or 16,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = props.align or Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		ZIndex = 3,
	}, {
		Stroke = React.createElement("UIStroke", { Color = Theme.TEXT_STROKE_COLOR, Thickness = 1 }),
	})
end

local function card(props: { position: UDim2, size: UDim2 }, children: { [string]: any })
	return React.createElement("Frame", {
		BackgroundColor3 = Theme.CARD_COLOR,
		BorderSizePixel = 0,
		Position = props.position,
		Size = props.size,
		ZIndex = 2,
	}, children)
end

local function formatTime(seconds: number): string
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

-- 12345 -> "12,345".
local function withCommas(value: number): string
	local text = tostring(math.floor(value))
	local formatted = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (formatted:gsub("^,", ""))
end

local function hex(color: Color3): string
	return "#" .. color:ToHex()
end

-- One stat tile in the top row.
local function StatTile(props: { title: string, value: string, x: number, width: number })
	return card({ position = UDim2.fromOffset(props.x, 0), size = UDim2.fromOffset(props.width, 64) }, {
		Corner = React.createElement("UICorner", { CornerRadius = UDim.new(0, 8) }),
		Value = label({
			position = UDim2.fromOffset(0, 6),
			size = UDim2.new(1, 0, 0, 30),
			text = props.value,
			textSize = 24,
			font = Theme.FONT_HEAVY,
			align = Enum.TextXAlignment.Center,
		}),
		Title = label({
			position = UDim2.fromOffset(0, 38),
			size = UDim2.new(1, 0, 0, 18),
			text = props.title,
			textSize = 13,
			color = Theme.DESCRIPTION_COLOR,
			align = Enum.TextXAlignment.Center,
		}),
	})
end

-- A section caption.
local function Caption(props: { text: string, y: number })
	return label({
		position = UDim2.fromOffset(0, props.y),
		size = UDim2.new(1, 0, 0, 20),
		text = props.text,
		textSize = 16,
		font = Theme.FONT_HEAVY,
	})
end

-- One reward line: the name on the left, the amount on the right.
local function RewardRow(props: { name: string, amount: string, color: Color3, y: number })
	return React.createElement("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, props.y),
		Size = UDim2.new(1, 0, 0, 24),
	}, {
		Name = label({
			position = UDim2.fromOffset(0, 0),
			size = UDim2.new(0.5, 0, 1, 0),
			text = props.name,
			color = Theme.DESCRIPTION_COLOR,
		}),
		Amount = label({
			position = UDim2.fromScale(0.5, 0),
			size = UDim2.new(0.5, 0, 1, 0),
			text = props.amount,
			color = props.color,
			font = Theme.FONT_HEAVY,
			textSize = 18,
			align = Enum.TextXAlignment.Right,
		}),
	})
end

-- One next goal: a title, a detail line and a progress bar.
local function GoalRow(props: { goal: { [string]: any }, y: number })
	local progress = math.clamp(tonumber(props.goal.progress) or 0, 0, 1)
	return React.createElement("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, props.y),
		Size = UDim2.new(1, 0, 0, 52),
	}, {
		Title = label({
			position = UDim2.fromOffset(0, 0),
			size = UDim2.new(1, 0, 0, 18),
			text = tostring(props.goal.title or ""),
			textSize = 15,
		}),
		Detail = label({
			position = UDim2.fromOffset(0, 18),
			size = UDim2.new(1, 0, 0, 16),
			text = tostring(props.goal.detail or ""),
			textSize = 13,
			color = Theme.DESCRIPTION_COLOR,
			font = Theme.FONT_SEMI,
		}),
		Track = React.createElement("Frame", {
			BackgroundColor3 = Theme.WELL_COLOR,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(0, 38),
			Size = UDim2.new(1, 0, 0, 10),
			ZIndex = 3,
		}, {
			Corner = React.createElement("UICorner", { CornerRadius = UDim.new(1, 0) }),
			Fill = React.createElement("Frame", {
				BackgroundColor3 = if progress >= 1 then CLEARED_COLOR else BAR_FILL_COLOR,
				BorderSizePixel = 0,
				Size = UDim2.fromScale(progress, 1),
				ZIndex = 4,
			}, {
				Corner = React.createElement("UICorner", { CornerRadius = UDim.new(1, 0) }),
			}),
		}),
	})
end

-- One teammate in the party strip.
local function PartyCard(props: { member: { [string]: any }, x: number, width: number, isMe: boolean, isMvp: boolean })
	local member = props.member
	local accent = if props.isMvp
		then MVP_COLOR
		elseif props.isMe then Theme.ACCENT_TEXT_COLOR
		else Theme.PANEL_STROKE_COLOR
	return card({ position = UDim2.fromOffset(props.x, 0), size = UDim2.fromOffset(props.width, PARTY_HEIGHT) }, {
		Corner = React.createElement("UICorner", { CornerRadius = UDim.new(0, 8) }),
		Stroke = React.createElement("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = accent,
			Thickness = if props.isMvp or props.isMe then 1.5 else 1,
		}),
		Headshot = React.createElement("ImageLabel", {
			BackgroundTransparency = 1,
			Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48", tonumber(member.userId) or 0),
			Position = UDim2.fromOffset(6, 6),
			Size = UDim2.fromOffset(40, 40),
			ZIndex = 3,
		}, {
			Corner = React.createElement("UICorner", { CornerRadius = UDim.new(0.25, 0) }),
		}),
		Name = label({
			position = UDim2.fromOffset(52, 5),
			size = UDim2.new(1, -58, 0, 20),
			text = (if props.isMvp then string.format('<font color="%s">MVP</font>  ', hex(MVP_COLOR)) else "")
				.. tostring(member.name or ""),
			textSize = 14,
		}),
		Line = label({
			position = UDim2.fromOffset(52, 26),
			size = UDim2.new(1, -58, 0, 18),
			text = string.format(
				"%s dmg  •  %s kills",
				withCommas(tonumber(member.damageDealt) or 0),
				withCommas(tonumber(member.kills) or 0)
			),
			textSize = 12,
			color = Theme.DESCRIPTION_COLOR,
			font = Theme.FONT_SEMI,
		}),
	})
end

local function Panel(props: { summary: Summary, onContinue: () -> () })
	local summary = props.summary
	local cleared = summary.cleared == true
	local resultColor = if cleared then CLEARED_COLOR else DEFEATED_COLOR

	-- The countdown to the auto-continue (the server keeps the same one).
	local secondsLeft, setSecondsLeft = React.useState(tonumber(summary.autoContinue) or 30)
	React.useEffect(function()
		local alive = true
		task.spawn(function()
			while alive do
				task.wait(1)
				if alive then
					setSecondsLeft(function(value: number)
						return math.max(value - 1, 0)
					end)
				end
			end
		end)
		return function()
			alive = false
		end
	end, {})
	React.useEffect(function()
		if secondsLeft <= 0 then
			props.onContinue()
		end
	end, { secondsLeft })

	-- The screen scale.
	local scale, setScale = React.useState(1)
	React.useEffect(function()
		local camera = Workspace.CurrentCamera
		local function refresh()
			local viewport = camera and camera.ViewportSize or Vector2.new(WIDTH, HEIGHT)
			setScale(math.min(viewport.X / (WIDTH + 40), viewport.Y / (HEIGHT + PARTY_HEIGHT + PARTY_GAP + 40), 1))
		end
		refresh()
		local connection = camera and camera:GetPropertyChangedSignal("ViewportSize"):Connect(refresh)
		return function()
			if connection then
				connection:Disconnect()
			end
		end
	end, {})

	local subtitle = tostring(summary.dungeon or "")
	if summary.difficulty and summary.difficulty ~= "" then
		subtitle ..= "  •  " .. tostring(summary.difficulty)
	end
	subtitle ..= "  •  " .. formatTime(tonumber(summary.seconds) or 0)

	-- Stats row (2026-11-08: kills and damage dealt).
	local stats = {
		{ "Kills", summary.kills },
		{ "Damage Dealt", summary.damageDealt },
	}
	local tileWidth = (WIDTH - PAD * 2 - (#stats - 1) * 12) / #stats

	-- The party strip, co-op only; it pushes the columns down.
	local party = if type(summary.party) == "table" then summary.party else {}
	local partyCards = {}
	local columnsY = 172
	if #party > 1 then
		-- By card, not user id (a /summary preview's mock teammates share
		-- the tester's id, and every card read MVP).
		local mvpIndex, mvpDamage = nil, -1
		for index, member in party do
			local damage = tonumber(member.damageDealt) or 0
			if damage > mvpDamage then
				mvpIndex, mvpDamage = index, damage
			end
		end
		local myIndex = nil
		for index, member in party do
			if member.userId == summary.me then
				myIndex = index
				break
			end
		end
		local cardWidth = (WIDTH - PAD * 2 - (#party - 1) * 10) / #party
		for index, member in party do
			partyCards["Member" .. index] = React.createElement(PartyCard, {
				member = member,
				x = (index - 1) * (cardWidth + 10),
				width = cardWidth,
				isMe = index == myIndex,
				isMvp = mvpDamage > 0 and index == mvpIndex,
			})
		end
		columnsY += PARTY_HEIGHT + PARTY_GAP
	end
	local height = HEIGHT + (columnsY - 172)
	local statTiles = {}
	for index, stat in stats do
		statTiles["Stat" .. index] = React.createElement(StatTile, {
			title = stat[1],
			value = withCommas(tonumber(stat[2]) or 0),
			x = (index - 1) * (tileWidth + 12),
			width = tileWidth,
		})
	end

	-- Rewards and gear (left).
	local friendBonus = tonumber(summary.friendBonus) or 0
	local left = {
		Caption = React.createElement(Caption, { text = if cleared then "Rewards" else "Kept", y = 0 }),
		Gold = React.createElement(RewardRow, {
			name = "Gold",
			amount = "+" .. tostring(summary.gold or 0),
			color = GOLD_COLOR,
			y = 26,
		}),
		Crystals = React.createElement(RewardRow, {
			name = "Crystals",
			amount = "+" .. tostring(summary.crystals or 0),
			color = CRYSTAL_COLOR,
			y = 52,
		}),
		Exp = React.createElement(RewardRow, {
			name = "EXP",
			amount = "+" .. tostring(summary.exp or 0),
			color = EXP_COLOR,
			y = 78,
		}),
	}
	local gearY = 112
	if friendBonus > 0 then
		left.Friend = label({
			position = UDim2.fromOffset(0, 104),
			size = UDim2.new(1, 0, 0, 18),
			text = string.format(
				'<font color="%s">Friend Bonus %s</font> included',
				hex(CLEARED_COLOR),
				FriendBonusData.Format(friendBonus)
			),
			textSize = 13,
			color = Theme.DESCRIPTION_COLOR,
		})
		gearY = 130
	end
	-- Gear Found only when there was some (2026-11-08).
	local gear = if type(summary.gear) == "table" then summary.gear else {}
	if #gear > 0 then
		left.GearCaption = React.createElement(Caption, { text = "Gear Found", y = gearY })
	end
	for index, piece in gear do
		local color = RarityColors[piece.rarity] or Theme.TEXT_COLOR
		left["Gear" .. index] = label({
			position = UDim2.fromOffset(0, gearY + 24 + (index - 1) * 20),
			size = UDim2.new(1, 0, 0, 20),
			text = string.format(
				'<font color="%s">%s</font>  %s',
				hex(color),
				tostring(piece.rarity),
				tostring(piece.name)
			),
			textSize = 14,
		})
	end
	local more = (tonumber(summary.gearCount) or 0) - #gear
	if more > 0 then
		left.MoreGear = label({
			position = UDim2.fromOffset(0, gearY + 24 + #gear * 20),
			size = UDim2.new(1, 0, 0, 20),
			text = string.format("+%d more", more),
			color = Theme.MUTED_TEXT_COLOR,
			textSize = 13,
		})
	end

	-- Build and next goals (right).
	local right = {
		Caption = React.createElement(Caption, { text = "Your Build", y = 0 }),
	}
	local relics = if type(summary.relics) == "table" then summary.relics else {}
	local perRow = math.max(math.floor((COLUMN_WIDTH + RELIC_GAP) / (RELIC_ICON + RELIC_GAP)), 1)
	for index, name in relics do
		local row = (index - 1) // perRow
		local column = (index - 1) % perRow
		local data = RelicData[name]
		right["Relic" .. index] = React.createElement("ImageLabel", {
			BackgroundColor3 = Theme.WELL_COLOR,
			BorderSizePixel = 0,
			Image = if data and data.icon then data.icon else "",
			Position = UDim2.fromOffset(column * (RELIC_ICON + RELIC_GAP), 26 + row * (RELIC_ICON + RELIC_GAP)),
			Size = UDim2.fromOffset(RELIC_ICON, RELIC_ICON),
			ZIndex = 3,
		}, {
			Corner = React.createElement("UICorner", { CornerRadius = UDim.new(0, 6) }),
		})
	end
	local relicRows = math.max(math.ceil(#relics / perRow), 1)
	local spellsY = 26 + relicRows * (RELIC_ICON + RELIC_GAP)
	if #relics == 0 then
		right.NoRelics = label({
			position = UDim2.fromOffset(0, 26),
			size = UDim2.new(1, 0, 0, 20),
			text = "No relics",
			color = Theme.MUTED_TEXT_COLOR,
			textSize = 14,
		})
	end
	-- (No spells line, 2026-11-08: you know what you cast.)
	-- Progress: unlocks first, then the quests the run moved forward.
	local progressY = spellsY + 8
	right.ProgressCaption = React.createElement(Caption, { text = "Progress", y = progressY })
	local rowY = progressY + 26
	local unlocks = if type(summary.unlocks) == "table" then summary.unlocks else {}
	for index, text in unlocks do
		right["Unlock" .. index] = label({
			position = UDim2.fromOffset(0, rowY),
			size = UDim2.new(1, 0, 0, 20),
			text = string.format('<font color="%s">Unlocked</font>  %s', hex(CLEARED_COLOR), tostring(text)),
			textSize = 14,
		})
		rowY += 22
	end
	local quests = if type(summary.quests) == "table" then summary.quests else {}
	for index, quest in quests do
		if index > 3 then
			break
		end
		right["Quest" .. index] = React.createElement(GoalRow, { goal = quest, y = rowY + 4 })
		rowY += 56
	end
	if #unlocks == 0 and #quests == 0 then
		right.NoProgress = label({
			position = UDim2.fromOffset(0, rowY),
			size = UDim2.new(1, 0, 0, 20),
			text = "No quest progress this run",
			color = Theme.MUTED_TEXT_COLOR,
			textSize = 14,
		})
	end

	return React.createElement("Frame", {
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.35,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
	}, {
		Panel = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = Theme.PANEL_COLOR,
			BorderSizePixel = 0,
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(WIDTH, height),
			ZIndex = 1,
		}, {
			Scale = React.createElement("UIScale", { Scale = scale }),
			Corner = React.createElement("UICorner", { CornerRadius = UDim.new(0, 12) }),
			Stroke = React.createElement("UIStroke", { Color = resultColor, Thickness = 2, Transparency = 0.3 }),
			Result = label({
				position = UDim2.fromOffset(PAD, 14),
				size = UDim2.new(1, -PAD * 2, 0, 44),
				text = if cleared then "CLEARED" else "DEFEATED",
				color = resultColor,
				textSize = 40,
				font = Theme.FONT_HEAVY,
				align = Enum.TextXAlignment.Center,
			}),
			Subtitle = label({
				position = UDim2.fromOffset(PAD, 58),
				size = UDim2.new(1, -PAD * 2, 0, 20),
				text = subtitle,
				textSize = 15,
				color = Theme.DESCRIPTION_COLOR,
				align = Enum.TextXAlignment.Center,
			}),
			Stats = React.createElement("Frame", {
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(PAD, 92),
				Size = UDim2.fromOffset(WIDTH - PAD * 2, 64),
			}, statTiles),
			Party = if #party > 1
				then React.createElement("Frame", {
					BackgroundTransparency = 1,
					Position = UDim2.fromOffset(PAD, 168),
					Size = UDim2.fromOffset(WIDTH - PAD * 2, PARTY_HEIGHT),
				}, partyCards)
				else nil,
			Left = React.createElement("Frame", {
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(PAD, columnsY),
				Size = UDim2.fromOffset(COLUMN_WIDTH, 300),
			}, left),
			Right = React.createElement("Frame", {
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(PAD + COLUMN_WIDTH + COLUMN_GAP, columnsY),
				Size = UDim2.fromOffset(COLUMN_WIDTH, 320),
			}, right),
			Continue = React.createElement("TextButton", {
				AnchorPoint = Vector2.new(0.5, 1),
				AutoButtonColor = true,
				BackgroundColor3 = Theme.PLAY_COLOR,
				BorderSizePixel = 0,
				FontFace = Theme.FONT_HEAVY,
				Position = UDim2.new(0.5, 0, 1, -PAD),
				Size = UDim2.fromOffset(260, 46),
				Text = string.format("Continue  (%d)", secondsLeft),
				TextColor3 = Theme.TEXT_COLOR,
				TextSize = 20,
				ZIndex = 3,
				[React.Event.Activated] = props.onContinue,
			}, {
				Corner = React.createElement("UICorner", { CornerRadius = UDim.new(0, 10) }),
				Stroke = React.createElement("UIStroke", {
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
					Color = Theme.PLAY_STROKE_COLOR,
					Thickness = 2,
				}),
				TextStroke = React.createElement("UIStroke", { Color = Theme.TEXT_STROKE_COLOR, Thickness = 1.2 }),
			}),
		}),
	})
end

local function Root()
	local summary, setSummary = React.useState(nil :: Summary?)

	React.useEffect(function()
		DungeonNetwork.RunSummaryShow.On(function(json: string)
			local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
			if ok and type(decoded) == "table" then
				setSummary(decoded)
			end
		end)
	end, {})

	return React.createElement("ScreenGui", {
		Name = "RunSummaryInterface",
		DisplayOrder = DISPLAY_ORDER,
		Enabled = summary ~= nil,
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, {
		Panel = if summary
			then React.createElement(Panel, {
				summary = summary,
				onContinue = function()
					setSummary(nil)
					DungeonNetwork.RunSummaryContinue.Fire()
				end,
			})
			else nil,
	})
end

--[ Lifecycle ]--

function RunSummaryInterfaceController.Init(_self: typeof(RunSummaryInterfaceController))
	local root = ReactRoblox.createRoot(Instance.new("Folder"))
	root:render(ReactRoblox.createPortal(React.createElement(Root), Players.LocalPlayer.PlayerGui))
end

return RunSummaryInterfaceController
