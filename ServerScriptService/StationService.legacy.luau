local CS = game:GetService("CollectionService")

local STATIONS = {
	Microwave = { Input = "RiceBowl", Output = "HotRiceBowl", Seconds = 10, Action = "Heat up" },
	HotWater  = { Input = "CupRamen", Output = "ReadyRamen",  Seconds = 20, Action = "Make ramen" },
}

local MOOD = { ReadyRamen = 5, HotRiceBowl = 4, Onigiri = 2, MilkTea = 1, Chips = 1 }
local EAT_ORDER = { "ReadyRamen", "HotRiceBowl", "Onigiri", "MilkTea", "Chips" }

local function take(player: Player, id: string): boolean
	local inv = player:FindFirstChild("Inventory")
	local v = inv and inv:FindFirstChild(id)
	if v and v.Value > 0 then
		v.Value -= 1
		return true
	end
	return false
end

local function give(player: Player, id: string)
	local inv = player:FindFirstChild("Inventory")
	if not inv then return end
	local v = inv:FindFirstChild(id)
	if not v then
		v = Instance.new("IntValue")
		v.Name = id
		v.Parent = inv
	end
	v.Value += 1
end

local function newPrompt(part: BasePart, action: string, object: string): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = action
	prompt.ObjectText = object
	prompt.HoldDuration = 0.2
	prompt.MaxActivationDistance = 7
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
	return prompt
end

local function setupStation(part: BasePart)
	local kind = part:GetAttribute("StationType")
	local cfg = STATIONS[kind]
	if not cfg then
		warn("Unknown StationType on", part:GetFullName())
		return
	end
	local prompt = newPrompt(part, cfg.Action, kind)
	local ding = part:FindFirstChild("Ding")
	local busy = false

	prompt.Triggered:Connect(function(player)
		if busy then return end
		if not take(player, cfg.Input) then
			prompt.ObjectText = "Needs " .. cfg.Input
			task.delay(2, function()
				if not busy then prompt.ObjectText = kind end
			end)
			return
		end
		busy = true
		prompt.ActionText = "Working..."
		for t = cfg.Seconds, 1, -1 do
			prompt.ObjectText = kind .. " (" .. t .. "s)"
			task.wait(1)
		end
		if ding then ding:Play() end
		if player.Parent then give(player, cfg.Output) end
		prompt.ActionText = cfg.Action
		prompt.ObjectText = kind
		busy = false
	end)
end

-- // Eating counter + Mood --------------------------------------------
local function addMood(player: Player, amount: number)
	local mood = tonumber(player:GetAttribute("Mood")) or 0
	local nextMood = math.clamp(mood + amount, 0, 10)
	player:SetAttribute("Mood", nextMood)
	return nextMood
end

local function nextFood(player: Player): string?
	local inv = player:FindFirstChild("Inventory")
	if not inv then return nil end
	for _, id in EAT_ORDER do
		local v = inv:FindFirstChild(id)
		if v and v.Value > 0 then
			return id
		end
	end
	return nil
end

local function setupEatSpot(part: BasePart)
	if part:FindFirstChildOfClass("ProximityPrompt") then return end
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Eat"
	prompt.ObjectText = "Window Counter"
	prompt.HoldDuration = 0.2
	prompt.MaxActivationDistance = 7
	prompt.RequiresLineOfSight = false
	prompt.Parent = part

	prompt.Triggered:Connect(function(player)
		local id = nextFood(player)
		if not id then
			prompt.ObjectText = "Nothing to eat!"
			task.delay(2, function()
				prompt.ObjectText = "Window Counter"
			end)
			return
		end
		take(player, id)
		local mood = addMood(player, MOOD[id] or 1)
		prompt.ObjectText = "Ate " .. id .. "! Mood " .. mood .. "/10"
		task.delay(2, function()
			prompt.ObjectText = "Window Counter"
			end)
	end)
end

-- // Hook up existing and future stations ------------------------------
for _, part in CS:GetTagged("Station") do
	if part:IsA("BasePart") then
		setupStation(part)
	end
end
CS:GetInstanceAddedSignal("Station"):Connect(function(part)
	if part:IsA("BasePart") then
		setupStation(part)
	end
end)

for _, part in CS:GetTagged("EatSpot") do
	if part:IsA("BasePart") then
		setupEatSpot(part)
	end
end
CS:GetInstanceAddedSignal("EatSpot"):Connect(function(part)
	if part:IsA("BasePart") then
		setupEatSpot(part)
	end
end)
