local TweenService = game:GetService("TweenService")

local UITheme = {}

UITheme.Colors = {
	Cream     = Color3.fromRGB(255, 248, 235),
	CreamDark = Color3.fromRGB(240, 226, 202),
	Green     = Color3.fromRGB(88, 170, 120),
	GreenDark = Color3.fromRGB(52, 120, 82),
	Pink      = Color3.fromRGB(255, 170, 190),
	PinkDark  = Color3.fromRGB(214, 112, 140),
	Ink       = Color3.fromRGB(74, 56, 52),
	Muted     = Color3.fromRGB(150, 130, 120),
	Gold      = Color3.fromRGB(255, 200, 90),
	GoldDark  = Color3.fromRGB(200, 150, 50),
}

UITheme.TitleFont = Enum.Font.FredokaOne
UITheme.BodyFont = Enum.Font.Nunito

local function tween(inst: Instance, props: { [string]: any }, t: number?)
	TweenService:Create(inst, TweenInfo.new(t or 0.12, Enum.EasingStyle.Quad), props):Play()
end

function UITheme.round(inst: GuiObject, radius: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 14)
	c.Parent = inst
	return c
end

function UITheme.stroke(inst: GuiObject, color: Color3, thickness: number?)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness or 2.5
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = inst
	return s
end

function UITheme.pad(inst: Instance, px: number)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, px)
	p.PaddingBottom = UDim.new(0, px)
	p.PaddingLeft = UDim.new(0, px)
	p.PaddingRight = UDim.new(0, px)
	p.Parent = inst
	return p
end

-- Rounded cream panel with a sticker outline. Returns the Frame.
function UITheme.card(parent: Instance, size: UDim2, position: UDim2?): Frame
	local f = Instance.new("Frame")
	f.Size = size
	f.Position = position or UDim2.fromScale(0.5, 0.5)
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BackgroundColor3 = UITheme.Colors.Cream
	f.BorderSizePixel = 0
	f.Parent = parent
	UITheme.round(f, 18)
	UITheme.stroke(f, UITheme.Colors.GreenDark, 3)
	UITheme.pad(f, 12)
	return f
end

function UITheme.title(parent: Instance, text: string): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, 34)
	l.Text = text
	l.Font = UITheme.TitleFont
	l.TextSize = 26
	l.TextColor3 = UITheme.Colors.GreenDark
	l.Parent = parent
	return l
end

function UITheme.label(parent: Instance, text: string, size: number?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, (size or 18) + 8)
	l.Text = text
	l.Font = UITheme.BodyFont
	l.TextSize = size or 18
	l.TextColor3 = UITheme.Colors.Ink
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

-- Chunky pill button with hover and press animation.
function UITheme.button(parent: Instance, text: string, color: Color3?, dark: Color3?): TextButton
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.Size = UDim2.new(1, 0, 0, 46)
	b.Text = text
	b.Font = UITheme.TitleFont
	b.TextSize = 20
	b.TextColor3 = Color3.new(1, 1, 1)
	b.BackgroundColor3 = color or UITheme.Colors.Green
	b.Parent = parent
	UITheme.round(b, 23)
	UITheme.stroke(b, dark or UITheme.Colors.GreenDark, 3)

	local scale = Instance.new("UIScale")
	scale.Parent = b
	b.MouseEnter:Connect(function() tween(scale, { Scale = 1.04 }) end)
	b.MouseLeave:Connect(function() tween(scale, { Scale = 1 }) end)
	b.MouseButton1Down:Connect(function() tween(scale, { Scale = 0.95 }, 0.07) end)
	b.MouseButton1Up:Connect(function() tween(scale, { Scale = 1.04 }) end)
	return b
end

-- Small pill showing a value, e.g. "🪙 50".
function UITheme.pill(parent: Instance, text: string, color: Color3?, dark: Color3?): TextLabel
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(0, 120, 0, 38)
	l.BackgroundColor3 = color or UITheme.Colors.Gold
	l.Text = text
	l.Font = UITheme.TitleFont
	l.TextSize = 22
	l.TextColor3 = UITheme.Colors.Ink
	l.Parent = parent
	UITheme.round(l, 19)
	UITheme.stroke(l, dark or UITheme.Colors.GoldDark, 3)
	return l
end

-- Pop-in animation. Call after the card is created or shown.
function UITheme.popIn(frame: GuiObject)
	local s = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	s.Scale = 0.85
	s.Parent = frame
	TweenService:Create(s, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

return UITheme