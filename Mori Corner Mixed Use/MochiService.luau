local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Products = require(RS.Config.Products)
local ScanBeep = RS.Remotes.ScanBeep

local Mochi = {}

local function getMochi(): Model?
	return workspace:FindFirstChild("Mochi", true)
end

-- Rotate a CFrame about a world-space pivot point.
local function rotateAbout(cf: CFrame, pivot: Vector3, rot: CFrame): CFrame
	return CFrame.new(pivot) * rot * CFrame.new(-pivot) * cf
end

local function tweenParts(goals: { [BasePart]: CFrame }, duration: number)
	local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for part, goal in pairs(goals) do
		TweenService:Create(part, info, { CFrame = goal }):Play()
	end
	task.wait(duration)
end

-- Small screen above the counter showing the running total.
local function getRegisterLabel(): TextLabel?
	local counter = workspace:FindFirstChild("Checkout Counter", true)
	if not counter then return nil end
	local anchor = counter:IsA("BasePart") and counter or counter:FindFirstChildWhichIsA("BasePart", true)
	if not anchor then return nil end

	local gui = anchor:FindFirstChild("RegisterScreen")
	if not gui or not gui:IsA("BillboardGui") then
		gui = Instance.new("BillboardGui")
		gui.Name = "RegisterScreen"
		gui.Size = UDim2.new(0, 220, 0, 60)
		gui.StudsOffset = Vector3.new(0, 4, 0)
		gui.MaxDistance = 40
		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.Size = UDim2.new(1, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextSize = 20
		label.TextColor3 = Color3.fromRGB(140, 255, 170)
		label.TextStrokeTransparency = 0.5
		label.Text = ""
		label.Parent = gui
		gui.Parent = anchor
	end
	local label = gui:FindFirstChild("Label")
	if label and label:IsA("TextLabel") then
		return label
	end
	return nil
end

-- Plays the scanning sequence for one customer. Yields until done.
function Mochi.Serve(player: Player, basket: { [string]: number })
	local label = getRegisterLabel()

	local mochi = getMochi()
	local torso = mochi and mochi:FindFirstChild("Torso")
	local head = mochi and mochi:FindFirstChild("Head")
	local rightArm = mochi and mochi:FindFirstChild("RightArm")
	local leftArm = mochi and mochi:FindFirstChild("LeftArm")

	-- Remember the resting pose so every gesture can return to it.
	local restCF = {}
	for _, part in { torso, head, rightArm, leftArm } do
		if part then restCF[part] = part.CFrame end
	end

	-- Greet: raise the right arm in a wave
	if label then label.Text = "Irasshaimase!" end
	if rightArm and restCF[rightArm] then
		local shoulder = rightArm.Position + Vector3.new(0, rightArm.Size.Y / 2, 0)
		tweenParts({ [rightArm] = rotateAbout(restCF[rightArm], shoulder, CFrame.Angles(0, 0, math.rad(120))) }, 0.3)
		task.wait(0.4)
		tweenParts({ [rightArm] = restCF[rightArm] }, 0.3)
	else
		task.wait(0.5)
	end

	-- Scan each item: arm sweep, beep to the client, running total on screen
	local total = 0
	for productId, qty in basket do
		local product = Products[productId]
		if product then
			for _ = 1, qty do
				if rightArm and restCF[rightArm] then
					local shoulder = rightArm.Position + Vector3.new(0, rightArm.Size.Y / 2, 0)
					tweenParts({ [rightArm] = rotateAbout(rightArm.CFrame, shoulder, CFrame.Angles(math.rad(90), 0, 0)) }, 0.15)
					ScanBeep:FireClient(player, product.Name)
					total += product.Price
					if label then label.Text = string.format("Total: %d", total) end
					task.wait(0.2)
					tweenParts({ [rightArm] = restCF[rightArm] }, 0.15)
				else
					ScanBeep:FireClient(player, product.Name)
					total += product.Price
					if label then label.Text = string.format("Total: %d", total) end
					task.wait(0.45)
				end
			end
			end
		end

	-- Bow: tilt the upper body forward at the waist
	if torso and restCF[torso] then
		local waist = torso.Position - Vector3.new(0, torso.Size.Y / 2, 0)
		local bow = CFrame.Angles(math.rad(-20), 0, 0)
		local goals = {}
		for part in pairs(restCF) do
			goals[part] = rotateAbout(part.CFrame, waist, bow)
		end
		tweenParts(goals, 0.4)
		if label then label.Text = string.format("Arigato! Total: %d", total) end
		task.wait(0.6)
		tweenParts(restCF, 0.4)
	else
		if label then label.Text = string.format("Arigato! Total: %d", total) end
		task.wait(0.6)
	end

	if label then
		task.delay(3, function()
			if label.Text == string.format("Arigato! Total: %d", total) then
				label.Text = ""
			end
		end)
	end
end

local Chat = game:GetService("Chat")
local PlayersService = game:GetService("Players")

local GREET_RANGE = 10
local GREET_COOLDOWN = 20
local lastGreeted: { [Player]: number } = {}

local function waveOnce()
	local mochi = getMochi()
	local rightArm = mochi and mochi:FindFirstChild("RightArm")
	if not rightArm then return end
	local rest = rightArm.CFrame
	local shoulder = rightArm.Position + Vector3.new(0, rightArm.Size.Y / 2, 0)
	tweenParts({ [rightArm] = rotateAbout(rest, shoulder, CFrame.Angles(0, 0, math.rad(120))) }, 0.3)
	tweenParts({ [rightArm] = rest }, 0.3)
end

-- Greet players who walk up to the counter.
task.spawn(function()
	while true do
		task.wait(0.5)
		local mochi = getMochi()
		if mochi then
			local origin = mochi:GetPivot().Position
			for _, player in PlayersService:GetPlayers() do
				local char = player.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart")
				if hrp and (hrp.Position - origin).Magnitude <= GREET_RANGE then
					local now = os.clock()
					if not lastGreeted[player] or now - lastGreeted[player] > GREET_COOLDOWN then
						lastGreeted[player] = now
						local head = mochi:FindFirstChild("Head")
						if head then
							Chat:Chat(head, "Irasshaimase! Welcome!", Enum.ChatColor.White)
						end
						waveOnce()
					end
				end
			end
		end
	end
end)

PlayersService.PlayerRemoving:Connect(function(player)
	lastGreeted[player] = nil
end)

return Mochi
