local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Products = require(RS.Config.Products)
local Mochi = require(script.Parent.MochiService)

local MAX_ITEMS = 10
local STARTING_COINS = 50
local CHECKOUT_RANGE = 15
local busy: { [Player]: boolean } = {}

local function getCounterPosition(): Vector3?
	local counter = workspace:FindFirstChild("Checkout Counter", true)
	if not counter then return nil end
	if counter:IsA("BasePart") then return counter.Position end
	local ok, cf = pcall(counter.GetBoundingBox, counter)
	if ok then return cf.Position end
	return nil
end

local function setupPlayer(player: Player)
	if player:FindFirstChild("leaderstats") then return end

	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Value = STARTING_COINS
	coins.Parent = stats
	stats.Parent = player

	local inv = Instance.new("Folder")
	inv.Name = "Inventory"
	inv.Parent = player

	-- Mood powers buffs later (faster walk, bigger loyalty stamps). 0-10.
	player:SetAttribute("Mood", 5)
end

Players.PlayerAdded:Connect(setupPlayer)
for _, player in Players:GetPlayers() do
	setupPlayer(player)
end

Players.PlayerRemoving:Connect(function(player)
	busy[player] = nil
end)

RS.Remotes.Checkout.OnServerInvoke = function(player: Player, basket: unknown)
	if busy[player] then
		return false, "Mochi is already scanning your items."
	end
	if type(basket) ~= "table" then
		return false, "Invalid basket."
	end

	-- Validate every product ID and quantity before doing anything.
	local total, count = 0, 0
	for productId, qty in basket :: any do
		local product = Products[productId]
		if not product
			or type(qty) ~= "number"
			or qty ~= qty -- NaN guard
			or qty < 1
			or qty ~= math.floor(qty)
		then
			return false, "Invalid basket."
		end
		count += qty
		total += product.Price * qty
	end

	if count < 1 then
		return false, "Your basket is empty."
	end
	if count > MAX_ITEMS then
		return false, "Basket limit is " .. MAX_ITEMS .. " items."
	end

	local stats = player:FindFirstChild("leaderstats")
	local coins = stats and stats:FindFirstChild("Coins")
	if not coins then
		return false, "Could not find your coins."
	end
	if coins.Value < total then
		return false, "Not enough coins (need " .. total .. ")."
	end

	-- Players must be standing at the register to check out.
	local counterPos = getCounterPosition()
	if counterPos then
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if not hrp or (hrp.Position - counterPos).Magnitude > CHECKOUT_RANGE then
			return false, "Walk up to the register to check out."
		end
	end

	busy[player] = true
	local ok, err = pcall(Mochi.Serve, player, basket)
	busy[player] = nil
	if not ok then
		warn("[Checkout] Mochi.Serve error:", err)
		return false, "Checkout failed, please try again."
	end

	-- Charge and move items into the player's inventory.
	coins.Value -= total
	local inv = player:FindFirstChild("Inventory")
	if inv then
		for productId, qty in basket :: any do
			local entry = inv:FindFirstChild(productId)
			if not entry then
				entry = Instance.new("IntValue")
				entry.Name = productId
				entry.Parent = inv
			end
			entry.Value += qty
		end
	end

	return true, total
end
