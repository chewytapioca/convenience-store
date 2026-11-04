local BasketModel = {}

local BODY = Color3.fromRGB(88, 170, 120)    -- Hana Mart green
local TRIM = Color3.fromRGB(255, 248, 235)   -- cream

-- { name, size, position relative to the basket base, color }
local PARTS = {
	{ "Base",   Vector3.new(1.6, 0.15, 1.1), Vector3.new(0, 0, 0),         BODY },
	{ "Front",  Vector3.new(1.6, 0.7, 0.1),  Vector3.new(0, 0.425, 0.5),   BODY },
	{ "Back",   Vector3.new(1.6, 0.7, 0.1),  Vector3.new(0, 0.425, -0.5),  BODY },
	{ "Left",   Vector3.new(0.1, 0.7, 0.9),  Vector3.new(-0.75, 0.425, 0), BODY },
	{ "Right",  Vector3.new(0.1, 0.7, 0.9),  Vector3.new(0.75, 0.425, 0),  BODY },
	{ "PostL",  Vector3.new(0.1, 0.45, 0.1), Vector3.new(-0.75, 1.0, 0),   TRIM },
	{ "PostR",  Vector3.new(0.1, 0.45, 0.1), Vector3.new(0.75, 1.0, 0),    TRIM },
	{ "Handle", Vector3.new(1.6, 0.1, 0.12), Vector3.new(0, 1.275, 0),     TRIM },
}

local function buildParts(): { [string]: Part }
	local parts = {}
	for _, def in PARTS do
		local p = Instance.new("Part")
		p.Name = def[1]
		p.Size = def[2]
		p.CFrame = CFrame.new(def[3])
		p.Color = def[4]
		p.Material = Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.CanCollide = false
		p.CanTouch = false
		p.Massless = true
		parts[def[1]] = p
	end
	return parts
end

-- Static basket for the stand (anchored, looks the same).
function BasketModel.makeDisplay(): Model
	local model = Instance.new("Model")
	model.Name = "DisplayBasket"
	local parts = buildParts()
	for _, p in parts do
		p.Anchored = true
		p.Parent = model
	end
	model.PrimaryPart = parts.Base
	return model
end

-- Holdable basket. The cream bar is the Handle, so the hand grips the bar
-- and the basket hangs below it.
function BasketModel.makeTool(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Basket"
	tool.ToolTip = "Shopping basket"
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	-- If it looks sideways or too high/low in the hand, tweak the Grip:
	--   tool.Grip = CFrame.new(0, 0.3, 0) * CFrame.Angles(0, math.rad(90), 0)
	tool.Grip = CFrame.new()

	local parts = buildParts()
	local handle = parts.Handle
	for name, p in parts do
		p.Parent = tool
		if name ~= "Handle" then
			local w = Instance.new("Weld")
			w.Part0 = handle
			w.Part1 = p
			w.C0 = handle.CFrame:ToObjectSpace(p.CFrame)
			w.Parent = p
		end
	end
	return tool
end

return BasketModel