--// Saves Coins, Inventory, and Mood so players keep their stuff.
-- Swap for ProfileStore later if you need session locking / versioning.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local AUTOSAVE_INTERVAL = 120

local store
pcall(function()
	store = DataStoreService:GetDataStore("PlayerProfile_v1")
end)
if not store then
	warn("[Save] DataStore unavailable - is Studio API access enabled?")
end

local function key(player: Player): string
	return "Player_" .. player.UserId
end

local function buildData(player: Player)
	local stats = player:FindFirstChild("leaderstats")
	local coins = stats and stats:FindFirstChild("Coins")
	local inv = player:FindFirstChild("Inventory")

	local data = {
		Coins = coins and coins.Value or 50,
		Mood = tonumber(player:GetAttribute("Mood")) or 5,
		Inventory = {},
	}
	if inv then
		for _, v in ipairs(inv:GetChildren()) do
			if v:IsA("IntValue") and v.Value > 0 then
				data.Inventory[v.Name] = v.Value
			end
		end
	end
	return data
end

local function saveProfile(player: Player)
	if not store then return end
	local data = buildData(player)
	local ok, err = pcall(function()
		store:UpdateAsync(key(player), function()
			return data
		end)
	end)
	if not ok then
		warn("[Save] failed for", player.Name, err)
	end
end

local function loadProfile(player: Player)
	if not store then return end
	local ok, data = pcall(function()
		return store:GetAsync(key(player))
	end)
	if not ok then
		warn("[Save] could not load", player.Name)
		return
	end
	if type(data) ~= "table" then return end

	-- Wait for the server scripts to create leaderstats + Inventory.
	local stats, inv
	for _ = 1, 50 do
		stats = player:FindFirstChild("leaderstats")
		inv = player:FindFirstChild("Inventory")
		if stats and inv then break end
		task.wait(0.2)
	end
	if not (stats and inv) then return end

	local coins = stats:FindFirstChild("Coins")
	if coins and type(data.Coins) == "number" then
		coins.Value = data.Coins
	end
	if type(data.Mood) == "number" then
		player:SetAttribute("Mood", math.clamp(data.Mood, 0, 10))
	end
	if type(data.Inventory) == "table" then
		for id, qty in data.Inventory do
			if type(qty) == "number" and qty > 0 then
				local v = inv:FindFirstChild(id)
				if not v then
					v = Instance.new("IntValue")
					v.Name = id
					v.Parent = inv
				end
				v.Value = qty
			end
		end
	end
end

Players.PlayerAdded:Connect(loadProfile)
for _, player in Players:GetPlayers() do
	task.spawn(loadProfile, player)
end

Players.PlayerRemoving:Connect(saveProfile)

task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for _, player in Players:GetPlayers() do
			task.spawn(saveProfile, player)
		end
	end
end)

game:BindToClose(function()
	for _, player in Players:GetPlayers() do
		task.spawn(saveProfile, player)
		end
	task.wait(2)
end)
