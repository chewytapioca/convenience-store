local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Products = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("Products"))

-- Friendly names for station outputs that are not sold on shelves.
local EXTRA_NAMES = {
	HotRiceBowl = "Hot Rice Bowl",
	ReadyRamen = "Ready Ramen",
}

local function displayName(id: string): string
	local p = Products[id]
	if p then return p.Name end
	return EXTRA_NAMES[id] or id
end

-- // UI ---------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "InventoryGui"
gui.ResetOnSpawn = false
gui.Parent = playerGui

local toggle = Instance.new("TextButton")
toggle.Name = "Toggle"
toggle.AnchorPoint = Vector2.new(0, 1)
toggle.Position = UDim2.new(0, 12, 1, -12)
toggle.Size = UDim2.new(0, 110, 0, 34)
toggle.BackgroundColor3 = Color3.fromRGB(90, 170, 120)
toggle.BorderSizePixel = 0
toggle.Font = Enum.Font.GothamBold
toggle.TextSize = 14
toggle.TextColor3 = Color3.fromRGB(255, 255, 255)
toggle.Text = "Bag  [I]"
toggle.Parent = gui

do
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = toggle
end

local frame = Instance.new("Frame")
frame.Name = "Panel"
frame.AnchorPoint = Vector2.new(0, 1)
frame.Position = UDim2.new(0, 12, 1, -54)
frame.Size = UDim2.new(0, 230, 0, 300)
frame.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
frame.BorderSizePixel = 0
frame.Visible = false
frame.Parent = gui
do
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame
end

local header = Instance.new("TextLabel")
header.Size = UDim2.new(1, -16, 0, 28)
header.Position = UDim2.new(0, 8, 0, 6)
header.BackgroundTransparency = 1
header.Text = "Your Stuff"
header.TextColor3 = Color3.fromRGB(255, 255, 255)
header.Font = Enum.Font.GothamBold
header.TextSize = 18
header.TextXAlignment = Enum.TextXAlignment.Left
header.Parent = frame

local statsLabel = Instance.new("TextLabel")
statsLabel.Name = "Stats"
statsLabel.Size = UDim2.new(1, -16, 0, 20)
statsLabel.Position = UDim2.new(0, 8, 0, 34)
statsLabel.BackgroundTransparency = 1
statsLabel.Text = ""
statsLabel.TextColor3 = Color3.fromRGB(255, 220, 130)
statsLabel.Font = Enum.Font.GothamBold
statsLabel.TextSize = 14
statsLabel.TextXAlignment = Enum.TextXAlignment.Left
statsLabel.Parent = frame

local list = Instance.new("ScrollingFrame")
list.Size = UDim2.new(1, -16, 1, -70)
list.Position = UDim2.new(0, 8, 0, 60)
list.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
list.BorderSizePixel = 0
list.ScrollBarThickness = 4
list.CanvasSize = UDim2.new()
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.Parent = frame
do
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = list
end

-- // Logic ------------------------------------------------------------
local function refresh()
	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end

	local inv = player:FindFirstChild("Inventory")
	if inv then
		local ids = {}
		for _, v in ipairs(inv:GetChildren()) do
			if v:IsA("IntValue") and v.Value > 0 then
				table.insert(ids, v.Name)
			end
		end
		table.sort(ids)
		for _, id in ipairs(ids) do
			local row = Instance.new("TextLabel")
			row.Size = UDim2.new(1, -8, 0, 22)
			row.BackgroundColor3 = Color3.fromRGB(32, 32, 38)
			row.BorderSizePixel = 0
			row.Font = Enum.Font.Gotham
			row.TextSize = 13
			row.TextColor3 = Color3.fromRGB(235, 235, 235)
			row.Text = displayName(id) .. " x" .. inv[id].Value
			row.Parent = list
		end
		if #ids == 0 then
			local row = Instance.new("TextLabel")
			row.Size = UDim2.new(1, -8, 0, 22)
			row.BackgroundTransparency = 1
			row.Font = Enum.Font.Gotham
			row.TextSize = 13
			row.TextColor3 = Color3.fromRGB(150, 150, 160)
			row.Text = "Nothing yet - go shopping!"
			row.Parent = list
		end
	end

	local stats = player:FindFirstChild("leaderstats")
	local coins = stats and stats:FindFirstChild("Coins")
	local mood = player:GetAttribute("Mood") or 0
	statsLabel.Text = "Coins: " .. (coins and coins.Value or 0) .. "   Mood: " .. mood .. "/10"
end

local function hookInventory(inv)
	inv.ChildAdded:Connect(function(v)
		if v:IsA("IntValue") then
			v.Changed:Connect(refresh)
		end
		refresh()
	end)
	inv.ChildRemoved:Connect(refresh)
end

task.spawn(function()
	-- The Inventory folder is created by the server on join.
	for _ = 1, 50 do
		local inv = player:FindFirstChild("Inventory")
		if inv then
			hookInventory(inv)
			break
		end
		task.wait(0.2)
	end
	refresh()
end)

player:GetAttributeChangedSignal("Mood"):Connect(refresh)

task.spawn(function()
	for _ = 1, 50 do
		local stats = player:FindFirstChild("leaderstats")
		local coins = stats and stats:FindFirstChild("Coins")
		if coins then
			coins.Changed:Connect(refresh)
			break
		end
		task.wait(0.2)
	end
end)

local function setPanel(visible: boolean)
	frame.Visible = visible
	if visible then refresh() end
end

toggle.Activated:Connect(function()
	setPanel(not frame.Visible)
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.I then
		setPanel(not frame.Visible)
	end
end)

refresh()
