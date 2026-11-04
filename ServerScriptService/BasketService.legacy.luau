local Players = game:GetService("Players")
local CS = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")
local BasketModel = require(ServerStorage:WaitForChild("Modules"):WaitForChild("BasketModel"))

local DISPLAY_COUNT = 3
local SPACING = 1.7

local function findBasket(player: Player): Instance?
	local char = player.Character
	return (char and char:FindFirstChild("Basket")) or player.Backpack:FindFirstChild("Basket")
end

local function giveBasket(player: Player)
	local tool = BasketModel.makeTool()
	tool.Parent = player.Backpack
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then hum:EquipTool(tool) end
end

local function setupStand(stand: BasePart)
	stand.Anchored = true

	-- Display baskets sitting on top of the stand.
	local topY = stand.Size.Y / 2 + 0.075
	for i = 1, DISPLAY_COUNT do
		local x = (i - (DISPLAY_COUNT + 1) / 2) * SPACING
		local b = BasketModel.makeDisplay()
		b.Parent = stand
		b:PivotTo(stand.CFrame * CFrame.new(x, topY, 0))
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Take / return basket"
	prompt.ObjectText = "Baskets"
	prompt.HoldDuration = 0.2
	prompt.MaxActivationDistance = 9
	prompt.RequiresLineOfSight = false
	prompt.Parent = stand

	prompt.Triggered:Connect(function(player)
		local existing = findBasket(player)
		if existing then
			existing:Destroy()
		else
			giveBasket(player)
		end
	end)
end

for _, p in CS:GetTagged("BasketStand") do setupStand(p) end
CS:GetInstanceAddedSignal("BasketStand"):Connect(setupStand)