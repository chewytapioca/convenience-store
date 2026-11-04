local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Products = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("Products"))
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local CheckoutRemote = remotes:WaitForChild("Checkout")
local ScanBeep = remotes:WaitForChild("ScanBeep")

local MAX_ITEMS = 10
local basket: { [string]: number } = {}

-- // Basket UI ---------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "BasketGui"
gui.ResetOnSpawn = false
gui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Name = "Basket"
frame.AnchorPoint = Vector2.new(1, 1)
frame.Position = UDim2.new(1, -12, 1, -12)
frame.Size = UDim2.new(0, 185, 0, 215)
frame.BackgroundColor3 = Color3.fromRGB(255, 224, 236)
frame.BorderSizePixel = 0
frame.Parent = gui
do
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 18)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Thickness = 3
	stroke.Parent = frame
end

local header = Instance.new("TextLabel")
header.Size = UDim2.new(1, -12, 0, 28)
header.Position = UDim2.new(0, 6, 0, 6)
header.BackgroundTransparency = 1
header.Text = "🧺 My Basket"
header.TextColor3 = Color3.fromRGB(255, 120, 168)
header.Font = Enum.Font.FredokaOne
header.TextSize = 16
header.Parent = frame

local list = Instance.new("ScrollingFrame")
list.Size = UDim2.new(1, -12, 1, -92)
list.Position = UDim2.new(0, 6, 0, 34)
list.BackgroundColor3 = Color3.fromRGB(255, 244, 249)
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
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = list
end

local totalLabel = Instance.new("TextLabel")
totalLabel.Size = UDim2.new(1, -12, 0, 18)
totalLabel.Position = UDim2.new(0, 6, 1, -76)
totalLabel.BackgroundTransparency = 1
totalLabel.Text = "♡ Total: 0 coins"
totalLabel.TextColor3 = Color3.fromRGB(255, 140, 175)
totalLabel.Font = Enum.Font.FredokaOne
totalLabel.TextSize = 13
totalLabel.TextXAlignment = Enum.TextXAlignment.Left
totalLabel.Parent = frame

local message = Instance.new("TextLabel")
message.Size = UDim2.new(1, -12, 0, 14)
message.Position = UDim2.new(0, 6, 1, -58)
message.BackgroundTransparency = 1
message.Text = ""
message.TextColor3 = Color3.fromRGB(190, 150, 170)
message.Font = Enum.Font.FredokaOne
message.TextSize = 11
message.TextXAlignment = Enum.TextXAlignment.Left
message.TextTruncate = Enum.TextTruncate.AtEnd
message.Parent = frame

local clearButton = Instance.new("TextButton")
clearButton.Size = UDim2.new(1, -12, 0, 30)
clearButton.Position = UDim2.new(0, 6, 1, -40)
clearButton.BackgroundColor3 = Color3.fromRGB(255, 240, 190)
clearButton.BorderSizePixel = 0
clearButton.Font = Enum.Font.FredokaOne
clearButton.TextSize = 13
clearButton.TextColor3 = Color3.fromRGB(235, 160, 120)
clearButton.Text = "Empty Basket 🧺"
clearButton.Parent = frame
do
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = clearButton
end

-- // Basket logic -------------------------------------------------------
local function countItems(): number
	local n = 0
	for _, qty in pairs(basket) do
		n += qty
	end
	return n
end

local function refresh()
	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	local total = 0
	local ids = {}
	for id in pairs(basket) do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local product = Products[id]
		if product then
			local qty = basket[id]
			total += product.Price * qty
			local row = Instance.new("TextLabel")
			row.Size = UDim2.new(1, -6, 0, 18)
			row.BackgroundColor3 = Color3.fromRGB(255, 232, 242)
			row.BorderSizePixel = 0
			row.Font = Enum.Font.FredokaOne
			row.TextSize = 11
			row.TextColor3 = Color3.fromRGB(170, 110, 140)
			row.Text = string.format("%s x%d - %d", product.Name, qty, product.Price * qty)
			row.Parent = list
		end
	end
	totalLabel.Text = "♡ Total: " .. total .. " coins"
end

local function showMessage(text: string)
	message.Text = text
	task.delay(2, function()
		if message.Text == text then
			message.Text = ""
		end
	end)
end

local function addItem(productId: string?)
	if not productId or not Products[productId] then return end
	if countItems() >= MAX_ITEMS then
		showMessage("Basket is full 🥺 (max " .. MAX_ITEMS .. " items).")
		return
	end
	basket[productId] = (basket[productId] or 0) + 1
	refresh()
end

-- Grab prompts on shelf items (existing and future)
local function hookItem(item: Instance)
	local prompt = item:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then return end
	prompt.Triggered:Connect(function(who: Player)
		if who == player then
			addItem(item:GetAttribute("ProductId"))
		end
	end)
end
for _, item in CollectionService:GetTagged("ShelfItem") do
	hookItem(item)
end
CollectionService:GetInstanceAddedSignal("ShelfItem"):Connect(hookItem)

clearButton.Activated:Connect(function()
	basket = {}
	refresh()
end)

local checkingOut = false
local function doCheckout()
	if checkingOut then return end
	if countItems() == 0 then
		showMessage("Your basket is empty 🥺")
		return
	end
	checkingOut = true
	showMessage("Mochi is scanning... ♡")
	local ok, result = CheckoutRemote:InvokeServer(basket)
	checkingOut = false
	if ok then
		basket = {}
		refresh()
		showMessage("Paid " .. tostring(result) .. " coins. Arigato! ♡")
	else
		showMessage(tostring(result))
	end
end

-- // Register area: prompt + only allow checkout near the counter ---
local function getCounter(): (BasePart?, Vector3?)
	local counter = workspace:FindFirstChild("Checkout Counter", true)
	if not counter then return nil, nil end
	if counter:IsA("BasePart") then
		return counter, counter.Position
	end
	local anchor = counter:FindFirstChildWhichIsA("BasePart", true)
	local pos
	if counter:IsA("Model") then
		local ok, cf = pcall(counter.GetBoundingBox, counter)
		if ok then pos = cf.Position end
	end
	return anchor, pos
end

local counterPart, counterPos = getCounter()

if counterPart then
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Checkout with Mochi ♡"
	prompt.ObjectText = "Register"
	prompt.HoldDuration = 0.2
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = counterPart
	prompt.Triggered:Connect(doCheckout)
end

-- Mochi's scanner beeps back to us during checkout
local beepSound = Instance.new("Sound")
beepSound.Name = "ScanBeepSound"
beepSound.SoundId = "rbxasset://sounds/electronicpingshort.wav"
beepSound.Volume = 0.6
beepSound.Parent = gui

ScanBeep.OnClientEvent:Connect(function(productName: string)
	showMessage("Scanned: " .. tostring(productName))
	beepSound:Play()
end)

refresh()
