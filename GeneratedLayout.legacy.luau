-- scene-generation compact geometry runtime. Generated source follows this prelude.
SG = {}

local EPS = 1e-5
local MIN_SIZE = 1e-3
local MAX_WARNINGS = 100
local SIZE_TOLERANCE = 0.05
local INSTALLER_NAME = "SceneGenerationInstaller"
-- Build-time channels live in ServerStorage as non-archivable instances, so a
-- saved place carries none of them. The warnings log is shared by the scene
-- and every Generator's copy of SG. The build marker exists while the scene
-- script runs. A host that reads the per-part markers after the build (the
-- z-fighting audit, glTF export) adds the trace marker to keep them, and the
-- export host adds the capture marker to record mesh placements instead.
local WARNINGS_LOG = "__SGWarnings"
local BUILD_MARKER = "__SGBuild"
local TRACE_MARKER = "__SGTrace"
local CAPTURE_MARKER = "__SGCaptureMeshes"
local MESH_PLACEMENT = "__SGMeshPlacement"
-- Per-part build markers. Each is removed when the scene finishes unless the
-- trace marker is present.
local ZF_SCOPE = "ZFScope"
local ZF_INDEX = "ZFIndex"
local GRADED_ATTRIBUTE = "Graded"
local ROAD_ATTRIBUTE = "Road"
local BUILD_ATTRIBUTES = { ZF_SCOPE, ZF_INDEX, GRADED_ATTRIBUTE, ROAD_ATTRIBUTE }
local S = {
	root = nil, parents = {}, xforms = { CFrame.identity }, palette = {},
	protos = {}, counts = {}, style = { nil, Enum.Material.SmoothPlastic, 0, true },
	lookByKey = {},
	assets = {}, assetTemplates = {}, assetFailures = {}, assetsLocked = false,
	meshPlacementCount = 0,
	warningSet = {}, logged = {},
	generators = {}, elements = {}, generatorsLocked = false,
	looks = nil, ownsLooks = false, generating = nil, intoWarnings = nil,
	provenance = {}, building = false, intoTrace = nil, bound = nil,
	zfBody = nil, zfModels = nil, zfBodyIndex = 0, zfSerial = 0,
	zfIndex = 0, zfScope = nil, zfActive = nil, liftActive = nil,
	lastCenter = nil, lastExtent = nil, sizeAsked = false, fitSize = nil,
	scopes = {}, shared = {}, wrapperNames = {}, protoBoxes = {}, instanceFolder = nil,
	gradeCols = {}, gradeProfiles = {}, gradePass = false, elementSources = {},
}

local function serverStorage()
	local ok, service = pcall(function() return game:GetService("ServerStorage") end)
	return ok and service or nil
end

local function marked(name)
	local storage = serverStorage()
	return storage ~= nil and storage:FindFirstChild(name) ~= nil
end

local function setMarker(name, present)
	local storage = serverStorage()
	if not storage then return end
	local found = storage:FindFirstChild(name)
	if present and not found then
		pcall(function()
			local marker = Instance.new("Folder")
			marker.Name = name
			marker.Archivable = false
			marker.Parent = storage
		end)
	elseif not present and found then
		found:Destroy()
	end
end

-- Whether parts carry their build markers. A generation decides once, in SG.into.
local function tracing()
	if S.generating and S.intoTrace ~= nil then return S.intoTrace end
	return S.building or marked(BUILD_MARKER) or marked(TRACE_MARKER)
end

local function warningLog(create)
	local storage = serverStorage()
	if not storage then return nil end
	local found = storage:FindFirstChild(WARNINGS_LOG)
	if found and found:IsA("StringValue") then return found end
	if not create then return nil end
	local made
	pcall(function()
		made = Instance.new("StringValue")
		made.Name = WARNINGS_LOG
		made.Archivable = false
		made.Parent = storage
	end)
	return made
end

local function logWarning(text)
	local log = warningLog(true)
	if not log then return end
	local value = log.Value
	if value == "" then
		log.Value = text
		return
	end
	if string.find("\n" .. value .. "\n", "\n" .. text .. "\n", 1, true) then return end
	local _, lines = string.gsub(value, "\n", "")
	if lines + 1 < MAX_WARNINGS then
		log.Value = value .. "\n" .. text
	elseif lines + 1 == MAX_WARNINGS then
		log.Value = value .. "\nSG: further warnings suppressed"
	end
end

-- A generation's warnings are logged together when it ends, so the same
-- warning from another generation of the same object is still recorded.
local function issue(api, message)
	local cleaned = (tostring(message):gsub("[\r\n]+", " "))
	local text = ("SG.%s: %s"):format(api, cleaned)
	if #text > 500 then text = text:sub(1, 497) .. "..." end
	if S.intoWarnings then table.insert(S.intoWarnings, text) end
	if S.warningSet[text] then return end
	S.warningSet[text] = true
	warn(text)
	if not S.intoWarnings then
		if #S.logged <= MAX_WARNINGS then table.insert(S.logged, text) end
		logWarning(text)
	end
end

local function num(api, value, label, fallback)
	local converted = type(value) == "number" and value or tonumber(value)
	if converted == nil or converted ~= converted or math.abs(converted) == math.huge then
		issue(api, ("%s must be a finite number; using %s"):format(label, fallback or 0))
		return fallback or 0
	end
	if converted ~= value then
		issue(api, ("%s converted to number %s"):format(label, converted))
	end
	return converted
end

local function pos(api, value, label)
	value = num(api, value, label)
	if value <= 0 then
		local corrected = math.max(math.abs(value), MIN_SIZE)
		issue(api, ("%s must be positive; using %s"):format(label, tostring(corrected)))
		value = corrected
	end
	return value
end

local function whole(api, value, label, zero)
	value = num(api, value, label)
	local minimum = zero and 0 or 1
	local rounded = math.max(minimum, math.floor(value + 0.5))
	if rounded ~= value then
		issue(api, ("%s must be an integer in range; using %d"):format(label, rounded))
	end
	return rounded
end

local function arr(api, value, stride)
	if type(value) ~= "table" then
		issue(api, "data must be a table; skipping call")
		return {}
	end
	local usable = #value - (#value % stride)
	if usable ~= #value then
		issue(api, ("data must be an array divisible by %d; ignoring %d trailing value(s)")
			:format(stride, #value - usable))
		local trimmed = {}
		for i = 1, usable do trimmed[i] = value[i] end
		return trimmed
	end
	return value
end

local function parent(api)
	local p = S.parents[#S.parents] or S.root
	if not p then
		issue(api, "call SG.scene first; creating an implicit Scene")
		p = SG.scene("Scene")
	end
	return p
end

-- Scenes with ProceduralModels keep their palette and keyed looks on
-- ReplicatedStorage.SceneGeneration.Looks, so a generator that regenerates
-- later in Studio, in a fresh copy of SG, still finds the scene's colours.
local LOOK_KEY = "^[%w_]+$"

local function lookStore()
	if S.looks and S.looks.Parent then return S.looks end
	local ok, found = pcall(function()
		local shared = game:GetService("ReplicatedStorage"):FindFirstChild("SceneGeneration")
		return shared and shared:FindFirstChild("Looks")
	end)
	S.looks = ok and found or nil
	return S.looks
end

local function persistLook(key)
	if not S.ownsLooks or S.generating or type(key) ~= "string"
		or not key:match(LOOK_KEY) or #key > 90 then
		return
	end
	local store = lookStore()
	if not store then return end
	if S.palette[key] then store:SetAttribute(key, S.palette[key]) end
	local rec = S.lookByKey[key]
	if rec then
		store:SetAttribute(key .. "__look", ("%s,%s,%s"):format(
			rec.material and rec.material.Name or "",
			rec.transparency == nil and "" or tostring(rec.transparency),
			rec.collision == nil and "" or tostring(rec.collision)))
	end
end

local function loadLook(key)
	if type(key) ~= "string" or S.palette[key] or not key:match(LOOK_KEY) then return end
	local store = lookStore()
	if not store then return end
	local stored = store:GetAttribute(key)
	if typeof(stored) ~= "Color3" then return end
	S.palette[key] = stored
	local look = store:GetAttribute(key .. "__look")
	if type(look) == "string" and not S.lookByKey[key] then
		local material, transparency, collision = look:match("^([^,]*),([^,]*),([^,]*)$")
		local rec = {}
		if material and material ~= "" then
			local ok, item = pcall(function() return Enum.Material[material] end)
			if ok then rec.material = item end
		end
		rec.transparency = tonumber(transparency)
		if collision == "true" then rec.collision = true elseif collision == "false" then rec.collision = false end
		S.lookByKey[key] = rec
	end
end

local function color(api, key)
	key = key == nil and S.style[1] or key
	if key == nil then return Color3.fromRGB(163, 162, 165) end
	if typeof(key) == "Color3" then return key end
	loadLook(key)
	if type(key) ~= "string" or not S.palette[key] then
		issue(api, ("unknown palette key %q; using grey"):format(tostring(key)))
		return Color3.fromRGB(163, 162, 165)
	end
	return S.palette[key]
end

local function localCF(api, value)
	if value == nil then return CFrame.identity end
	if typeof(value) == "Vector3" then return CFrame.new(value) end
	if typeof(value) ~= "CFrame" then
		issue(api, "transform must be CFrame or Vector3; using identity")
		return CFrame.identity
	end
	return value
end

local function nextName(holder, kind)
	local counts = S.counts[holder]
	if not counts then
		counts = {}
		S.counts[holder] = counts
	end
	counts[kind] = (counts[kind] or 0) + 1
	return ("%s_%03d"):format(kind, counts[kind])
end

local function zfNumbers(row, key)
	local value = type(row) == "table" and row[key] or nil
	if type(value) ~= "table" then return nil end
	return tonumber(value[1]) or 0, tonumber(value[2]) or 0, tonumber(value[3]) or 0
end

-- Repairs for the generation in progress come from its wrapper Generator (see
-- SG.bind). Body repairs live on this script. Either way the part grows along
-- its own axes.
local function zfAdjust(size, cf, index)
	local bucket = S.generating and S.zfActive or S.zfBody
	local row = type(bucket) == "table" and (bucket[tostring(index)] or bucket[index]) or nil
	local sx, sy, sz = zfNumbers(row, "size")
	local ox, oy, oz = zfNumbers(row, "offset")
	if sx then
		size = Vector3.new(
			math.max(math.abs(size.X + sx), MIN_SIZE),
			math.max(math.abs(size.Y + sy), MIN_SIZE),
			math.max(math.abs(size.Z + sz), MIN_SIZE))
	end
	if ox then cf = cf * CFrame.new(ox, oy, oz) end
	return size, cf
end

-- Remember which generated model this is, and return the repairs its parts
-- apply when it generates. The serial follows creation order, so the same
-- scene source addresses the same model on every run.
local function bindZFight(instance)
	S.zfSerial += 1
	local scope = "m" .. tostring(S.zfSerial)
	S.scopes[instance] = scope
	local repairs = S.zfModels and S.zfModels[scope]
	return scope, type(repairs) == "table" and repairs or nil
end

-- A generation's parts know their creation index but not which model they
-- belong to, so the scene labels them once the model has generated.
local function labelScope(model)
	local scope = S.scopes[model]
	if not scope or not tracing() then return end
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("BasePart") and item:GetAttribute(ZF_INDEX) ~= nil then
			item:SetAttribute(ZF_SCOPE, scope)
		end
	end
end

local function make(api, kind, className, size, cf, key)
	if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
		issue(api, "size must be positive; clamping invalid axes")
		size = Vector3.new(
			math.max(math.abs(size.X), MIN_SIZE),
			math.max(math.abs(size.Y), MIN_SIZE),
			math.max(math.abs(size.Z), MIN_SIZE))
	end
	local holder = parent(api)
	local p = Instance.new(className)
	local material, transparency, collision = S.style[2], S.style[3], S.style[4]
	-- A palette key on a primitive uses that key's remembered look when one
	-- was set with SG.style. Colour always comes from the key; material,
	-- transparency, and collision stay on the current defaults only if the
	-- key was never styled.
	if type(key) == "string" then
		loadLook(key)
		local rec = S.lookByKey[key]
		if rec then
			if rec.material then material = rec.material end
			transparency = rec.transparency or 0
			collision = rec.collision == nil and true or rec.collision
		end
	end
	p.Name, p.Anchored, p.CanCollide, p.CastShadow = nextName(holder, kind), true, collision, true
	p.Material, p.Transparency, p.Color = material, transparency, color(api, key)
	local index, scope
	if S.generating then
		S.zfIndex += 1
		index, scope = S.zfIndex, S.zfScope
	else
		S.zfBodyIndex += 1
		index, scope = S.zfBodyIndex, "body"
	end
	local world = S.xforms[#S.xforms] * localCF(api, cf)
	size, world = zfAdjust(size, world, index)
	if S.generating and type(S.liftActive) == "table" then
		local delta = S.liftActive[tostring(index)]
		if type(delta) ~= "number" then delta = tonumber(delta) end
		if type(delta) == "number" and delta ~= 0 then
			world = world + Vector3.new(0, delta, 0)
		end
	end
	p.Size, p.CFrame, p.Parent = size, world, holder
	if tracing() then
		pcall(p.SetAttribute, p, ZF_INDEX, index)
		-- A generated part with no scope shares no repair slot. Stamping the
		-- fallback name "model" on every generator collapsed their indices together.
		if type(scope) == "string" and scope ~= "" then pcall(p.SetAttribute, p, ZF_SCOPE, scope) end
	end
	return p
end

-- Baked coplanar-face shifts. `payload` is JSON: body parts keyed by creation
-- index, and one table per generated model keyed by the serial bindZFight assigns.
function SG.zFight(payload)
	if type(payload) ~= "string" then
		issue("zFight", "repairs must be a JSON string; ignoring them")
		return nil
	end
	local ok, data = pcall(function()
		return game:GetService("HttpService"):JSONDecode(payload)
	end)
	if not ok or type(data) ~= "table" then
		issue("zFight", "repairs are not valid JSON; ignoring them")
		return nil
	end
	S.zfBody = type(data.body) == "table" and data.body or nil
	S.zfModels = type(data.models) == "table" and data.models or nil
	return nil
end

local function scoped(api, name, cf, build)
	if type(name) ~= "string" or name == "" then
		issue(api, "name must be a non-empty string; using Object")
		name = "Object"
	end
	if type(cf) == "function" and build == nil then build, cf = cf, nil end
	if type(build) ~= "function" then
		issue(api, "build must be a function; skipping group")
		return nil
	end
	local model = Instance.new("Model")
	model.Name, model.Parent = name, parent(api)
	local saved = { S.style[1], S.style[2], S.style[3], S.style[4] }
	-- put starts opaque and collidable; g/o keep the caller's style.
	-- All three restore style when the callback returns.
	if api == "put" then
		S.style[3], S.style[4] = 0, true
	end
	table.insert(S.parents, model)
	table.insert(S.xforms, S.xforms[#S.xforms] * localCF(api, cf))
	local ok, result = pcall(build, model)
	table.remove(S.xforms)
	table.remove(S.parents)
	S.style[1], S.style[2], S.style[3], S.style[4] = saved[1], saved[2], saved[3], saved[4]
	if not ok then issue(api, "build stopped early: " .. tostring(result)) end
	return model
end

function SG.scene(name, into)
	name, into = name or "Scene", into or workspace
	if type(name) ~= "string" or name == "" then
		issue("scene", "invalid name; using Scene")
		name = "Scene"
	end
	if typeof(into) ~= "Instance" then
		issue("scene", "parent must be an Instance; using workspace")
		into = workspace
	end
	if S.root then S.root:Destroy() end
	local old = into:FindFirstChild(name)
	if old then old:Destroy() end
	S.parents, S.xforms, S.palette, S.protos, S.counts = {}, { CFrame.identity }, {}, {}, {}
	S.lookByKey = {}
	S.meshPlacementCount = 0
	S.zfBodyIndex, S.zfSerial = 0, 0
	S.scopes, S.shared, S.wrapperNames, S.protoBoxes = {}, {}, {}, {}
	S.gradeCols, S.gradeProfiles = {}, {}
	S.style = { nil, Enum.Material.SmoothPlastic, 0, true }
	S.building = true
	setMarker(BUILD_MARKER, true)
	-- The log starts with this scene: the prelude's warnings, then its own.
	local log = warningLog(true)
	if log then log.Value = "" end
	for _, text in ipairs(S.logged) do logWarning(text) end
	local root = Instance.new("Folder")
	root.Name, root.Parent, S.root = name, into, root
	return root
end

-- Reserved for the trusted prelude: how the scene was generated (Quality,
-- Source). The prelude line is the record; revisions read it back from there.
function SG.provenance(data)
	if type(data) ~= "table" then
		issue("provenance", "provenance must be a table")
		return nil
	end
	for field, value in pairs(data) do
		if type(field) == "string" and (type(value) == "string" or type(value) == "number") then
			S.provenance[field] = value
		end
	end
	return nil
end

function SG.palette(data)
	data = arr("palette", data, 4)
	for i = 1, #data, 4 do
		local key = data[i]
		if type(key) ~= "string" or key == "" then
			issue("palette", ("invalid key at entry %d; skipping color"):format((i + 3) / 4))
		else
			local r = math.clamp(math.floor(num("palette", data[i + 1], "r") + 0.5), 0, 255)
			local g = math.clamp(math.floor(num("palette", data[i + 2], "g") + 0.5), 0, 255)
			local b = math.clamp(math.floor(num("palette", data[i + 3], "b") + 0.5), 0, 255)
			S.palette[key] = Color3.fromRGB(r, g, b)
			persistLook(key)
		end
	end
end

-- A material may be given as an Enum.Material or, more compactly, as its name:
-- "Wood" instead of Enum.Material.Wood. The name lookup is case-insensitive and
-- built once from the live enum, so it tracks whatever materials the engine has.
local materialByName
local function resolveMaterial(api, value)
	if typeof(value) == "EnumItem" and value.EnumType == Enum.Material then
		return value
	end
	if type(value) == "string" then
		if not materialByName then
			materialByName = {}
			for _, item in ipairs(Enum.Material:GetEnumItems()) do
				materialByName[item.Name:lower()] = item
			end
		end
		local item = materialByName[value:lower()]
		if item then return item end
		issue(api, ("unknown material %q; keeping current material"):format(value))
		return nil
	end
	issue(api, "material must be an Enum.Material or a material name; keeping current material")
	return nil
end

function SG.style(key, material, transparency, collision)
	if key ~= nil then
		color("style", key)
		S.style[1] = key
	end
	-- A palette key remembers the whole look it was styled with -- material,
	-- transparency, and collision -- so a later bare SG.style(key) or passing
	-- that key on a primitive restores all three. Transparency and collision
	-- are recorded per key, not left on the global style, so setting a
	-- translucent key does not bleed onto the opaque objects styled after it.
	local rec
	if type(key) == "string" then
		rec = S.lookByKey[key]
		if not rec then rec = {}; S.lookByKey[key] = rec end
	end
	if material ~= nil then
		local resolved = resolveMaterial("style", material)
		if resolved then
			S.style[2] = resolved
			if rec then rec.material = resolved end
		end
	elseif rec and rec.material then
		S.style[2] = rec.material
	end
	-- A boolean in the transparency slot is a collision shorthand: it sets
	-- collision and leaves the object opaque.
	if type(transparency) == "boolean" then
		if collision == nil then collision = transparency end
		transparency = 0
	end
	if transparency ~= nil then
		local t = math.clamp(num("style", transparency, "transparency"), 0, 1)
		S.style[3] = t
		if rec then rec.transparency = t end
	elseif rec then
		S.style[3] = rec.transparency or 0
	end
	if collision ~= nil then
		if type(collision) ~= "boolean" then
			issue("style", "collision must be boolean; keeping current collision")
		else
			S.style[4] = collision
			if rec then rec.collision = collision end
		end
	elseif rec then
		S.style[4] = rec.collision == nil and true or rec.collision
	end
	if rec then persistLook(key) end
end

function SG.cframe(x, y, z, rx, ry, rz)
	return CFrame.new(num("cframe", x or 0, "x"), num("cframe", y or 0, "y"), num("cframe", z or 0, "z"))
		* CFrame.Angles(
			math.rad(num("cframe", rx or 0, "rx")),
			math.rad(num("cframe", ry or 0, "ry")),
			math.rad(num("cframe", rz or 0, "rz")))
end

-- A position without rotation, for the common case. Shorter than SG.cframe and
-- says outright that only a location is meant.
function SG.pos(x, y, z)
	return CFrame.new(num("pos", x or 0, "x"), num("pos", y or 0, "y"), num("pos", z or 0, "z"))
end

function SG.group(name, cf, build) return scoped("group", name, cf, build) end

function SG.transform(cf, build)
	if type(build) ~= "function" then
		issue("transform", "build must be a function; skipping transform")
		return nil
	end
	table.insert(S.xforms, S.xforms[#S.xforms] * localCF("transform", cf))
	local ok, result = pcall(build)
	table.remove(S.xforms)
	if not ok then
		issue("transform", "build stopped early: " .. tostring(result))
		return nil
	end
	return result
end

function SG.box(sx, sy, sz, cf, key)
	return make("box", "Box", "Part",
		Vector3.new(pos("box", sx, "sx"), pos("box", sy, "sy"), pos("box", sz, "sz")), cf, key)
end

function SG.sphere(d, cf, key)
	d = pos("sphere", d, "diameter")
	local p = make("sphere", "Sphere", "Part", Vector3.new(d, d, d), cf, key)
	p.Shape = Enum.PartType.Ball
	return p
end

function SG.disc(r, h, cf, key)
	r, h = pos("disc", r, "radius"), pos("disc", h or 0.1, "thickness")
	local p = make("disc", "Disc", "Part", Vector3.new(h, r * 2, r * 2),
		localCF("disc", cf) * CFrame.Angles(0, 0, math.pi / 2), key)
	p.Shape = Enum.PartType.Cylinder
	return p
end

function SG.segment(ax, ay, az, bx, by, bz, width, key, round)
	local a = Vector3.new(num("segment", ax, "ax"), num("segment", ay, "ay"), num("segment", az, "az"))
	local b = Vector3.new(num("segment", bx, "bx"), num("segment", by, "by"), num("segment", bz, "bz"))
	local length, mid = (b - a).Magnitude, (a + b) / 2
	if length <= EPS then
		issue("segment", "endpoints must be distinct; skipping segment")
		return nil
	end
	width = pos("segment", width or 0.2, "width")
	local cf = CFrame.lookAt(mid, b)
	if round then
		local p = make("segment", "Segment", "Part", Vector3.new(length, width, width),
			cf * CFrame.Angles(0, math.pi / 2, 0), key)
		p.Shape = Enum.PartType.Cylinder
		return p
	end
	return make("segment", "Segment", "Part", Vector3.new(width, width, length), cf, key)
end

local function triangle(api, a, b, c, thickness, key)
	local ab, ac, bc = b - a, c - a, c - b
	if ab:Dot(ab) > ac:Dot(ac) and ab:Dot(ab) > bc:Dot(bc) then
		a, b, c = c, a, b
	elseif ac:Dot(ac) > ab:Dot(ab) and ac:Dot(ac) > bc:Dot(bc) then
		a, b, c = b, c, a
	end
	ab, ac, bc = b - a, c - a, c - b
	if bc.Magnitude <= EPS or ac:Cross(ab).Magnitude <= EPS then
		issue(api, "triangle must be non-degenerate; skipping triangle")
		return {}
	end
	local right, back = ac:Cross(ab).Unit, bc.Unit
	local up, height, made = bc:Cross(right).Unit, math.abs(ab:Dot(bc:Cross(right).Unit)), {}
	local function one(mid, xAxis, zAxis, run)
		if run > EPS then
			table.insert(made, make(api, "Triangle", "WedgePart",
				Vector3.new(thickness, height, run), CFrame.fromMatrix(mid, xAxis, up, zAxis), key))
		end
	end
	one((a + b) / 2, right, back, math.abs(ab:Dot(back)))
	one((a + c) / 2, -right, -back, math.abs(ac:Dot(back)))
	return made
end

function SG.triangle(ax, ay, az, bx, by, bz, cx, cy, cz, w, key)
	return triangle("triangle",
		Vector3.new(num("triangle", ax, "ax"), num("triangle", ay, "ay"), num("triangle", az, "az")),
		Vector3.new(num("triangle", bx, "bx"), num("triangle", by, "by"), num("triangle", bz, "bz")),
		Vector3.new(num("triangle", cx, "cx"), num("triangle", cy, "cy"), num("triangle", cz, "cz")),
		pos("triangle", w or 0.05, "thickness"), key)
end

function SG.quad(ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, w, key)
	local a = Vector3.new(num("quad", ax, "ax"), num("quad", ay, "ay"), num("quad", az, "az"))
	local b = Vector3.new(num("quad", bx, "bx"), num("quad", by, "by"), num("quad", bz, "bz"))
	local c = Vector3.new(num("quad", cx, "cx"), num("quad", cy, "cy"), num("quad", cz, "cz"))
	local d = Vector3.new(num("quad", dx, "dx"), num("quad", dy, "dy"), num("quad", dz, "dz"))
	w = pos("quad", w or 0.05, "thickness")
	return { triangle("quad", a, b, c, w, key), triangle("quad", a, c, d, w, key) }
end

function SG.frustum(r1, r2, h, sides, cf, key)
	r1, r2, h = pos("frustum", r1, "bottom radius"), num("frustum", r2, "top radius"), pos("frustum", h, "height")
	if r2 < 0 then
		issue("frustum", "top radius must be non-negative; using 0")
		r2 = 0
	end
	sides = whole("frustum", sides or 8, "sides")
	if sides < 3 then
		issue("frustum", "sides must be at least 3; using 3")
		sides = 3
	end
	local made = {}
	local function face(a, b, c)
		for _, part in ipairs(triangle("frustum", a, b, c, 0.05, key)) do made[#made + 1] = part end
	end
	SG.transform(cf or CFrame.identity, function()
		local lo, hi = {}, {}
		for i = 0, sides - 1 do
			local angle = i * math.pi * 2 / sides
			lo[i + 1] = Vector3.new(math.cos(angle) * r1, -h / 2, math.sin(angle) * r1)
			hi[i + 1] = Vector3.new(math.cos(angle) * r2, h / 2, math.sin(angle) * r2)
		end
		for i = 1, sides do
			local j = i % sides + 1
			if r2 <= EPS then
				face(lo[i], lo[j], Vector3.new(0, h / 2, 0))
			else
				face(lo[i], lo[j], hi[j])
				face(lo[i], hi[j], hi[i])
			end
			face(Vector3.new(0, -h / 2, 0), lo[j], lo[i])
			if r2 > EPS then
				face(Vector3.new(0, h / 2, 0), hi[i], hi[j])
			end
		end
	end)
	return made
end

function SG.roundedSlab(sx, sy, sz, radius, cf, key)
	sx, sy, sz, radius = pos("roundedSlab", sx, "sx"), pos("roundedSlab", sy, "sy"),
		pos("roundedSlab", sz, "sz"), pos("roundedSlab", radius, "radius")
	radius = math.min(radius, math.min(sx, sz) * 0.499)
	local made = {}
	SG.transform(cf or CFrame.identity, function()
		if sz - 2 * radius > EPS then made[#made + 1] = SG.box(sx, sy, sz - 2 * radius, nil, key) end
		if sx - 2 * radius > EPS then made[#made + 1] = SG.box(sx - 2 * radius, sy, sz, nil, key) end
		for _, x in ipairs({ -1, 1 }) do
			for _, z in ipairs({ -1, 1 }) do
				made[#made + 1] = SG.disc(radius, sy, SG.cframe(x * (sx / 2 - radius), 0, z * (sz / 2 - radius)), key)
			end
		end
	end)
	return made
end

-- Block lettering on a 5 x 7 grid, top row first.
local GLYPH_ROWS = {
	A = { " ### ", "#   #", "#   #", "#####", "#   #", "#   #", "#   #" },
	B = { "#### ", "#   #", "#   #", "#### ", "#   #", "#   #", "#### " },
	C = { " ### ", "#   #", "#    ", "#    ", "#    ", "#   #", " ### " },
	D = { "#### ", "#   #", "#   #", "#   #", "#   #", "#   #", "#### " },
	E = { "#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####" },
	F = { "#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#    " },
	G = { " ### ", "#   #", "#    ", "# ###", "#   #", "#   #", " ### " },
	H = { "#   #", "#   #", "#   #", "#####", "#   #", "#   #", "#   #" },
	I = { "#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "#####" },
	J = { "  ###", "   # ", "   # ", "   # ", "   # ", "#  # ", " ##  " },
	K = { "#   #", "#  # ", "# #  ", "##   ", "# #  ", "#  # ", "#   #" },
	L = { "#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####" },
	M = { "#   #", "## ##", "# # #", "# # #", "#   #", "#   #", "#   #" },
	N = { "#   #", "##  #", "# # #", "#  ##", "#   #", "#   #", "#   #" },
	O = { " ### ", "#   #", "#   #", "#   #", "#   #", "#   #", " ### " },
	P = { "#### ", "#   #", "#   #", "#### ", "#    ", "#    ", "#    " },
	Q = { " ### ", "#   #", "#   #", "#   #", "# # #", "#  # ", " ## #" },
	R = { "#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #" },
	S = { " ####", "#    ", "#    ", " ### ", "    #", "    #", "#### " },
	T = { "#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  " },
	U = { "#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### " },
	V = { "#   #", "#   #", "#   #", "#   #", "#   #", " # # ", "  #  " },
	W = { "#   #", "#   #", "#   #", "# # #", "# # #", "## ##", "#   #" },
	X = { "#   #", "#   #", " # # ", "  #  ", " # # ", "#   #", "#   #" },
	Y = { "#   #", "#   #", " # # ", "  #  ", "  #  ", "  #  ", "  #  " },
	Z = { "#####", "    #", "   # ", "  #  ", " #   ", "#    ", "#####" },
	["0"] = { " ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### " },
	["1"] = { "  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### " },
	["2"] = { " ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####" },
	["3"] = { "#### ", "    #", "    #", " ### ", "    #", "    #", "#### " },
	["4"] = { "   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # " },
	["5"] = { "#####", "#    ", "#### ", "    #", "    #", "#   #", " ### " },
	["6"] = { " ### ", "#    ", "#    ", "#### ", "#   #", "#   #", " ### " },
	["7"] = { "#####", "    #", "   # ", "  #  ", "  #  ", "  #  ", "  #  " },
	["8"] = { " ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### " },
	["9"] = { " ### ", "#   #", "#   #", " ####", "    #", "    #", " ### " },
	["-"] = { "     ", "     ", "     ", "#####", "     ", "     ", "     " },
	["+"] = { "     ", "  #  ", "  #  ", "#####", "  #  ", "  #  ", "     " },
	["."] = { "     ", "     ", "     ", "     ", "     ", "     ", "  #  " },
	[","] = { "     ", "     ", "     ", "     ", "     ", "  #  ", " #   " },
	[":"] = { "     ", "  #  ", "     ", "     ", "     ", "  #  ", "     " },
	["!"] = { "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "     ", "  #  " },
	["?"] = { " ### ", "#   #", "    #", "   # ", "  #  ", "     ", "  #  " },
	["'"] = { "  #  ", "  #  ", "     ", "     ", "     ", "     ", "     " },
	["/"] = { "    #", "    #", "   # ", "  #  ", " #   ", "#    ", "#    " },
	["&"] = { " ##  ", "#  # ", "# #  ", " #   ", "# # #", "#  # ", " ## #" },
}
local GLYPH_COLUMNS, GLYPH_LINES, GLYPH_ADVANCE, MAX_TEXT = 5, 7, 6, 40
local glyphRects = {}

-- Cover a glyph's cells with as few rectangles as a greedy scan finds, so a
-- letter costs a handful of parts rather than one per cell.
local function rectsFor(char)
	local cached = glyphRects[char]
	if cached then return cached end
	local rows = GLYPH_ROWS[char]
	if not rows then return nil end
	local filled, used, rects = {}, {}, {}
	for r = 1, GLYPH_LINES do
		filled[r], used[r] = {}, {}
		for c = 1, GLYPH_COLUMNS do filled[r][c] = rows[r]:sub(c, c) == "#" end
	end
	for r = 1, GLYPH_LINES do
		for c = 1, GLYPH_COLUMNS do
			if filled[r][c] and not used[r][c] then
				local w = 1
				while c + w <= GLYPH_COLUMNS and filled[r][c + w] and not used[r][c + w] do w += 1 end
				local h = 1
				while r + h <= GLYPH_LINES do
					local full = true
					for k = c, c + w - 1 do
						if not filled[r + h][k] or used[r + h][k] then full = false; break end
					end
					if not full then break end
					h += 1
				end
				for rr = r, r + h - 1 do
					for k = c, c + w - 1 do used[rr][k] = true end
				end
				rects[#rects + 1] = { c - 1, r - 1, w, h }
			end
		end
	end
	glyphRects[char] = rects
	return rects
end

-- Block letters centred on cf in its local XY plane, `height` studs tall and
-- `depth` thick along Z. They read left to right from cf's -Z side, the side a
-- front faces, so a sign on a -Z front needs no rotation. maxWidth shrinks the
-- letters to fit. Returns the lettering's width in studs.
function SG.text(text, cf, height, key, maxWidth, depth)
	text = tostring(text or ""):upper()
	if #text > MAX_TEXT then
		issue("text", ("text longer than %d characters; truncating"):format(MAX_TEXT))
		text = text:sub(1, MAX_TEXT)
	end
	height = pos("text", height, "height")
	local count = #text
	if count == 0 then return 0 end
	local cells = count * GLYPH_ADVANCE - 1
	local cell = height / GLYPH_LINES
	if maxWidth ~= nil then
		maxWidth = pos("text", maxWidth, "maxWidth")
		cell = math.min(cell, maxWidth / cells)
	end
	depth = depth ~= nil and pos("text", depth, "depth") or cell
	local width, tall = cells * cell, GLYPH_LINES * cell
	local frame = localCF("text", cf)
	for i = 1, count do
		local char = text:sub(i, i)
		local rects = char ~= " " and rectsFor(char)
		if char ~= " " and not rects then
			issue("text", ("no glyph for %q; leaving a gap"):format(char))
		end
		local start = (i - 1) * GLYPH_ADVANCE
		for _, rect in ipairs(rects or {}) do
			local u = start + rect[1] + rect[3] / 2
			local v = rect[2] + rect[4] / 2
			make("text", "Letter", "Part", Vector3.new(rect[3] * cell, rect[4] * cell, depth),
				frame * CFrame.new(width / 2 - u * cell, tall / 2 - v * cell, 0), key)
		end
	end
	return width
end

-- Lights and effects sit on a small invisible holder part at cf, so they work
-- the same in scene code and inside a generator, where regeneration rebuilds
-- them with the rest of the object.
local LIGHT_COLOR = Color3.fromRGB(255, 214, 160)
local LIGHT_CLASSES = { point = "PointLight", spot = "SpotLight", surface = "SurfaceLight" }
local PARTICLE_TEXTURES = {
	sparkle = "rbxasset://textures/particles/sparkles_main.dds",
	smoke = "rbxasset://textures/particles/smoke_main.dds",
	fire = "rbxasset://textures/particles/fire_main.dds",
}
-- texture, colour, size, transparency, lifetime, rate, speed, spread, rise, light emission
local PARTICLE_PRESETS = {
	embers = { "sparkle", Color3.fromRGB(255, 140, 40), 0.25, 0.1, 2.5, 12, 3, 25, 2, 1 },
	steam = { "smoke", Color3.fromRGB(235, 235, 240), 1.5, 0.6, 3, 6, 2, 15, 1.5, 0 },
	mist = { "smoke", Color3.fromRGB(210, 220, 230), 4, 0.8, 6, 3, 0.4, 180, 0, 0 },
	dust = { "sparkle", Color3.fromRGB(230, 215, 180), 0.12, 0.3, 5, 8, 0.3, 180, 0, 0 },
	magic = { "sparkle", Color3.fromRGB(150, 120, 255), 0.4, 0.1, 2, 14, 1.5, 180, 0.5, 1 },
	flame = { "fire", Color3.fromRGB(255, 150, 50), 1.2, 0.2, 0.8, 20, 3, 10, 2, 1 },
}

local function fxColor(api, value, fallback)
	if value == nil then return fallback end
	if type(value) == "table" and #value == 3 then
		return Color3.fromRGB(
			math.clamp(num(api, value[1], "r"), 0, 255),
			math.clamp(num(api, value[2], "g"), 0, 255),
			math.clamp(num(api, value[3], "b"), 0, 255))
	end
	return color(api, value)
end

local function fxHolder(api, kind, cf, size)
	local holder = parent(api)
	local p = Instance.new("Part")
	p.Name, p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery = nextName(holder, kind), true, false, false, false
	p.CastShadow, p.Transparency, p.Size = false, 1, size
	p.CFrame, p.Parent = S.xforms[#S.xforms] * localCF(api, cf), holder
	return p
end

local function optTable(api, opts)
	if opts == nil then return {} end
	if type(opts) ~= "table" then
		issue(api, "options must be a table; ignoring them")
		return {}
	end
	return opts
end

-- A light at cf. kind is "point" (all around), "spot" (a cone along cf's -Z,
-- the way a front faces), or "surface" (a panel facing cf's -Z). Shadows are
-- off unless opts.shadows is true. opts.angle sets the spot or surface spread.
function SG.light(kind, cf, colorKey, range, brightness, opts)
	kind = kind or "point"
	local className = LIGHT_CLASSES[kind]
	if not className then
		issue("light", ("unknown light kind %q; using point"):format(tostring(kind)))
		kind, className = "point", "PointLight"
	end
	opts = optTable("light", opts)
	range = math.clamp(range ~= nil and pos("light", range, "range") or 16, 1, 60)
	brightness = math.clamp(brightness ~= nil and num("light", brightness, "brightness") or 1, 0, 10)
	local holder = fxHolder("light", "Light", cf, Vector3.new(0.2, 0.2, 0.2))
	local light = Instance.new(className)
	light.Color, light.Range, light.Brightness = fxColor("light", colorKey, LIGHT_COLOR), range, brightness
	light.Shadows = opts.shadows == true
	if kind ~= "point" then
		light.Face = Enum.NormalId.Front
		if opts.angle ~= nil then
			light.Angle = math.clamp(num("light", opts.angle, "angle"), 0, 180)
		end
	end
	light.Parent = holder
	return light
end

-- A fire, smoke, sparkle, or particle effect at cf. size is the effect's scale
-- in studs: flame height for fire and smoke, emitter width for particles.
-- Particle kinds: embers, steam, mist, dust, magic, flame. opts: color,
-- secondary (fire), rate (particles), opacity (smoke).
function SG.effect(kind, cf, size, opts)
	opts = optTable("effect", opts)
	local preset = PARTICLE_PRESETS[kind]
	if kind ~= "fire" and kind ~= "smoke" and kind ~= "sparkles" and not preset then
		issue("effect", ("unknown effect kind %q; skipping"):format(tostring(kind)))
		return nil
	end
	size = math.clamp(size ~= nil and pos("effect", size, "size") or 2, 0.2, 30)
	local effect
	if preset then
		local holder = fxHolder("effect", "Effect", cf, Vector3.new(size, 0.2, size))
		effect = Instance.new("ParticleEmitter")
		effect.Texture = PARTICLE_TEXTURES[preset[1]]
		effect.Color = ColorSequence.new(fxColor("effect", opts.color, preset[2]))
		effect.Size = NumberSequence.new(preset[3], preset[3] * 1.5)
		effect.Transparency = NumberSequence.new(preset[4], 1)
		effect.Lifetime = NumberRange.new(preset[5] * 0.7, preset[5])
		effect.Rate = math.max(opts.rate ~= nil and num("effect", opts.rate, "rate") or preset[6], 0)
		effect.Speed = NumberRange.new(preset[7] * 0.5, preset[7])
		effect.SpreadAngle = Vector2.new(preset[8], preset[8])
		effect.Acceleration = Vector3.new(0, preset[9], 0)
		effect.LightEmission = preset[10]
		effect.EmissionDirection = Enum.NormalId.Top
		effect.Shape = Enum.ParticleEmitterShape.Box
		effect.Parent = holder
		return effect
	end
	local holder = fxHolder("effect", "Effect", cf, Vector3.new(0.2, 0.2, 0.2))
	if kind == "fire" then
		effect = Instance.new("Fire")
		effect.Size, effect.Heat = size, math.clamp(size * 2, 1, 25)
		effect.Color = fxColor("effect", opts.color, Color3.fromRGB(236, 139, 70))
		effect.SecondaryColor = fxColor("effect", opts.secondary, Color3.fromRGB(139, 80, 55))
	elseif kind == "smoke" then
		effect = Instance.new("Smoke")
		effect.Size, effect.RiseVelocity = size, math.clamp(size, 1, 10)
		effect.Opacity = math.clamp(opts.opacity ~= nil and num("effect", opts.opacity, "opacity") or 0.25, 0, 1)
		effect.Color = fxColor("effect", opts.color, Color3.fromRGB(120, 120, 120))
	else
		effect = Instance.new("Sparkles")
		effect.SparkleColor = fxColor("effect", opts.color, Color3.fromRGB(255, 240, 180))
	end
	effect.Parent = holder
	return effect
end

local function lightingColor(value)
	if value == nil then return nil end
	return fxColor("lighting", value, nil)
end

local FOG_DENSITY = 0.6
local FOG_DARK = 0.12
local FOG_DARK_DENSITY = 0.4

-- The place's time of day and mood. Lighting is global to the place, so only
-- scene code may call this, not a generator. opts: time (0-24 clock hours),
-- brightness, ambient, outdoor (outdoor ambient), exposure, fog (0-1, where 1
-- is thick fog that still shows the near scene), fogColor, haze (0-10).
function SG.lighting(opts)
	if S.generating then
		issue("lighting", "lighting is global to the place; call it from scene code, not a generator")
		return
	end
	opts = optTable("lighting", opts)
	local ok, Lighting = pcall(game.GetService, game, "Lighting")
	if not ok then
		issue("lighting", "Lighting is not available; skipping")
		return
	end
	if opts.time ~= nil then Lighting.ClockTime = num("lighting", opts.time, "time") % 24 end
	if opts.brightness ~= nil then
		Lighting.Brightness = math.clamp(num("lighting", opts.brightness, "brightness"), 0, 10)
	end
	if opts.exposure ~= nil then
		Lighting.ExposureCompensation = math.clamp(num("lighting", opts.exposure, "exposure"), -3, 3)
	end
	Lighting.Ambient = lightingColor(opts.ambient) or Lighting.Ambient
	Lighting.OutdoorAmbient = lightingColor(opts.outdoor) or Lighting.OutdoorAmbient
	if opts.fog ~= nil or opts.fogColor ~= nil or opts.haze ~= nil then
		local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
		if not atmosphere then
			atmosphere = Instance.new("Atmosphere")
			atmosphere.Name = "SceneGenerationAtmosphere"
			atmosphere.Parent = Lighting
		end
		if opts.haze ~= nil then atmosphere.Haze = math.clamp(num("lighting", opts.haze, "haze"), 0, 10) end
		atmosphere.Color = lightingColor(opts.fogColor) or atmosphere.Color
		if opts.fog ~= nil then
			-- Atmosphere.Density 1 hides everything past arm's length, so the
			-- authored 0-1 scale tops out at FOG_DENSITY. Dark fog reads as a
			-- blackout well below that, so it is capped lower still.
			local density = math.clamp(num("lighting", opts.fog, "fog"), 0, 1) * FOG_DENSITY
			local c = atmosphere.Color
			if 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B < FOG_DARK and density > FOG_DARK_DENSITY then
				issue("lighting", ("fog %.2f with a near-black fogColor blacks out the scene; using %.2f"):format(
					num("lighting", opts.fog, "fog"), FOG_DARK_DENSITY / FOG_DENSITY))
				density = FOG_DARK_DENSITY
			end
			atmosphere.Density = density
		end
	end
end

local function points(api, data)
	data = arr(api, data, 3)
	if #data < 6 then
		issue(api, "at least two points are required; skipping call")
		return {}
	end
	local result = {}
	for i = 1, #data, 3 do
		result[#result + 1] = Vector3.new(
			num(api, data[i], "x"), num(api, data[i + 1], "y"), num(api, data[i + 2], "z"))
	end
	return result
end

function SG.curve(data, steps, closed)
	local p = points("curve", data)
	if #p < 2 then return {} end
	steps = whole("curve", steps or 6, "steps")
	local out, segments = {}, closed and #p or #p - 1
	local function get(i) return closed and p[(i - 1) % #p + 1] or p[math.clamp(i, 1, #p)] end
	for segment = 1, segments do
		local p0, p1, p2, p3 = get(segment - 1), get(segment), get(segment + 1), get(segment + 2)
		for j = 0, steps - 1 do
			local u, u2, u3 = j / steps, (j / steps) ^ 2, (j / steps) ^ 3
			local v = 0.5 * ((2 * p1) + (-p0 + p2) * u
				+ (2 * p0 - 5 * p1 + 4 * p2 - p3) * u2
				+ (-p0 + 3 * p1 - 3 * p2 + p3) * u3)
			out[#out + 1], out[#out + 2], out[#out + 3] = v.X, v.Y, v.Z
		end
	end
	local last = closed and p[1] or p[#p]
	out[#out + 1], out[#out + 2], out[#out + 3] = last.X, last.Y, last.Z
	return out
end

function SG.path(data, width, key, round, closed)
	local p = points("path", data)
	if #p < 2 then return nil end
	for i = 1, closed and #p or #p - 1 do
		local a, b = p[i], p[i % #p + 1]
		SG.segment(a.X, a.Y, a.Z, b.X, b.Y, b.Z, width, key, round)
	end
	return nil
end

function SG.ribbon(data, width, key, closed)
	local p, left, right = points("ribbon", data), {}, {}
	if #p < 2 then return nil end
	width = pos("ribbon", width, "width")
	for i, point in ipairs(p) do
		local previous = p[i == 1 and (closed and #p or 1) or i - 1]
		local following = p[i == #p and (closed and 1 or #p) or i + 1]
		local tangent = following - previous
		if tangent.Magnitude <= EPS then
			issue("ribbon", "zero tangent; using x axis")
			tangent = Vector3.xAxis
		end
		local side = Vector3.yAxis:Cross(tangent.Unit)
		if side.Magnitude <= EPS then
			issue("ribbon", "vertical tangent; using z axis")
			side = Vector3.zAxis
		end
		side = side.Unit * width / 2
		left[i], right[i] = point - side, point + side
	end
	for i = 1, closed and #p or #p - 1 do
		local j = i % #p + 1
		triangle("ribbon", left[i], right[i], right[j], 0.05, key)
		triangle("ribbon", left[i], right[j], left[j], 0.05, key)
	end
	return nil
end

local function arc(cx, cy, cz, radius, a0, a1, steps)
	cx, cy, cz = num("arc", cx, "cx"), num("arc", cy, "cy"), num("arc", cz, "cz")
	a0, a1 = num("arc", a0, "a0"), num("arc", a1, "a1")
	local p = {}
	for i = 0, steps do
		local angle = a0 + (a1 - a0) * i / steps
		p[i + 1] = Vector3.new(cx + math.cos(angle) * radius, cy + math.sin(angle) * radius, cz)
	end
	return p
end

function SG.archFill(cx, cy, cz, inner, outer, a0, a1, steps, w, key)
	outer, inner = pos("archFill", outer, "outer radius"), num("archFill", inner or 0, "inner radius")
	if inner < 0 or inner >= outer then
		local corrected = math.clamp(inner, 0, math.max(0, outer - MIN_SIZE))
		issue("archFill", ("invalid inner radius; using %s"):format(corrected))
		inner = corrected
	end
	a0, a1, steps, w = num("archFill", a0 or 0, "a0"), num("archFill", a1 or math.pi, "a1"),
		whole("archFill", steps or 12, "steps"),
		pos("archFill", w or 0.05, "thickness")
	local outside, inside = arc(cx, cy, cz, outer, a0, a1, steps),
		arc(cx, cy, cz, math.max(inner, EPS), a0, a1, steps)
	for i = 1, steps do
		if inner == 0 then
			triangle("archFill", Vector3.new(cx, cy, cz), outside[i], outside[i + 1], w, key)
		else
			triangle("archFill", inside[i], outside[i], outside[i + 1], w, key)
			triangle("archFill", inside[i], outside[i + 1], inside[i + 1], w, key)
		end
	end
end

function SG.archTrim(cx, cy, cz, radius, a0, a1, steps, width, key, round)
	steps = whole("archTrim", steps or 12, "steps")
	local p = arc(cx, cy, cz, pos("archTrim", radius, "radius"),
		num("archTrim", a0 or 0, "a0"), num("archTrim", a1 or math.pi, "a1"), steps)
	for i = 1, steps do
		local a, b = p[i], p[i + 1]
		SG.segment(a.X, a.Y, a.Z, b.X, b.Y, b.Z, width, key, round)
	end
end

function SG.boxes(data)
	data = arr("boxes", data, 7)
	for i = 1, #data, 7 do
		SG.box(data[i], data[i + 1], data[i + 2],
			SG.cframe(data[i + 3], data[i + 4], data[i + 5]), data[i + 6])
	end
end

function SG.spheres(data)
	data = arr("spheres", data, 5)
	for i = 1, #data, 5 do
		SG.sphere(data[i], SG.cframe(data[i + 1], data[i + 2], data[i + 3]), data[i + 4])
	end
	return nil
end

function SG.discs(data)
	data = arr("discs", data, 6)
	for i = 1, #data, 6 do
		SG.disc(data[i], data[i + 1],
			SG.cframe(data[i + 2], data[i + 3], data[i + 4]), data[i + 5])
	end
	return nil
end

function SG.define(key, build)
	if type(key) ~= "string" or key == "" or type(build) ~= "function" then
		issue("define", "expected non-empty key and build function; skipping definition")
		return nil
	end
	if S.protos[key] then
		issue("define", ("prototype %q already exists; replacing it"):format(key))
	end
	S.protos[key] = build
	return nil
end

-- Set once the ProceduralModel helpers below exist. Returns the placed
-- ProceduralModel, or nil when key has no prototype Generator.
local prototypeModel
-- Also set below. Binds each lifted ProceduralModel to its lift and removes
-- the build markers.
local finishScene

-- A box size from a Vector3 or {width, height, depth}, or nil when absent.
local function boxSize(api, value)
	if value == nil then return nil end
	if typeof(value) == "Vector3" then value = { value.X, value.Y, value.Z } end
	local w, h, d = type(value) == "table" and tonumber(value[1]), type(value) == "table" and tonumber(value[2]),
		type(value) == "table" and tonumber(value[3])
	if not (w and h and d and w > EPS and h > EPS and d > EPS) then
		issue(api, "size must be {width, height, depth} with positive numbers; ignoring it")
		return nil
	end
	return Vector3.new(w, h, d)
end
-- Set with the Terrain grading below. Levels the ground under a seated object.
local padUnder

-- A copy built as plain parts, when the prototype has no Generator or its
-- ProceduralModel failed. SG.attributes still reads the copy's attributes, so
-- the plain copy is the same object a generated one would have been, and
-- SG.size returns size when one was asked for.
local function plainCopy(api, name, cf, build, attributes, size)
	local saved, savedSize = S.plainAttributes, S.plainSize
	S.plainAttributes = type(attributes) == "table" and attributes or nil
	S.plainSize = size
	local model = scoped(api, name, cf, build)
	S.plainAttributes, S.plainSize = saved, savedSize
	if model and type(attributes) == "table" then
		for attribute, value in pairs(attributes) do
			pcall(model.SetAttribute, model, tostring(attribute), value)
		end
	end
	return model
end

-- attributes optionally sets the prototype's SG.attributes on every copy.
function SG.place(key, base, data, attributes)
	local build = S.protos[key]
	if not build then
		issue("place", ("prototype %q is not defined; skipping placements"):format(tostring(key)))
		return nil
	end
	data = arr("place", data, 6)
	if type(base) ~= "string" or base == "" then
		issue("place", "invalid base name; using prototype key")
		base = tostring(key)
	end
	for i = 1, #data, 6 do
		local n = (i + 5) / 6
		local name = ("%s_%03d"):format(base, n)
		local cf = SG.cframe(data[i], data[i + 1], data[i + 2], data[i + 3], data[i + 4], data[i + 5])
		if not prototypeModel("place", key, name, cf, attributes) then
			plainCopy("place", name, cf, build, attributes)
		end
	end
	return nil
end

function SG.assets(data)
	if S.assetsLocked then
		issue("assets", "asset manifest is already registered; ignoring replacement")
		return nil
	end
	if type(data) ~= "table" then
		issue("assets", "asset manifest must be a table")
		return nil
	end
	for _, template in pairs(S.assetTemplates) do
		template:Destroy()
	end
	S.assetTemplates, S.assetFailures = {}, {}
	S.assets = data
	S.assetsLocked = true
	return nil
end

local function assetTemplate(key)
	if S.assetTemplates[key] then return S.assetTemplates[key] end
	if S.assetFailures[key] then return nil end
	local spec = S.assets[key]
	if type(spec) ~= "table" or tonumber(spec.assetId) == nil then
		issue("mesh", ("asset %q is not registered; skipping mesh"):format(tostring(key)))
		S.assetFailures[key] = true
		return nil
	end
	local service = game:GetService("InsertService")
	local ok, loaded = pcall(service.LoadAsset, service, tonumber(spec.assetId))
	if not ok or not loaded then
		issue("mesh", ("could not load asset %s for %s: %s")
			:format(tostring(spec.assetId), tostring(key), tostring(loaded)))
		S.assetFailures[key] = true
		return nil
	end
	loaded.Name = tostring(key) .. "_Template"
	loaded.Parent = nil
	for _, item in ipairs(loaded:GetDescendants()) do
		if item:IsA("LuaSourceContainer") then
			item:Destroy()
		elseif item:IsA("BasePart") then
			item.Anchored = true
		end
	end
	S.assetTemplates[key] = loaded
	return loaded
end

local function recordMeshPlacement(key, base, targetHeight, spec)
	local extent = type(spec) == "table" and spec.extent
	if type(extent) ~= "table"
		or tonumber(extent[1]) == nil
		or tonumber(extent[2]) == nil
		or tonumber(extent[3]) == nil then
		issue("mesh", ("asset %q has no measured extent; skipping export placement")
			:format(tostring(key)))
		return
	end
	local box = type(spec) == "table" and spec.box
	if type(box) ~= "table" or #box ~= 12 then
		issue("mesh", ("asset %q has no measured bounding-box frame; skipping export placement")
			:format(tostring(key)))
		return
	end
	for i = 1, 12 do
		if tonumber(box[i]) == nil then
			issue("mesh", ("asset %q has an invalid bounding-box frame; skipping export placement")
				:format(tostring(key)))
			return
		end
	end
	local record = Instance.new("CFrameValue")
	S.meshPlacementCount += 1
	record.Name = MESH_PLACEMENT
	record.Archivable = false
	record.Value = base
	record:SetAttribute("Key", tostring(key))
	record:SetAttribute("Ordinal", S.meshPlacementCount)
	record:SetAttribute("TargetHeight", targetHeight)
	record:SetAttribute("ExtentX", tonumber(extent[1]))
	record:SetAttribute("ExtentY", tonumber(extent[2]))
	record:SetAttribute("ExtentZ", tonumber(extent[3]))
	record:SetAttribute("BoxCFrame", CFrame.new(table.unpack(box)))
	record.Parent = parent("mesh")
end

-- Published MeshGen assets face +Z, but every SG front faces -Z, so the half
-- turn makes yaw 0 mean the same thing for meshes, prototypes, and generators.
-- The turned frame is also what export records for the composite GLB.
local MESH_FRONT = CFrame.Angles(0, math.pi, 0)

function SG.mesh(key, cf, targetHeight)
	targetHeight = pos("mesh", targetHeight, "targetHeight")
	local base = S.xforms[#S.xforms] * localCF("mesh", cf) * MESH_FRONT
	local spec = S.assets[key]
	if marked(CAPTURE_MARKER) then
		recordMeshPlacement(key, base, targetHeight, spec)
		return nil
	end
	local template = assetTemplate(key)
	if not template then return nil end
	local model
	local ok, err = pcall(function()
		model = template:Clone()
		model.Name = nextName(parent("mesh"), tostring(key))
		model:PivotTo(CFrame.identity)
		local box, extent = model:GetBoundingBox()
		if extent.Y <= EPS then
			error(("asset %q has no measurable height"):format(tostring(key)))
		end
		model:ScaleTo(model:GetScale() * targetHeight / extent.Y)
		model:PivotTo(CFrame.identity)
		local fitted
		box, fitted = model:GetBoundingBox()
		local wantedBox = base * CFrame.new(0, fitted.Y / 2, 0)
		model:PivotTo(wantedBox * box:Inverse())
		model.Parent = parent("mesh")
	end)
	if not ok then
		if model then model:Destroy() end
		issue("mesh", ("asset %q could not be fitted; skipping mesh: %s")
			:format(tostring(key), tostring(err)))
		return nil
	end
	return model
end

function SG.boxRegion(x, y, z, sx, sy, sz)
	x, y, z = num("boxRegion", x, "x"), num("boxRegion", y, "y"), num("boxRegion", z, "z")
	sx, sy, sz = num("boxRegion", sx, "sx"), num("boxRegion", sy, "sy"), num("boxRegion", sz, "sz")
	if sx < 0 or sy < 0 or sz < 0 then
		issue("boxRegion", "region sizes must be non-negative; using absolute values")
		sx, sy, sz = math.abs(sx), math.abs(sy), math.abs(sz)
	end
	if sx + sy + sz <= 0 then
		issue("boxRegion", "invalid region; scatter will be skipped")
		return nil
	end
	return { "b", x, y, z, sx, sy, sz }
end

function SG.discRegion(x, y, z, radius)
	return { "d", num("discRegion", x, "x"), num("discRegion", y, "y"), num("discRegion", z, "z"),
		pos("discRegion", radius, "radius") }
end

function SG.scatter(seed, count, region, build)
	count = whole("scatter", count, "count", true)
	if type(region) ~= "table" or type(build) ~= "function" then
		issue("scatter", "expected region and build function; skipping scatter")
		return nil
	end
	seed = whole("scatter", seed or 0, "seed", true)
	local rng = Random.new(seed)
	for i = 1, count do
		local point
		if region[1] == "b" then
			if #region < 7 then
				issue("scatter", "box region is incomplete; skipping scatter")
				return nil
			end
			local x, y, z = num("scatter", region[2], "region x"),
				num("scatter", region[3], "region y"), num("scatter", region[4], "region z")
			local sx, sy, sz = math.abs(num("scatter", region[5], "region sx")),
				math.abs(num("scatter", region[6], "region sy")),
				math.abs(num("scatter", region[7], "region sz"))
			point = Vector3.new(
				x + rng:NextNumber(-sx / 2, sx / 2),
				y + rng:NextNumber(-sy / 2, sy / 2),
				z + rng:NextNumber(-sz / 2, sz / 2))
		elseif region[1] == "d" then
			if #region < 5 then
				issue("scatter", "disc region is incomplete; skipping scatter")
				return nil
			end
			local x, y, z = num("scatter", region[2], "region x"),
				num("scatter", region[3], "region y"), num("scatter", region[4], "region z")
			local angle = rng:NextNumber(0, math.pi * 2)
			local radius = math.sqrt(rng:NextNumber()) * pos("scatter", region[5], "region radius")
			point = Vector3.new(
				x + math.cos(angle) * radius, y, z + math.sin(angle) * radius)
		else
			issue("scatter", "unknown region; skipping scatter")
			return nil
		end
		local ok, result = pcall(build, point, i, rng)
		if not ok then issue("scatter", ("item %d stopped early: %s"):format(i, tostring(result))) end
	end
	return nil
end

-- Seating on the ground. A raycast straight down finds whatever support the
-- caller named and reports its surface height. The seating wrappers below run
-- this BEFORE entering a build callback, so an object is placed at a height the
-- ground decided, and no ray is ever fired from inside a group (where it would
-- hit the sibling part placed a moment earlier and walk the object into the sky).
-- RCC export replaces Terrain with parts under I2LFakedTerrain, and rewrites
-- Terrain references in the scene's own chunk only. Looking the folder up by
-- name keeps seating correct in a ModuleScript copy of SG as well.
local function terrainSupport()
	return workspace:FindFirstChild("I2LFakedTerrain") or workspace.Terrain
end

local function normalizeSupports(api, supports)
	if supports == nil then return { terrainSupport() } end
	if typeof(supports) == "Instance" then return { supports } end
	if type(supports) ~= "table" then
		issue(api, "supports must be an Instance or a table of Instances; using Terrain")
		return { terrainSupport() }
	end
	local out = {}
	for _, inst in ipairs(supports) do
		if typeof(inst) == "Instance" then
			out[#out + 1] = inst
		else
			issue(api, "each support must be an Instance; ignoring one entry")
		end
	end
	if #out == 0 then
		issue(api, "no valid supports given; using Terrain")
		return { terrainSupport() }
	end
	return out
end

local SKY = 4096

local function includeParams(supports, ignoreWater)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = supports
	params.IgnoreWater = ignoreWater
	return params
end

-- One downward ray against a fixed include-filter. Returns the world Y of the
-- hit, or nil when the column is empty. A ray from the sky stops on the first
-- surface, which inside a cave is the hill over it; `below` starts the ray at
-- that height instead, so it lands on the floor under that point.
local function raycastSupport(x, z, supports, ignoreWater, below)
	local start = below or SKY
	local hit = workspace:Raycast(Vector3.new(x, start, z), Vector3.new(0, -(start + SKY), 0),
		includeParams(supports, ignoreWater))
	return hit and hit.Position.Y or nil
end

-- The underside of whatever is above (x, y, z), up to reach studs, or nil.
local function raycastCeiling(x, y, z, supports, reach)
	local hit = workspace:Raycast(Vector3.new(x, y, z), Vector3.new(0, reach, 0), includeParams(supports, true))
	return hit and hit.Position.Y or nil
end

-- The highest hit across a footprint, so no corner of a wide object sinks. A
-- footprint is a side length or a {width, depth} pair along the object's own
-- axes, so its corners turn with yaw. It is sampled at its centre and four
-- corners; nil footprint samples the centre alone. Returns nil if every sample
-- misses.
local function highestSupport(api, x, z, supports, footprint, ignoreWater, yaw, below)
	local best = raycastSupport(x, z, supports, ignoreWater, below)
	if footprint ~= nil then
		local hw, hd
		if type(footprint) == "table" then
			hw = pos(api, footprint[1], "footprint width") / 2
			hd = pos(api, footprint[2], "footprint depth") / 2
		else
			hw = pos(api, footprint, "footprint") / 2
			hd = hw
		end
		local turn = math.rad(yaw or 0)
		local c, s = math.cos(turn), math.sin(turn)
		for _, o in ipairs({ { -hw, -hd }, { hw, -hd }, { -hw, hd }, { hw, hd } }) do
			-- CFrame.Angles(0, turn, 0) carries a local (x, z) to these world offsets.
			local ox, oz = o[1] * c + o[2] * s, -o[1] * s + o[2] * c
			local y = raycastSupport(x + ox, z + oz, supports, ignoreWater, below)
			if y and (not best or y > best) then best = y end
		end
	end
	return best
end

-- Resolve a seating request to a world CFrame. (x, z) are the caller's footprint
-- centre, taken through the current transform so seating works inside a
-- translated group; yaw is degrees about world Y. When nothing supports the
-- column we warn and fall back to y = 0 rather than dropping the object.
-- The root transform maps world into a scene element's ProceduralModel space,
-- so it is undone before raycasting and reapplied to the seated result.
local function seatWorld(api, label, x, z, yaw, opts)
	opts = type(opts) == "table" and opts or {}
	local root = S.xforms[1]
	local base = root:Inverse() * S.xforms[#S.xforms]
	local below = opts.below ~= nil and num(api, opts.below, "below") or nil
	local column = base * Vector3.new(num(api, x, "x"), below or 0, num(api, z, "z"))
	yaw = num(api, yaw or 0, "yaw")
	local y = opts.y
	if y ~= nil then
		y = num(api, y, "y")
	else
		local supports = normalizeSupports(api, opts.supports)
		local ignoreWater = opts.ignoreWater
		if ignoreWater == nil then ignoreWater = true end
		y = highestSupport(api, column.X, column.Z, supports, opts.footprint, ignoreWater, yaw,
			below and column.Y or nil)
		if y == nil then
			issue(api, ("nothing supports %q; placing it at y = 0"):format(tostring(label)))
			y = 0
		end
	end
	local world = CFrame.new(column.X, y, column.Z) * CFrame.Angles(0, math.rad(yaw), 0)
	return base:Inverse() * world
end

-- The raw support height at a world column, for callers doing their own math.
-- Returns nil when the column is empty; handle that rather than indexing it.
function SG.ground(x, z, supports, ignoreWater)
	x, z = num("ground", x, "x"), num("ground", z, "z")
	supports = normalizeSupports("ground", supports)
	if ignoreWater == nil then ignoreWater = true end
	return raycastSupport(x, z, supports, ignoreWater)
end

-- The first support at or below y in a column: a cave or interior floor rather
-- than the roof above it. nil when nothing is below.
function SG.floor(x, y, z, supports, ignoreWater)
	x, y, z = num("floor", x, "x"), num("floor", y, "y"), num("floor", z, "z")
	supports = normalizeSupports("floor", supports)
	if ignoreWater == nil then ignoreWater = true end
	return raycastSupport(x, z, supports, ignoreWater, y)
end

-- The parts of the scene and the Terrain, for helpers that attach to whatever
-- the scene has already built.
local function sceneSupports()
	local out = { terrainSupport() }
	if S.root then out[2] = S.root end
	return out
end

-- The underside of the first thing above y in a column, up to reach studs
-- (default 64): a cave roof, a beam, or an eave. nil when nothing is above.
function SG.ceiling(x, y, z, supports, reach)
	x, y, z = num("ceiling", x, "x"), num("ceiling", y, "y"), num("ceiling", z, "z")
	supports = supports == nil and sceneSupports() or normalizeSupports("ceiling", supports)
	reach = reach ~= nil and pos("ceiling", reach, "reach") or 64
	return raycastCeiling(x, y, z, supports, reach)
end

-- How far a thin surface may sit under the terrain and still be lifted onto it.
-- Deeper than this is a basement or a span, not the 2-stud voxel bleed.
local SURFACE_BURIAL = 6
local SURFACE_THICKNESS = 2.5
local SURFACE_CLEARANCE = 0.1

local function worldSpan(cf, size, axis)
	local function component(vector)
		if axis == "x" then return math.abs(vector.X) end
		if axis == "z" then return math.abs(vector.Z) end
		return math.abs(vector.Y)
	end
	return component(cf.RightVector) * size.X
		+ component(cf.UpVector) * size.Y
		+ component(cf.LookVector) * size.Z
end

-- Grass blades grow through any part laid over Grass Terrain. A part at least
-- GRASS_COVER studs across whose underside is within GRASS_REACH of the ground
-- covers it, and the Grass under it becomes LeafyGrass, which has no blades.
-- Narrower parts (posts, flowers, trunks) leave the meadow around them alone.
local GRASS_COVER = 2
local GRASS_REACH = 2
local GRASS_VOXEL = 4

local function clearGrassUnder(parts, supports)
	local terrain = workspace.Terrain
	if typeof(terrain) ~= "Instance" then return end
	local columns, order = {}, {}
	for _, part in ipairs(parts) do
		local cf, size, p = part.CFrame, part.Size, part.Position
		local spanX, spanY, spanZ = worldSpan(cf, size, "x"), worldSpan(cf, size, "y"), worldSpan(cf, size, "z")
		-- A slab on a slope is seated or lifted to its highest corner, so the
		-- ground under its centre can sit well below it.
		local low, high = math.huge, -math.huge
		for _, o in ipairs({ { 0, 0 }, { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
			local ground = raycastSupport(p.X + o[1] * spanX / 2, p.Z + o[2] * spanZ / 2, supports, true)
			if ground then low, high = math.min(low, ground), math.max(high, ground) end
		end
		local bottom = p.Y - spanY / 2
		if low < math.huge and bottom <= high + GRASS_REACH and bottom + spanY >= low - 0.5 then
			local lo = math.floor((low - 8) / GRASS_VOXEL)
			local hi = math.ceil((high + 6) / GRASS_VOXEL)
			for ix = math.floor((p.X - spanX / 2) / GRASS_VOXEL), math.ceil((p.X + spanX / 2) / GRASS_VOXEL) - 1 do
				for iz = math.floor((p.Z - spanZ / 2) / GRASS_VOXEL), math.ceil((p.Z + spanZ / 2) / GRASS_VOXEL) - 1 do
					local key = ix .. "," .. iz
					local column = columns[key]
					if column then
						column[3], column[4] = math.min(column[3], lo), math.max(column[4], hi)
					else
						columns[key] = { ix, iz, lo, hi }
						order[#order + 1] = columns[key]
					end
				end
			end
		end
	end
	table.sort(order, function(a, b)
		if a[1] ~= b[1] then return a[1] < b[1] end
		return a[2] < b[2]
	end)
	local i = 1
	while i <= #order do
		local first, last = order[i], order[i]
		while order[i + 1] and order[i + 1][1] == first[1] and order[i + 1][2] == last[2] + 1
			and order[i + 1][3] == first[3] and order[i + 1][4] == first[4] do
			i += 1
			last = order[i]
		end
		local region = Region3.new(
			Vector3.new(first[1], first[3], first[2]) * GRASS_VOXEL,
			Vector3.new(first[1] + 1, first[4], last[2] + 1) * GRASS_VOXEL)
		pcall(terrain.ReplaceMaterial, terrain, region, GRASS_VOXEL, Enum.Material.Grass, Enum.Material.LeafyGrass)
		i += 1
	end
end

-- Roads, decks and treads authored at a fill height end up under the visible
-- surface. Lift each thin horizontal part so its top clears the terrain under
-- it. Water is ignored, so a pier over the sea stays at its drafted height
-- while the same deck rises where it crosses land. A part buried deeper than
-- SURFACE_BURIAL is left where it was.
function SG.liftSurfaces()
	if S.generating then
		issue("liftSurfaces", "call it from scene code, after the scene has built")
		return nil
	end
	for _ = 1, 4 do task.wait() end
	local supports = { terrainSupport() }
	local function buried(x, z, top)
		local ground = raycastSupport(x, z, supports, true)
		if not ground then return nil end
		local depth = ground + SURFACE_CLEARANCE - top
		if depth <= 0 or depth > SURFACE_BURIAL then return nil end
		return depth
	end
	local lifts, covers = {}, {}
	for _, part in ipairs(workspace:GetDescendants()) do
		if part:IsA("BasePart") and not part:IsA("Terrain") then
			local skipped = false
			local current = part.Parent
			while typeof(current) == "Instance" do
				if current.Name == "I2LFakedTerrain" then
					skipped = true
					break
				end
				current = current.Parent
			end
			-- A paved road already sits on Terrain shaped for it.
			local readGraded, graded = pcall(part.GetAttribute, part, GRADED_ATTRIBUTE)
			skipped = skipped or (readGraded and graded == true)
			local cf, size = part.CFrame, part.Size
			local spanY = worldSpan(cf, size, "y")
			local spanX, spanZ = worldSpan(cf, size, "x"), worldSpan(cf, size, "z")
			if not skipped and part.Transparency < 0.95 and math.min(spanX, spanZ) >= GRASS_COVER then
				covers[#covers + 1] = part
			end
			if not skipped and spanY <= SURFACE_THICKNESS and spanY <= spanX and spanY <= spanZ then
				local top = part.Position.Y + spanY / 2
				local hx, hz = spanX / 2, spanZ / 2
				local depth = buried(part.Position.X, part.Position.Z, top)
				for _, corner in ipairs({ { -hx, -hz }, { hx, -hz }, { -hx, hz }, { hx, hz } }) do
					local sample = buried(part.Position.X + corner[1], part.Position.Z + corner[2], top)
					if sample and (not depth or sample > depth) then depth = sample end
				end
				if depth then
					pcall(function()
						part.CFrame = part.CFrame + Vector3.new(0, depth, 0)
					end)
					-- A ProceduralModel rebuilds its parts from the generator, so a
					-- CFrame edit here is gone on the next Size or Attribute change.
					-- The index is the one make() stamps, and generation adds the
					-- same delta back in the model's unscaled space.
					local readIndex, index = pcall(part.GetAttribute, part, ZF_INDEX)
					local host = part.Parent
					while typeof(host) == "Instance" and not host:IsA("ProceduralModel") do
						host = host.Parent
					end
					if readIndex and type(index) == "number" and typeof(host) == "Instance" and host:IsA("ProceduralModel") then
						local bucket = lifts[host]
						if not bucket then
							bucket = {}
							lifts[host] = bucket
						end
						local readScale, scale = pcall(host.GetScale, host)
						if not readScale or type(scale) ~= "number" or scale <= EPS then scale = 1 end
						bucket[tostring(index)] = depth / scale
					end
				end
			end
		end
	end
	clearGrassUnder(covers, supports)
	finishScene(lifts)
	return nil
end

-- An SG.group that seats itself: builds the object in local space around a base
-- at y = 0, then rests it on the ground at (x, z) facing yaw. opts may carry
-- supports (Instance or list; default Terrain), footprint (side or {w, d} for
-- highest-corner sampling), ignoreWater (default true), and y (an explicit
-- height that skips the raycast).
function SG.seat(name, x, z, yaw, build, opts)
	if type(yaw) == "function" and build == nil then
		yaw, build = 0, yaw
	end
	local cf = seatWorld("seat", name, x, z, yaw, opts)
	local model = scoped("seat", name, cf, build)
	if type(opts) == "table" and opts.pad then padUnder("seat", model, cf, opts) end
	return model
end

-- Place a generated mesh resting on the ground at (x, z) facing yaw, scaled to
-- targetHeight studs. The mesh analogue of SG.seat; opts matches SG.seat.
function SG.meshOn(key, x, z, yaw, targetHeight, opts)
	local cf = seatWorld("meshOn", key, x, z, yaw, opts)
	local model = SG.mesh(key, cf, targetHeight)
	if type(opts) == "table" and opts.pad then padUnder("meshOn", model, cf, opts) end
	return model
end

-- How far below the given point a hanging object may find what it hangs from,
-- so a point a little under a beam's underside still finds that beam.
local HANG_SLACK = 1.5

-- Hang a mesh so its top meets what it hangs from. (x, y, z) is a point just
-- under a beam, eave, branch or ceiling, or in front of a wall or cliff with
-- opts.wall. The search starts there and only looks up (or back, for a wall),
-- never from the sky, so it cannot land on a roof or a hilltop over the point.
-- opts: reach (studs to search, default 24), wall (hang against the surface
-- behind the mesh, which faces away from it), supports (default the scene's
-- parts and the Terrain).
function SG.hang(key, x, y, z, yaw, targetHeight, opts)
	local api = "hang"
	opts = type(opts) == "table" and opts or {}
	targetHeight = pos(api, targetHeight, "targetHeight")
	yaw = num(api, yaw or 0, "yaw")
	local reach = opts.reach ~= nil and pos(api, opts.reach, "reach") or 24
	local supports = opts.supports == nil and sceneSupports() or normalizeSupports(api, opts.supports)
	local root = S.xforms[1]
	local base = root:Inverse() * S.xforms[#S.xforms]
	local point = base * Vector3.new(num(api, x, "x"), num(api, y, "y"), num(api, z, "z"))
	local turn = base.Rotation * CFrame.Angles(0, math.rad(yaw), 0)
	local top, column = point.Y, point
	if opts.wall then
		local back = turn:VectorToWorldSpace(Vector3.zAxis)
		local start = point - Vector3.new(0, math.min(1, targetHeight * 0.1), 0)
		local hit = workspace:Raycast(start, back * reach, includeParams(supports, true))
		if hit then
			local normal = Vector3.new(hit.Normal.X, 0, hit.Normal.Z)
			if normal.Magnitude > EPS then
				normal = normal.Unit
				turn = CFrame.Angles(0, math.atan2(-normal.X, -normal.Z), 0)
			else
				normal = -back
			end
			local spec = S.assets[key]
			local extent = type(spec) == "table" and type(spec.extent) == "table" and spec.extent or {}
			local height, deep = tonumber(extent[2]), tonumber(extent[3])
			local depth = 0
			if height and deep and height > EPS then depth = deep * targetHeight / height end
			column = Vector3.new(hit.Position.X, point.Y, hit.Position.Z) + normal * (depth / 2 + 0.05)
		else
			issue(api, ("no wall within %g studs behind %q; hanging it at the given point")
				:format(reach, tostring(key)))
		end
	else
		local ceiling = raycastCeiling(point.X, point.Y - HANG_SLACK, point.Z, supports, reach + HANG_SLACK)
		if ceiling then
			top = ceiling
		else
			issue(api, ("nothing within %g studs above %q; hanging it from the given point")
				:format(reach, tostring(key)))
		end
	end
	local world = CFrame.new(column.X, top - targetHeight, column.Z) * turn
	return SG.mesh(key, base:Inverse() * world, targetHeight)
end

-- SG.place, seated. rows is a flat array of (x, z, yaw) triples; each placement
-- is dropped onto the ground at its column. opts matches SG.seat and applies to
-- every placement.
function SG.placeOn(key, base, rows, opts)
	local build = S.protos[key]
	if not build then
		issue("placeOn", ("prototype %q is not defined; skipping placements"):format(tostring(key)))
		return nil
	end
	rows = arr("placeOn", rows, 3)
	if type(base) ~= "string" or base == "" then
		issue("placeOn", "invalid base name; using prototype key")
		base = tostring(key)
	end
	local attributes = type(opts) == "table" and opts.attributes or nil
	local size = type(opts) == "table" and boxSize("placeOn", opts.size) or nil
	if size and type(opts) == "table" and opts.footprint == nil then
		local seated = {}
		for k, v in pairs(opts) do seated[k] = v end
		seated.footprint = { size.X, size.Z }
		opts = seated
	end
	for i = 1, #rows, 3 do
		local n = (i + 2) / 3
		local name = ("%s_%03d"):format(base, n)
		local cf = seatWorld("placeOn", name, rows[i], rows[i + 1], rows[i + 2], opts)
		local model = prototypeModel("placeOn", key, name, cf, attributes, size)
		if not model then model = plainCopy("placeOn", name, cf, build, attributes, size) end
		if type(opts) == "table" and opts.pad then padUnder("placeOn", model, cf, opts) end
	end
	return nil
end

-- ProceduralModels. A Generator ModuleScript builds its object with SG inside
-- SG.into; ProceduralModel:GetBoundingBox() reports Size rather than what was
-- generated, so placement always measures the generated parts.
local function measureParts(instance)
	local low = Vector3.new(math.huge, math.huge, math.huge)
	local high = -low
	local count = 0
	for _, item in ipairs(instance:GetDescendants()) do
		if item:IsA("BasePart") then
			count += 1
			local half = item.Size / 2
			for _, sx in ipairs({ -1, 1 }) do
				for _, sy in ipairs({ -1, 1 }) do
					for _, sz in ipairs({ -1, 1 }) do
						local corner = item.CFrame:PointToWorldSpace(
							Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))
						low = low:Min(corner)
						high = high:Max(corner)
					end
				end
			end
		end
	end
	return count, low, high
end

local function recentre(container, offset)
	for _, item in ipairs(container:GetDescendants()) do
		if item:IsA("BasePart") then
			item.CFrame = item.CFrame - offset
		elseif item:IsA("Model") and not item.PrimaryPart then
			item.WorldPivot = item.WorldPivot - offset
		end
	end
end

-- A scene RCC runs as a game script may not write ModuleScript.Source (it lacks
-- PluginOrOpenCloud). The RCC host script, which may, leaves a
-- BindableFunction that writes it instead.
local function generatorModule(folder, name, source)
	local module = Instance.new("ModuleScript")
	module.Name = name
	local written, writeError = pcall(function() module.Source = source end)
	if not written then
		module:Destroy()
		local installer = game:GetService("ServerStorage"):FindFirstChild(INSTALLER_NAME)
		if not (installer and installer:IsA("BindableFunction")) then error(writeError, 0) end
		module = installer:Invoke(name, source)
		if typeof(module) ~= "Instance" or not module:IsA("ModuleScript") then
			error("the generator installer returned no ModuleScript", 0)
		end
	end
	module.Parent = folder
	return module
end

local LUA_NAME = "^[%a_][%w_]*$"

local function luaLiteral(value, depth)
	depth = depth or 1
	local kind = type(value)
	if kind == "number" then
		if value ~= value or math.abs(value) == math.huge then return "0" end
		return ("%.9g"):format(value)
	elseif kind == "string" then
		return ("%q"):format(value)
	elseif kind == "boolean" then
		return tostring(value)
	elseif kind ~= "table" then
		return "nil"
	end
	local keys = {}
	for key in pairs(value) do keys[#keys + 1] = key end
	if #keys == 0 then return "{}" end
	if #value == #keys then
		local items = {}
		for i = 1, #value do items[i] = luaLiteral(value[i], depth + 1) end
		return "{ " .. table.concat(items, ", ") .. " }"
	end
	table.sort(keys, function(a, b)
		local na, nb = tonumber(a), tonumber(b)
		if na and nb then return na < nb end
		return tostring(a) < tostring(b)
	end)
	local pad = string.rep("\t", depth)
	local lines = {}
	for _, key in ipairs(keys) do
		local label = type(key) == "string" and key:match(LUA_NAME) and key or ("[%s]"):format(luaLiteral(key))
		lines[#lines + 1] = ("%s%s = %s,"):format(pad, label, luaLiteral(value[key], depth + 1))
	end
	return "{\n" .. table.concat(lines, "\n") .. "\n" .. string.rep("\t", depth - 1) .. "}"
end

local function wrapperName(name)
	local folder = S.instanceFolder
	local candidate, extra = name, 1
	while S.wrapperNames[candidate] or (folder and folder:FindFirstChild(candidate)) do
		extra += 1
		candidate = ("%s_%d"):format(name, extra)
	end
	S.wrapperNames[candidate] = true
	return candidate
end

-- The Generator for one ProceduralModel. A model with repairs gets its own
-- wrapper module in Generators.Instances that binds them to the shared one;
-- the rest use the shared module directly.
local function generatorFor(made, shared, state)
	S.shared[made] = shared
	if type(state) ~= "table" or next(state) == nil or not S.instanceFolder then return shared end
	local source = ('local SG = require(game:GetService("ReplicatedStorage").SceneGeneration.SG)\n'
		.. "return SG.bind(require(script.Parent.Parent[%q][%q]), %s)\n")
		:format(shared.Parent.Name, shared.Name, luaLiteral(state))
	local ok, module = pcall(generatorModule, S.instanceFolder, wrapperName(made.Name), source)
	if ok then return module end
	issue("generators", ("%s keeps the shared Generator, so its repairs are lost when it regenerates: %s")
		:format(made.Name, tostring(module)))
	return shared
end

-- Engines without ForceGeneration (roblox-cli 0.730) generate a frame or two
-- later instead, so there the first GeneratedFolder content is waited for.
local function forceGeneration(made)
	local ok, finished = pcall(made.ForceGeneration, made)
	if ok then return finished == true end
	if not tostring(finished):find("not available", 1, true) then error(finished, 0) end
	local deadline = os.clock() + 10
	repeat
		task.wait()
		if tostring(made.GenerationError) ~= "" then return false end
		local folder = made:FindFirstChildOfClass("GeneratedFolder")
		if folder and #folder:GetChildren() > 0 then return true end
	until os.clock() > deadline
	return false
end

-- Studio regenerates a ProceduralModel whenever its Size or Attributes change,
-- and lays the new parts out relative to its pivot. SG.into centres every
-- generation on the generator's origin, so a pivot there is the centre of the
-- Size box Studio draws. The first generation moves the pivot to the first
-- part's rotation, so it is pinned back to the origin afterwards.
local function generateAtOrigin(made)
	made.WorldPivot = CFrame.identity
	if not forceGeneration(made) then
		error("generation did not finish: " .. tostring(made.GenerationError))
	end
	made.WorldPivot = CFrame.identity
end

-- Size the box to what generated, for a model whose first build was measured
-- in the scene's copy of SG and came out otherwise.
local function matchSize(made)
	local count, low, high = measureParts(made)
	if count == 0 then return end
	local extent = high - low
	local delta = extent - made.Size
	if math.max(math.abs(delta.X), math.abs(delta.Y), math.abs(delta.Z)) > SIZE_TOLERANCE then
		made.Size = extent
		generateAtOrigin(made)
	end
end

-- Move a generated object so the bottom centre of its parts lands on base.
local function seatGenerated(model, base)
	local count, low, high = measureParts(model)
	if count == 0 then error("generated no parts") end
	local bottom = Vector3.new((low.X + high.X) / 2, low.Y, (low.Z + high.Z) / 2)
	model:PivotTo(base * CFrame.new(-bottom) * model:GetPivot())
	return high - low
end

-- The drafted centre and box of a prototype copy, built once per key,
-- attributes and size as plain parts that are thrown away. A generation is
-- centred on its parts, so this is where the prototype's own origin lands.
local function prototypeBox(key, attributes, size)
	local id = ("%s|%s|%s"):format(tostring(key), tostring(attributes), tostring(size))
	local box = S.protoBoxes[id]
	if box then return box[1], box[2] end
	local build = S.protos[key]
	if type(build) ~= "function" then return nil, nil end
	local scratch = Instance.new("Model")
	SG.into(scratch, build, attributes, size)
	local centre, extent = S.lastCenter, S.lastExtent
	scratch:Destroy()
	if centre then S.protoBoxes[id] = { centre, extent } end
	return centre, extent
end

-- One copy of an SG.define prototype that the prelude registered as a
-- Generator. The prototype builds in its own local space, so the copy is
-- generated at the origin and then pivoted onto cf, exactly where SG.place
-- would have built it. Inside a generation, prototypes stay plain parts.
-- A size other than the prototype's own box makes its SG.size fit it.
prototypeModel = function(api, key, name, cf, attributes, size)
	local module = S.prototypes and S.prototypes[key]
	if not module or S.generating then return nil end
	if attributes ~= nil and type(attributes) ~= "table" then
		issue(api, "attributes must be a table; ignoring them")
		attributes = nil
	end
	local holder = parent(api)
	local world = S.xforms[#S.xforms] * localCF(api, cf)
	local made
	local ok, err = pcall(function()
		local centre, extent = prototypeBox(key, attributes, size)
		if not centre then error("generated no parts") end
		made = Instance.new("ProceduralModel")
		made.Name = name
		made.Size = size or extent
		for attribute, value in pairs(attributes or {}) do
			if not pcall(made.SetAttribute, made, tostring(attribute), value) then
				issue(api, ("%s attribute %s has an unsupported value; ignoring it"):format(name, tostring(attribute)))
			end
		end
		made.Parent = holder
		local _, repairs = bindZFight(made)
		made.Generator = generatorFor(made, module, repairs and { zf = repairs } or nil)
		generateAtOrigin(made)
		matchSize(made)
		made:PivotTo(world * CFrame.new(centre))
		labelScope(made)
	end)
	if ok then return made end
	if made then made:Destroy() end
	issue(api, ("%s is a plain Model because ProceduralModel failed: %s"):format(name, tostring(err)))
	return nil
end

-- The parts' box in frame's space.
local function partsIn(model, frame)
	local low = Vector3.new(math.huge, math.huge, math.huge)
	local high = -low
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("BasePart") then
			local half = item.Size / 2
			for _, sx in ipairs({ -1, 1 }) do
				for _, sy in ipairs({ -1, 1 }) do
					for _, sz in ipairs({ -1, 1 }) do
						local corner = frame:PointToObjectSpace(item.CFrame:PointToWorldSpace(
							Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)))
						low = low:Min(corner)
						high = high:Max(corner)
					end
				end
			end
		end
	end
	return low, high
end

-- The end of the scene. Each lifted ProceduralModel gets a wrapper Generator
-- with its lift (and any z-fighting repairs) and regenerates from it, so the
-- lift survives the next Size or Attribute change. Its box grows to the lifted
-- parts, and its pivot moves to their centre, which is where the regenerated
-- parts are centred. Then the per-part build markers come off, unless a host
-- asked to keep them.
finishScene = function(lifts)
	for host, bucket in pairs(type(lifts) == "table" and lifts or {}) do
		local shared = S.shared[host]
		if shared and host.Parent then
			local state = { lift = bucket }
			local scope = S.scopes[host]
			local repairs = scope and S.zfModels and S.zfModels[scope]
			if type(repairs) == "table" then state.zf = repairs end
			local old = host.Generator
			local module = generatorFor(host, shared, state)
			if module ~= old then
				local ok, err = pcall(function()
					local pivot = host:GetPivot()
					local low, high = partsIn(host, pivot)
					local readScale, scale = pcall(host.GetScale, host)
					if not readScale or type(scale) ~= "number" or scale <= EPS then scale = 1 end
					if low.X <= high.X then host.Size = (high - low) / scale end
					host.Generator = module
					if not forceGeneration(host) then
						error("generation did not finish: " .. tostring(host.GenerationError), 0)
					end
					host.WorldPivot = pivot
					if low.X <= high.X then host:PivotTo(pivot * CFrame.new((low + high) / 2)) end
				end)
				if ok then
					if old and old ~= shared then
						local name = old.Name
						old:Destroy()
						module.Name = name
					end
					labelScope(host)
				else
					issue("liftSurfaces", ("%s could not take its lift: %s"):format(host.Name, tostring(err)))
				end
			end
		end
	end
	if S.root and not marked(TRACE_MARKER) then
		for _, item in ipairs(S.root:GetDescendants()) do
			if item:IsA("BasePart") then
				for _, attribute in ipairs(BUILD_ATTRIBUTES) do
					if item:GetAttribute(attribute) ~= nil then item:SetAttribute(attribute, nil) end
				end
			end
		end
	end
	S.building = false
	setMarker(BUILD_MARKER, false)
end

-- Build into container with a fresh palette, style, and transform scope.
-- Generators use this instead of SG.scene. attributes is what SG.attributes
-- reads back while build runs, and size (the generator's parameters.Size) is
-- what SG.size reads.
--
-- The object is built at its default size first. If it asked SG.size for its
-- box and that box is not Size, a builder resized it in Studio or the scene
-- asked for a size, so it is built again to fit Size. Either way the parts are
-- then centred on the container's origin, which is the ProceduralModel's pivot.
function SG.into(container, build, attributes, size)
	if typeof(container) ~= "Instance" then
		issue("into", "container must be an Instance; skipping build")
		return nil
	end
	if type(build) ~= "function" then
		issue("into", "build must be a function; skipping build")
		return nil
	end
	local saved = {
		S.parents, S.xforms, S.palette, S.protos, S.lookByKey, S.style,
		S.generating, S.intoWarnings, S.zfIndex, S.zfScope, S.zfActive, S.liftActive,
		S.generatingSize, S.plainSize, S.intoTrace, S.sizeAsked, S.fitSize,
	}
	S.generating = type(attributes) == "table" and attributes or {}
	S.generatingSize = typeof(size) == "Vector3" and size or nil
	S.plainSize = nil
	S.intoTrace = nil
	S.intoTrace = tracing()
	-- SG.bind leaves the wrapper's repairs for this generation. The scene's own
	-- plain-Model fallback leaves its scope too.
	local bound = type(S.bound) == "table" and S.bound or {}
	S.bound = nil
	S.zfScope = type(bound.scope) == "string" and bound.scope or nil
	S.zfActive = type(bound.zf) == "table" and bound.zf or nil
	S.liftActive = type(bound.lift) == "table" and bound.lift or nil
	local before = {}
	for _, child in ipairs(container:GetChildren()) do before[child] = true end
	local function run(fit)
		for _, child in ipairs(container:GetChildren()) do
			if not before[child] then child:Destroy() end
		end
		S.parents, S.xforms, S.palette, S.protos, S.lookByKey = { container }, { CFrame.identity }, {}, {}, {}
		S.style = { nil, Enum.Material.SmoothPlastic, 0, true }
		S.intoWarnings = {}
		S.zfIndex = 0
		S.sizeAsked = false
		S.fitSize = fit
		return pcall(build, container)
	end
	local ok, err = run(nil)
	local count, low, high = measureParts(container)
	-- A zero Size asks for the default build; the measurement host uses it.
	local given = S.generatingSize
	if given and math.max(given.X, given.Y, given.Z) <= EPS then given = nil end
	if ok and S.sizeAsked and given and count > 0 then
		local delta = given - (high - low)
		if math.max(math.abs(delta.X), math.abs(delta.Y), math.abs(delta.Z)) > SIZE_TOLERANCE then
			ok, err = run(given:Max(Vector3.new(MIN_SIZE, MIN_SIZE, MIN_SIZE)))
			count, low, high = measureParts(container)
		end
	end
	S.lastCenter, S.lastExtent = nil, nil
	if count > 0 then
		local centre = (low + high) / 2
		S.lastCenter, S.lastExtent = centre, high - low
		recentre(container, centre)
	end
	local warnings = S.intoWarnings
	S.parents, S.xforms, S.palette, S.protos, S.lookByKey, S.style = saved[1], saved[2], saved[3], saved[4], saved[5], saved[6]
	S.generating, S.intoWarnings = saved[7], saved[8]
	S.zfIndex, S.zfScope, S.zfActive, S.liftActive = saved[9], saved[10], saved[11], saved[12]
	S.generatingSize, S.plainSize, S.intoTrace = saved[13], saved[14], saved[15]
	S.sizeAsked, S.fitSize = saved[16], saved[17]
	if not ok then
		table.insert(warnings, "SG.into: build stopped early: " .. tostring(err))
		issue("into", "build stopped early: " .. tostring(err))
	end
	if S.intoWarnings then
		for _, text in ipairs(warnings) do table.insert(S.intoWarnings, text) end
	else
		for _, text in ipairs(warnings) do logWarning(text) end
	end
	return container
end

-- Reserved for wrapper Generators. A ProceduralModel whose parts were repaired
-- or lifted has its own Generator in ServerStorage.SceneGeneration.Generators
-- .Instances that binds those repairs to the shared Generator:
--   return SG.bind(require(script.Parent.Parent.Objects.Stall), { zf = {...}, lift = {...} })
-- so every generation, in Studio as on RCC, builds the repaired object.
function SG.bind(definition, state)
	if type(definition) ~= "table" or type(definition.OnGenerate) ~= "function" then
		error("SG.bind needs a Generator definition with an OnGenerate function", 2)
	end
	state = type(state) == "table" and state or {}
	local bound = {}
	for key, value in pairs(definition) do bound[key] = value end
	bound.OnGenerate = function(parameters, container)
		local saved = S.bound
		S.bound = state
		local ok, err = pcall(definition.OnGenerate, parameters, container)
		S.bound = saved
		if not ok then error(err, 0) end
	end
	return bound
end

-- The Attributes a generator or scene element declares, with the values the
-- current generation was given. Outside a generation it returns defaults.
function SG.attributes(defaults)
	if type(defaults) ~= "table" then
		issue("attributes", "defaults must be a table")
		return {}
	end
	local current = S.generating or S.plainAttributes
	if not current then return defaults end
	local out = {}
	for name, value in pairs(defaults) do
		local given = current[name]
		out[name] = (given ~= nil and typeof(given) == typeof(value)) and given or value
	end
	return out
end

-- The box an object builds to fit: default, unless SG.into is rebuilding it to
-- fit a Size other than the box its default build measured.
function SG.size(default)
	if typeof(default) ~= "Vector3" then
		issue("size", "default must be a Vector3; using 4 x 4 x 4")
		default = Vector3.new(4, 4, 4)
	end
	if S.plainSize then return S.plainSize end
	S.sizeAsked = true
	return S.fitSize or default
end

local function numbers(value)
	if type(value) ~= "table" then return nil end
	local out = {}
	for i = 1, #value do
		out[i] = tonumber(value[i])
		if out[i] == nil then return nil end
	end
	return out
end

-- A value of the same type as the generator's default, or nil.
local function coerceAttribute(default, value)
	local kind = typeof(default)
	if typeof(value) == kind then return value end
	if kind == "number" then return tonumber(value) end
	if kind == "boolean" and type(value) == "string" then
		local lowered = value:lower()
		if lowered == "true" then return true end
		if lowered == "false" then return false end
		return nil
	end
	if kind == "string" and (type(value) == "number" or type(value) == "boolean") then
		return tostring(value)
	end
	local v = numbers(value)
	if kind == "Color3" and v and #v == 3 then
		if v[1] > 1 or v[2] > 1 or v[3] > 1 then
			return Color3.fromRGB(math.clamp(v[1], 0, 255), math.clamp(v[2], 0, 255), math.clamp(v[3], 0, 255))
		end
		return Color3.new(v[1], v[2], v[3])
	end
	if kind == "Vector3" and v and #v == 3 then return Vector3.new(v[1], v[2], v[3]) end
	return nil
end

local function boundAttribute(api, label, name, schema, value)
	if type(schema) ~= "table" then return value end
	if type(value) == "number" then
		local low, high = tonumber(schema.min), tonumber(schema.max)
		local bounded = math.clamp(value, low or -math.huge, high or math.huge)
		if bounded ~= value then
			issue(api, ("%s attribute %s = %s is outside its range; using %s")
				:format(label, name, tostring(value), tostring(bounded)))
		end
		return bounded
	end
	if type(value) == "string" and type(schema.options) == "table" and #schema.options > 0
		and not table.find(schema.options, value) then
		issue(api, ("%s attribute %s = %q is not one of its options; using the default")
			:format(label, name, value))
		return nil
	end
	return value
end

-- Reserved for the trusted prelude. Installs SG itself as
-- ReplicatedStorage.SceneGeneration.SG and one Generator ModuleScript per
-- object type and scene element. Where a ModuleScript cannot be written, every
-- ProceduralModel is built as a plain Model from the same generator code.
function SG.generators(data)
	if S.generatorsLocked then
		issue("generators", "generators are already registered; ignoring replacement")
		return nil
	end
	if type(data) ~= "table" then
		issue("generators", "generator manifest must be a table")
		return nil
	end
	S.generatorsLocked = true
	S.generators, S.elements, S.prototypes = {}, {}, {}
	local objectFolder, elementFolder, prototypeFolder
	-- The SceneGeneration folder. Declared here so the DP install below can parent into it.
	local sceneFolder
	local installed, installError = pcall(function()
		local replicated = game:GetService("ReplicatedStorage")
		local server = game:GetService("ServerStorage")
		for _, holder in ipairs({ replicated, server }) do
			local old = holder:FindFirstChild("SceneGeneration")
			if old then old:Destroy() end
		end
		sceneFolder = Instance.new("Folder")
		sceneFolder.Name = "SceneGeneration"
		local looks = Instance.new("Configuration")
		looks.Name = "Looks"
		looks.Parent = sceneFolder
		generatorModule(sceneFolder, "SG", tostring(data.runtime or ""))
		sceneFolder.Parent = replicated
		local root = Instance.new("Folder")
		root.Name = "SceneGeneration"
		local generators = Instance.new("Folder")
		generators.Name = "Generators"
		generators.Parent = root
		objectFolder = Instance.new("Folder")
		objectFolder.Name = "Objects"
		objectFolder.Parent = generators
		elementFolder = Instance.new("Folder")
		elementFolder.Name = "Elements"
		elementFolder.Parent = generators
		prototypeFolder = Instance.new("Folder")
		prototypeFolder.Name = "Prototypes"
		prototypeFolder.Parent = generators
		local instanceFolder = Instance.new("Folder")
		instanceFolder.Name = "Instances"
		instanceFolder.Parent = generators
		S.instanceFolder = instanceFolder
		root.Parent = server
		S.looks, S.ownsLooks = looks, true
	end)
	local decalReady = false
	if not installed then
		objectFolder, elementFolder, prototypeFolder, S.instanceFolder = nil, nil, nil, nil
		issue("generators", "ProceduralModels are unavailable here; building plain Models: "
			.. tostring(installError))
	elseif type(data.decalRuntime) == "string" and data.decalRuntime ~= "" then
		-- Published decals. Generators require ReplicatedStorage.SceneGeneration.DP
		-- the same way they require SG. The scene script's own DP global is a
		-- different copy and is not visible inside a ModuleScript.
		local decalInstalled, decalError = pcall(generatorModule, sceneFolder, "DP", data.decalRuntime)
		decalReady = decalInstalled
		if not decalInstalled then
			issue("generators", "DP is unavailable; decal prototypes stay plain Models: "
				.. tostring(decalError))
		end
	end
	local function usesDecalModule(source)
		return type(source) == "string" and string.find(source, "SceneGeneration.DP", 1, true) ~= nil
	end
	for key, spec in pairs(type(data.objects) == "table" and data.objects or {}) do
		local entry = { key = tostring(key), variants = type(spec.variants) == "table" and spec.variants or {} }
		local ok, definition = pcall(spec.build)
		if ok and type(definition) == "table" and type(definition.OnGenerate) == "function" then
			definition.Attributes = type(definition.Attributes) == "table" and definition.Attributes or {}
			definition.Schema = type(definition.Schema) == "table" and definition.Schema or {}
			entry.definition = definition
		else
			issue("generators", ("generator %s did not load: %s"):format(entry.key, tostring(definition)))
		end
		if objectFolder and entry.definition then
			local made, module = pcall(generatorModule, objectFolder, entry.key, tostring(spec.source or ""))
			if made then
				entry.module = module
			else
				issue("generators", ("generator %s has no ModuleScript: %s"):format(entry.key, tostring(module)))
			end
		end
		S.generators[entry.key] = entry
	end
	for id, source in pairs(type(data.elements) == "table" and data.elements or {}) do
		S.elementSources[tostring(id)] = tostring(source)
		if elementFolder and (decalReady or not usesDecalModule(source)) then
			local made, module = pcall(generatorModule, elementFolder, tostring(id), tostring(source))
			if made then S.elements[tostring(id)] = module end
		end
	end
	for key, source in pairs(type(data.prototypes) == "table" and data.prototypes or {}) do
		if prototypeFolder and (decalReady or not usesDecalModule(source)) then
			local made, module = pcall(generatorModule, prototypeFolder, tostring(key), tostring(source))
			if made then S.prototypes[tostring(key)] = module end
		end
	end
	return nil
end

local function proceduralValues(api, label, entry, variant, attributes)
	local defaults, schema = entry.definition.Attributes, entry.definition.Schema
	local values = {}
	local fixed = type(variant) == "table" and type(variant.values) == "table" and variant.values or {}
	for name, raw in pairs(fixed) do
		local value = nil
		if defaults[name] ~= nil then
			value = coerceAttribute(defaults[name], raw)
			if value ~= nil then value = boundAttribute(api, label, name, schema[name], value) end
		end
		if value == nil then
			issue(api, ("%s variant value for %s does not fit the generator; ignoring it")
				:format(label, tostring(name)))
		else
			values[name] = value
		end
	end
	if attributes ~= nil and type(attributes) ~= "table" then
		issue(api, "attributes must be a table; ignoring them")
		attributes = nil
	end
	for name, raw in pairs(attributes or {}) do
		local rule = schema[name]
		if defaults[name] == nil then
			issue(api, ("%s has no attribute %s; ignoring it"):format(label, tostring(name)))
		elseif type(rule) == "table" and rule.shape and fixed[name] == nil then
			issue(api, ("%s attribute %s changes its shape; choose a variant instead")
				:format(label, tostring(name)))
		else
			local value = coerceAttribute(defaults[name], raw)
			if value ~= nil then value = boundAttribute(api, label, name, rule, value) end
			if value == nil then
				issue(api, ("%s attribute %s has the wrong type; ignoring it"):format(label, tostring(name)))
			else
				values[name] = value
			end
		end
	end
	return values
end

-- Place one ProceduralModel built by the generator registered as key.
-- variant names a measured shape ("default" when nil); cf is the centre of the
-- footprint on the ground; targetHeight sets one uniform scale; attributes may
-- only set style attributes. opts.size = {width, height, depth} rebuilds the
-- object to fit that box before targetHeight scales it.
function SG.procedural(key, variant, cf, targetHeight, attributes, opts)
	targetHeight = pos("procedural", targetHeight, "targetHeight")
	local fit = type(opts) == "table" and boxSize("procedural", opts.size) or nil
	local entry = S.generators[key]
	if not entry or not entry.definition then
		issue("procedural", ("generator %q is not registered; skipping object"):format(tostring(key)))
		return nil
	end
	variant = variant == nil and "default" or tostring(variant)
	local spec = entry.variants[variant]
	if type(spec) ~= "table" then
		issue("procedural", ("%s has no variant %q; using default"):format(entry.key, variant))
		variant, spec = "default", entry.variants.default
	end
	local extent = type(spec) == "table" and numbers(spec.extent)
	if not extent or #extent ~= 3 or extent[2] <= EPS then
		issue("procedural", ("%s variant %s has no measured size; skipping object"):format(entry.key, variant))
		return nil
	end
	local base = S.xforms[#S.xforms] * localCF("procedural", cf)
	local holder = parent("procedural")
	local name = nextName(holder, entry.key)
	local values = proceduralValues("procedural", name, entry, spec, attributes)
	local measured = Vector3.new(extent[1], extent[2], extent[3])
	local size = fit or measured
	local scale = targetHeight / size.Y
	if entry.module then
		local made
		local ok, err = pcall(function()
			made = Instance.new("ProceduralModel")
			made.Name = name
			made.Size = size
			for attribute, value in pairs(values) do made:SetAttribute(attribute, value) end
			made.Parent = holder
			local _, repairs = bindZFight(made)
			made.Generator = generatorFor(made, entry.module, repairs and { zf = repairs } or nil)
			made.WorldPivot = CFrame.identity
			if math.abs(scale - 1) > EPS then made:ScaleTo(scale) end
			generateAtOrigin(made)
			seatGenerated(made, base)
			labelScope(made)
		end)
		if ok then return made end
		if made then made:Destroy() end
		issue("procedural", ("%s is a plain Model because ProceduralModel failed: %s"):format(name, tostring(err)))
	end
	local model
	local ok, err = pcall(function()
		local merged = {}
		for attribute, value in pairs(entry.definition.Attributes) do merged[attribute] = value end
		for attribute, value in pairs(values) do merged[attribute] = value end
		model = Instance.new("Model")
		model.Name = name
		for attribute, value in pairs(merged) do pcall(model.SetAttribute, model, attribute, value) end
		local scope, repairs = bindZFight(model)
		local generated = Instance.new("Folder")
		generated.Name = "Generated"
		generated.Parent = model
		model.Parent = holder
		S.bound = { scope = scope, zf = repairs }
		local generatedOk, generateError = pcall(entry.definition.OnGenerate,
			{ Attributes = merged, Size = size, Pause = function() end }, generated)
		S.bound = nil
		if not generatedOk then error(generateError, 0) end
		if math.abs(scale - 1) > EPS then model:ScaleTo(scale) end
		seatGenerated(model, base)
	end)
	if not ok then
		if model then model:Destroy() end
		issue("procedural", ("%s could not be generated; skipping object: %s"):format(name, tostring(err)))
		return nil
	end
	return model
end

-- SG.procedural seated on the ground at (x, z) facing yaw, like SG.meshOn.
-- opts matches SG.seat; the footprint defaults to the scaled measured base.
function SG.proceduralOn(key, variant, x, z, yaw, targetHeight, attributes, opts)
	opts = type(opts) == "table" and opts or {}
	local entry = S.generators[key]
	local spec = entry and (entry.variants[variant == nil and "default" or tostring(variant)] or entry.variants.default)
	local extent = type(spec) == "table" and numbers(spec.extent)
	local fit = boxSize("proceduralOn", opts.size)
	if fit then extent = { fit.X, fit.Y, fit.Z } end
	if opts.footprint == nil and opts.y == nil and extent and #extent == 3 and extent[2] > EPS then
		local scale = pos("proceduralOn", targetHeight, "targetHeight") / extent[2]
		local seated = {}
		for k, v in pairs(opts) do seated[k] = v end
		seated.footprint = { math.max(extent[1] * scale, MIN_SIZE), math.max(extent[3] * scale, MIN_SIZE) }
		opts = seated
	end
	local cf = seatWorld("proceduralOn", key, x, z, yaw, opts)
	local model = SG.procedural(key, variant, cf, targetHeight, attributes, fit and { size = fit } or nil)
	if opts.pad then padUnder("proceduralOn", model, cf, opts) end
	return model
end

-- A scene element (road, path, fence, river, plaza, floor) or any other object
-- built from SG primitives, as its own ProceduralModel. build uses world
-- coordinates and may call SG.attributes once for its style Attributes. The
-- prelude registers a Generator made from the same code; without one, build
-- runs here as an ordinary group.
function SG.element(name, build)
	if type(name) ~= "string" or name == "" then
		issue("element", "name must be a non-empty string; using Element")
		name = "Element"
	end
	if type(build) ~= "function" then
		issue("element", "build must be a function; skipping element")
		return nil
	end
	local label = name:match("([^/]+)$") or name
	local module = S.elements[name]
	if module then
		-- The Generator must not edit the Terrain, since it regenerates whenever a
		-- builder retunes it. An element that grades a road or a pad runs once
		-- here first, into a scratch Model, to grade and store the result the
		-- Generator then builds from. Every element is then built once more as
		-- scratch to find where its parts are, since its generation is centred on
		-- them and so cannot say where in the world it belongs.
		local source = S.elementSources[name]
		local graded = not S.generating and type(source) == "string"
			and (source:find("SG%.road") or source:find("pad%s*=")) ~= nil
		if graded then
			local scratch = Instance.new("Model")
			S.gradePass = true
			SG.into(scratch, build)
			S.gradePass = false
			scratch:Destroy()
		end
		local scratch = Instance.new("Model")
		SG.into(scratch, build)
		local centre, extent = S.lastCenter, S.lastExtent
		scratch:Destroy()
		local holder = parent("element")
		local xform = S.xforms[#S.xforms]
		local made
		local ok, err = pcall(function()
			if not centre and graded then
				-- An unpaved path lives in the graded Terrain and builds no parts.
				made = false
				return
			end
			if not centre then error("generated no parts") end
			made = Instance.new("ProceduralModel")
			made.Name = label
			made.Size = extent
			made.Parent = holder
			local _, repairs = bindZFight(made)
			made.Generator = generatorFor(made, module, repairs and { zf = repairs } or nil)
			generateAtOrigin(made)
			if measureParts(made) == 0 then error("generated no parts") end
			matchSize(made)
			made:PivotTo(xform * CFrame.new(centre))
			labelScope(made)
		end)
		if ok and made == false then
			local empty = Instance.new("Model")
			empty.Name = label
			empty.Parent = holder
			return empty
		end
		if ok then return made end
		if made then made:Destroy() end
		issue("element", ("%s is a plain Model because ProceduralModel failed: %s"):format(name, tostring(err)))
	end
	return scoped("element", label, nil, build)
end

-- Terrain: height-field writer, noise and distance helpers for landscapes.

local TERRAIN_VOXEL = 4
local TERRAIN_CHUNK = 32 -- voxels per side in one WriteVoxels call
local TERRAIN_STAND_IN_CELLS = 5000 -- RCC stand-in parts, under the proxy's 12k cap
-- The isosurface sits 2 studs (1.75 to 2 on slopes) above the filled height,
-- measured in Studio; writing that much lower puts the surface at the height asked for.
-- Water shows no such offset: its surface lands where it is filled.
local TERRAIN_BLEED = 2
-- One-octave math.noise has a standard deviation of about 0.27 and peaks near
-- +/-0.98; dividing by this keeps the normalised sum inside -1..1.
local NOISE_PEAK = 0.9

local function terrainMaterial(api, value, fallback, cache)
	if value == nil then return fallback end
	local hit = cache[value]
	if hit then return hit end
	local material = resolveMaterial(api, value) or fallback
	cache[value] = material
	return material
end

function SG.terrainField(x0, z0, x1, z1, sample, opts)
	local api = "terrainField"
	if type(sample) ~= "function" then
		issue(api, "sample must be a function(x, z) returning height, material, waterLevel; skipping call")
		return
	end
	opts = type(opts) == "table" and opts or {}
	x0, z0 = num(api, x0, "x0"), num(api, z0, "z0")
	x1, z1 = num(api, x1, "x1"), num(api, z1, "z1")
	if x1 < x0 then x0, x1 = x1, x0 end
	if z1 < z0 then z0, z1 = z1, z0 end
	x0, z0 = math.floor(x0 / TERRAIN_VOXEL) * TERRAIN_VOXEL, math.floor(z0 / TERRAIN_VOXEL) * TERRAIN_VOXEL
	x1, z1 = math.ceil(x1 / TERRAIN_VOXEL) * TERRAIN_VOXEL, math.ceil(z1 / TERRAIN_VOXEL) * TERRAIN_VOXEL
	if x1 - x0 < TERRAIN_VOXEL or z1 - z0 < TERRAIN_VOXEL then
		issue(api, "the rectangle is smaller than one 4-stud voxel; skipping call")
		return
	end
	local cache = {}
	local ground = terrainMaterial(api, "Ground", Enum.Material.Ground, cache)
	local under = opts.under ~= nil and terrainMaterial(api, opts.under, nil, cache) or nil
	local underDepth = opts.underDepth ~= nil and pos(api, opts.underDepth, "underDepth") or 8
	-- sample may return a material function(y, depth) instead of a name; it is
	-- called per voxel with the voxel's centre y and its depth below the surface.
	local layerFailed = false
	local function layer(fn, y, depth)
		local ok, value = pcall(fn, y, depth)
		if not ok then
			if not layerFailed then
				issue(api, ("material function failed: %s; using Ground"):format(tostring(value)))
				layerFailed = true
			end
			return ground
		end
		return terrainMaterial(api, value, ground, cache)
	end

	-- In RCC the Terrain is a part-building proxy (a table, not an Instance).
	-- There one coarse box per cell stands in for the voxels.
	local terrain = workspace.Terrain
	local standIn = typeof(terrain) ~= "Instance"
	local step = TERRAIN_VOXEL
	if standIn then
		local columns = (x1 - x0) * (z1 - z0) / (TERRAIN_VOXEL * TERRAIN_VOXEL)
		step = TERRAIN_VOXEL * math.max(1, math.ceil(math.sqrt(columns / TERRAIN_STAND_IN_CELLS)))
	end
	local nx, nz = math.ceil((x1 - x0) / step), math.ceil((z1 - z0) / step)

	local heights, materials, waters = {}, {}, {}
	local lowest, highest = math.huge, -math.huge
	local badHeight = false
	for i = 1, nx do
		local x = x0 + (i - 0.5) * step
		for k = 1, nz do
			local z = z0 + (k - 0.5) * step
			local ok, h, m, w = pcall(sample, x, z)
			if not ok then
				issue(api, ("sample(%g, %g) failed: %s; skipping call"):format(x, z, tostring(h)))
				return
			end
			h = tonumber(h)
			if h == nil or h ~= h or math.abs(h) == math.huge then
				badHeight = true
				h = 0
			end
			w = tonumber(w)
			if w ~= nil and (w ~= w or math.abs(w) == math.huge) then w = nil end
			local index = (i - 1) * nz + k
			heights[index] = h
			materials[index] = type(m) == "function" and m or terrainMaterial(api, m, ground, cache)
			waters[index] = w
			lowest = math.min(lowest, h)
			highest = math.max(highest, h, w or h)
		end
	end
	if badHeight then
		issue(api, "sample returned a height that is not a finite number; using 0 there")
	end
	local bottom = opts.bottom ~= nil and num(api, opts.bottom, "bottom") or (lowest - underDepth - 8)
	bottom = math.floor(bottom / TERRAIN_VOXEL) * TERRAIN_VOXEL
	local top = math.ceil((highest + TERRAIN_VOXEL) / TERRAIN_VOXEL) * TERRAIN_VOXEL

	if standIn then
		for i = 1, nx do
			local x = x0 + (i - 0.5) * step
			for k = 1, nz do
				local z = z0 + (k - 0.5) * step
				local index = (i - 1) * nz + k
				local h, m, w = heights[index], materials[index], waters[index]
				if type(m) == "function" then
					m = layer(m, h - TERRAIN_VOXEL / 2, TERRAIN_VOXEL / 2)
				end
				if h > bottom then
					terrain:FillBlock(CFrame.new(x, (bottom + h) / 2, z), Vector3.new(step, h - bottom, step), m)
				end
				if w and w > math.max(h, bottom) then
					local base = math.max(h, bottom)
					terrain:FillBlock(CFrame.new(x, (base + w) / 2, z), Vector3.new(step, w - base, step), Enum.Material.Water)
				end
			end
		end
		return
	end

	local ny = (top - bottom) / TERRAIN_VOXEL
	local air, water = Enum.Material.Air, Enum.Material.Water
	for ci = 1, nx, TERRAIN_CHUNK do
		local sx = math.min(TERRAIN_CHUNK, nx - ci + 1)
		for ck = 1, nz, TERRAIN_CHUNK do
			local sz = math.min(TERRAIN_CHUNK, nz - ck + 1)
			local mats, occs = {}, {}
			for i = 1, sx do
				local mi, oi = {}, {}
				mats[i], occs[i] = mi, oi
				for j = 1, ny do
					mi[j], oi[j] = {}, {}
				end
				for k = 1, sz do
					local index = (ci + i - 2) * nz + (ck + k - 1)
					local surface, m, w = heights[index], materials[index], waters[index]
					local h = surface - TERRAIN_BLEED
					local layered = type(m) == "function"
					for j = 1, ny do
						local base = bottom + (j - 1) * TERRAIN_VOXEL
						local fill = math.clamp((h - base) / TERRAIN_VOXEL, 0, 1)
						local wet = w and math.clamp((w - base) / TERRAIN_VOXEL, 0, 1) or 0
						-- A voxel holds one material: a thin bed voxel (under half full)
						-- holding at least half a voxel more water than ground becomes
						-- water, so shallow water such as a flooded paddy is not lost.
						if fill > 0 and not (fill < 0.5 and wet >= fill + 0.5) then
							local centre = base + TERRAIN_VOXEL / 2
							if layered then
								mi[j][k] = layer(m, centre, surface - centre)
							else
								mi[j][k] = (under and base + TERRAIN_VOXEL <= h - underDepth) and under or m
							end
							oi[j][k] = fill
						elseif wet > 0 then
							mi[j][k] = water
							oi[j][k] = wet
						else
							mi[j][k] = air
							oi[j][k] = 0
						end
					end
				end
			end
			local lo = Vector3.new(x0 + (ci - 1) * TERRAIN_VOXEL, bottom, z0 + (ck - 1) * TERRAIN_VOXEL)
			local hi = lo + Vector3.new(sx * TERRAIN_VOXEL, top - bottom, sz * TERRAIN_VOXEL)
			terrain:WriteVoxels(Region3.new(lo, hi), TERRAIN_VOXEL, mats, occs)
		end
	end
	-- Raycasts only see a Terrain edit a few frames later.
	for _ = 1, 4 do
		task.wait()
	end
end

-- Grading. A paved road or a building pad reshapes the Terrain under itself.
-- A paved road then stands on a foundation deeper than the voxel surface can
-- miss by, so neither a gap nor the ground shows through it. An unpaved path
-- is the graded Terrain itself, painted with its material. A pad levels the
-- ground a little above the building's base, so the building always touches
-- it, and builds nothing. Grading runs only
-- while the scene builds; a generator that regenerates later rebuilds from the
-- stored result and never edits the Terrain.
local GRADE_SINK = 1 -- graded surface under a paved deck
local GRADE_EDGE = 2 -- graded core past the edge of a deck or footprint
local GRADE_SHOULDER = 10 -- blend back to the natural ground over this width
local GRADE_MATERIAL = "Ground"
local GRADE_STORE = "Grades"
local ROAD_SPACING = 4
local ROAD_LIFT = 0.25 -- deck top above the smoothed natural ground
local ROAD_DECK = 0.4
local ROAD_DEPTH = 6
-- A road that crosses an earlier one sits this far under it, beyond the band
-- the face audit treats as coplanar.
local ROAD_CROSSING = 0.05
-- The voxel surface lands 0 to 0.13 studs under its target, so a pad aiming
-- this far above the base meets it flush to within about 0.15, never below.
local PAD_RISE = 0.13
-- How deep an unpaved path's material reaches, and the export proxy's
-- painted slab over a path column.
local PATH_PAINT_DEPTH = 2 * TERRAIN_VOXEL
local PATH_PROXY_THICKNESS = 0.2
local PATH_PROXY_LIFT = 0.05

local function gradeKey(x, z)
	return ("%d,%d"):format(math.floor(x / TERRAIN_VOXEL), math.floor(z / TERRAIN_VOXEL))
end

local function gradeStore(create)
	local ok, store = pcall(function()
		local shared = game:GetService("ReplicatedStorage"):FindFirstChild("SceneGeneration")
		if not shared then return nil end
		local found = shared:FindFirstChild(GRADE_STORE)
		if not found and create then
			found = Instance.new("Configuration")
			found.Name = GRADE_STORE
			found.Parent = shared
		end
		return found
	end)
	return ok and store or nil
end

local function grading()
	return S.gradePass or not S.generating
end

-- Reshape the Terrain columns of a rectangle. target(x, z) returns dist,
-- surface, deck, paint: dist <= 0 inside the core, the graded surface there,
-- the deck or floor height the core carries, and whether the column is part of
-- an unpaved path whose top takes the paint material. The shoulder blends back
-- to the natural ground. A column an earlier road or pad already graded keeps
-- that grade in a shoulder, and in a core takes the lower of the two surfaces.
local function gradeTerrain(api, x0, z0, x1, z1, shoulder, material, target, paint)
	x0, z0 = math.floor(x0 / TERRAIN_VOXEL) * TERRAIN_VOXEL, math.floor(z0 / TERRAIN_VOXEL) * TERRAIN_VOXEL
	x1, z1 = math.ceil(x1 / TERRAIN_VOXEL) * TERRAIN_VOXEL, math.ceil(z1 / TERRAIN_VOXEL) * TERRAIN_VOXEL
	local nx, nz = (x1 - x0) / TERRAIN_VOXEL, (z1 - z0) / TERRAIN_VOXEL
	local supports = { terrainSupport() }
	local plans, low, high = {}, math.huge, -math.huge
	for i = 1, nx do
		local x = x0 + (i - 0.5) * TERRAIN_VOXEL
		for k = 1, nz do
			local z = z0 + (k - 0.5) * TERRAIN_VOXEL
			local dist, surface, deck, painted = target(x, z)
			if dist and dist < shoulder then
				local key = gradeKey(x, z)
				local locked = S.gradeCols[key]
				local natural = raycastSupport(x, z, supports, true)
				local wanted
				if dist <= 0 then
					wanted = locked and math.min(surface, locked.surface) or surface
					S.gradeCols[key] = { surface = wanted, deck = locked and math.max(deck, locked.deck) or deck }
				elseif not locked and natural then
					local u = dist / shoulder
					u = u * u * (3 - 2 * u)
					wanted = surface + (natural - surface) * u
				end
				if wanted and natural then
					plans[(i - 1) * nz + k] = {
						target = wanted, core = dist <= 0, paint = paint ~= nil and painted and dist <= 0,
					}
					low = math.min(low, wanted, natural)
					high = math.max(high, wanted, natural)
				end
			end
		end
	end
	if low == math.huge then return end

	-- In RCC the Terrain is the export proxy's parts. Cut the blocks a core
	-- passes through down to its surface so the export matches Studio.
	local terrain = workspace.Terrain
	if typeof(terrain) ~= "Instance" then
		local folder = workspace:FindFirstChild("I2LFakedTerrain")
		for _, part in ipairs(folder and folder:GetChildren() or {}) do
			if part:IsA("Part") and part.Shape == Enum.PartType.Block and part.Material ~= Enum.Material.Glass then
				local p = part.Position
				local i = math.floor((p.X - x0) / TERRAIN_VOXEL) + 1
				local k = math.floor((p.Z - z0) / TERRAIN_VOXEL) + 1
				local plan = i >= 1 and i <= nx and k >= 1 and k <= nz and plans[(i - 1) * nz + k]
				local bottom = p.Y - part.Size.Y / 2
				if plan and plan.core and p.Y + part.Size.Y / 2 > plan.target and plan.target - bottom > 0.05 then
					part.Size = Vector3.new(part.Size.X, plan.target - bottom, part.Size.Z)
					part.CFrame = CFrame.new(p.X, (bottom + plan.target) / 2, p.Z)
				end
			end
		end
		-- A proxy block can span many columns, so a path is shown as a thin slab
		-- of its material over each painted column rather than by recolouring.
		if paint and terrain and type(terrain.FillBlock) == "function" then
			for i = 1, nx do
				for k = 1, nz do
					local plan = plans[(i - 1) * nz + k]
					if plan and plan.paint then
						local top = plan.target + PATH_PROXY_LIFT
						pcall(terrain.FillBlock, terrain,
							CFrame.new(x0 + (i - 0.5) * TERRAIN_VOXEL, top - PATH_PROXY_THICKNESS / 2, z0 + (k - 0.5) * TERRAIN_VOXEL),
							Vector3.new(TERRAIN_VOXEL, PATH_PROXY_THICKNESS, TERRAIN_VOXEL), paint)
					end
				end
			end
		end
		return
	end

	local bottom = math.floor((low - 12) / TERRAIN_VOXEL) * TERRAIN_VOXEL
	local top = math.ceil((high + 8) / TERRAIN_VOXEL) * TERRAIN_VOXEL
	local ny = (top - bottom) / TERRAIN_VOXEL
	local air, water, grass = Enum.Material.Air, Enum.Material.Water, Enum.Material.Grass
	local bare = terrainMaterial(api, material, Enum.Material.Ground, {})
	if bare == grass then bare = Enum.Material.Ground end
	for ci = 1, nx, TERRAIN_CHUNK do
		local sx = math.min(TERRAIN_CHUNK, nx - ci + 1)
		for ck = 1, nz, TERRAIN_CHUNK do
			local sz = math.min(TERRAIN_CHUNK, nz - ck + 1)
			local touched = false
			for i = 1, sx do
				for k = 1, sz do
					if plans[(ci + i - 2) * nz + (ck + k - 1)] then touched = true end
				end
			end
			if touched then
				local lo = Vector3.new(x0 + (ci - 1) * TERRAIN_VOXEL, bottom, z0 + (ck - 1) * TERRAIN_VOXEL)
				local hi = lo + Vector3.new(sx * TERRAIN_VOXEL, top - bottom, sz * TERRAIN_VOXEL)
				local region = Region3.new(lo, hi)
				local mats, occs = terrain:ReadVoxels(region, TERRAIN_VOXEL)
				for i = 1, sx do
					for k = 1, sz do
						local plan = plans[(ci + i - 2) * nz + (ck + k - 1)]
						if plan then
							local surfaceMaterial = bare
							for j = ny, 1, -1 do
								local m = mats[i][j][k]
								if m ~= air and m ~= water then
									surfaceMaterial = m
									break
								end
							end
							-- Grass blades poke through whatever covers them.
							if plan.core and surfaceMaterial == grass then surfaceMaterial = bare end
							local h = plan.target - TERRAIN_BLEED
							for j = 1, ny do
								local fill = math.clamp((h - (bottom + (j - 1) * TERRAIN_VOXEL)) / TERRAIN_VOXEL, 0, 1)
								local m = mats[i][j][k]
								if fill > 0 then
									local solid = (m ~= air and m ~= water) and m or surfaceMaterial
									if plan.core and solid == grass then solid = bare end
									if plan.paint and h - (bottom + (j - 1) * TERRAIN_VOXEL) <= PATH_PAINT_DEPTH then
										solid = paint
									end
									mats[i][j][k], occs[i][j][k] = solid, fill
								elseif m ~= water then
									mats[i][j][k], occs[i][j][k] = air, 0
								end
							end
						end
					end
				end
				terrain:WriteVoxels(region, TERRAIN_VOXEL, mats, occs)
			end
		end
	end
	for _ = 1, 4 do
		task.wait()
	end
end

local function markGraded(list, into)
	local trace = tracing()
	for _, part in ipairs(list) do
		if typeof(part) == "Instance" then
			if trace then pcall(part.SetAttribute, part, GRADED_ATTRIBUTE, true) end
			into[#into + 1] = part
		end
	end
end

-- The natural ground at a column: the Terrain, or the water surface over it.
local function naturalHeight(x, z)
	local supports = { terrainSupport() }
	local ground = raycastSupport(x, z, supports, true)
	local wet = raycastSupport(x, z, supports, false)
	if ground and wet and wet > ground then return wet + ROAD_LIFT end
	return ground
end

-- The centre line every ROAD_SPACING studs, keeping each given vertex.
local function roadSamples(pts)
	local out = { pts[1] }
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local run = Vector3.new(b.X - a.X, 0, b.Z - a.Z).Magnitude
		if run > EPS then
			local n = math.max(1, math.ceil(run / ROAD_SPACING))
			for s = 1, n do
				out[#out + 1] = a:Lerp(b, s / n)
			end
		end
	end
	return out
end

-- Deck heights along the centre line: the natural ground across the road's
-- width, smoothed along it. Where an earlier road's graded core lies under a
-- sample, the height is pinned just under that road's deck, so a crossing meets
-- the road it crosses instead of stepping up or down to it.
local function roadProfile(api, pts, width, opts)
	local samples = roadSamples(pts)
	local n = #samples
	local hw = width / 2
	local heights, pinned = {}, {}
	for i, s in ipairs(samples) do
		local a, b = samples[math.max(1, i - 1)], samples[math.min(n, i + 1)]
		local along = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
		local side = along.Magnitude > EPS and Vector3.yAxis:Cross(along.Unit) * hw * 0.8 or Vector3.zero
		local total, count = 0, 0
		for _, offset in ipairs({ Vector3.zero, side, -side }) do
			local y = naturalHeight(s.X + offset.X, s.Z + offset.Z)
			if y then
				total += y
				count += 1
			end
		end
		heights[i] = count > 0 and total / count + (opts.foundation == false and 0 or ROAD_LIFT) or s.Y
		local locked = S.gradeCols[gradeKey(s.X, s.Z)]
		if locked then pinned[i] = locked.deck - ROAD_CROSSING end
	end
	local reach = opts.smooth ~= nil and math.max(0, num(api, opts.smooth, "smooth")) or math.max(16, width * 2)
	local radius = math.ceil(reach / ROAD_SPACING)
	for _ = 1, radius > 0 and 3 or 0 do
		local prefix = { 0 }
		for i = 1, n do prefix[i + 1] = prefix[i] + heights[i] end
		local smoothed = {}
		for i = 1, n do
			local a, b = math.max(1, i - radius), math.min(n, i + radius)
			smoothed[i] = pinned[i] or (prefix[b + 1] - prefix[a]) / (b - a + 1)
		end
		heights = smoothed
	end
	local profile = {}
	for i, s in ipairs(samples) do profile[i] = Vector3.new(s.X, pinned[i] or heights[i], s.Z) end
	return profile
end

local function gradeRoad(api, profile, width, opts)
	local hw = width / 2
	local shoulder = opts.shoulder ~= nil and math.max(0, num(api, opts.shoulder, "shoulder")) or GRADE_SHOULDER
	local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
	for _, p in ipairs(profile) do
		x0, z0 = math.min(x0, p.X), math.min(z0, p.Z)
		x1, z1 = math.max(x1, p.X), math.max(z1, p.Z)
	end
	local margin = hw + GRADE_EDGE + shoulder + TERRAIN_VOXEL
	-- An unpaved path is the ground itself: graded to its profile and painted
	-- with its material at least one voxel column wide.
	local unpaved = opts.foundation == false
	local paint = unpaved and terrainMaterial(api, opts.material or GRADE_MATERIAL, Enum.Material.Ground, {}) or nil
	if paint == Enum.Material.Water or paint == Enum.Material.Air then paint = Enum.Material.Ground end
	local painted = math.max(hw, TERRAIN_VOXEL / 2)
	gradeTerrain(api, x0 - margin, z0 - margin, x1 + margin, z1 + margin, shoulder, opts.material or GRADE_MATERIAL,
		function(x, z)
			local best, deck = math.huge, profile[1].Y
			for i = 1, #profile - 1 do
				local a, b = profile[i], profile[i + 1]
				local dx, dz = b.X - a.X, b.Z - a.Z
				local length2 = dx * dx + dz * dz
				local t = length2 > 0 and math.clamp(((x - a.X) * dx + (z - a.Z) * dz) / length2, 0, 1) or 0
				local d = (x - a.X - dx * t) ^ 2 + (z - a.Z - dz * t) ^ 2
				if d < best then best, deck = d, a.Y + (b.Y - a.Y) * t end
			end
			local distance = math.sqrt(best)
			return distance - hw - GRADE_EDGE, unpaved and deck or deck - GRADE_SINK, deck,
				unpaved and distance <= painted
		end, paint)
end

-- Keep only the profile points that bend the line by more than tolerance.
local function simplifyLine(line, tolerance)
	local keep = { [1] = true, [#line] = true }
	local function walk(first, last)
		local a, b = line[first], line[last]
		local ab = b - a
		local length2 = ab:Dot(ab)
		local worst, index = tolerance, nil
		for i = first + 1, last - 1 do
			local t = length2 > 0 and math.clamp((line[i] - a):Dot(ab) / length2, 0, 1) or 0
			local d = (line[i] - (a + ab * t)).Magnitude
			if d > worst then worst, index = d, i end
		end
		if index then
			keep[index] = true
			walk(first, index)
			walk(index, last)
		end
	end
	walk(1, #line)
	local out = {}
	for i, p in ipairs(line) do
		if keep[i] then out[#out + 1] = p end
	end
	return out
end

-- A deck ROAD_DECK thick whose top follows the profile, mitred at each bend,
-- over a foundation down to depth below it: the same triangles in the base
-- key, offset along each face's normal so the two meet without overlapping.
local function buildDeck(api, profile, width, key, opts)
	local line = simplifyLine(profile, 0.05)
	local hw = width / 2
	local depth = math.max(ROAD_DECK + 0.5, opts.depth ~= nil and pos(api, opts.depth, "depth") or ROAD_DEPTH)
	local baseKey = opts.base or key
	local function flat(v)
		local f = Vector3.new(v.X, 0, v.Z)
		return f.Magnitude > EPS and f.Unit or nil
	end
	local left, right, made = {}, {}, {}
	for i, p in ipairs(line) do
		local incoming = flat(p - line[math.max(1, i - 1)]) or flat(line[math.min(#line, i + 1)] - p) or Vector3.xAxis
		local outgoing = flat(line[math.min(#line, i + 1)] - p) or incoming
		local tangent = flat(incoming + outgoing) or outgoing
		local side = Vector3.yAxis:Cross(tangent).Unit
		local mitre = 1 / math.max(0.5, side:Dot(Vector3.yAxis:Cross(outgoing).Unit))
		left[i], right[i] = p - side * hw * mitre, p + side * hw * mitre
	end
	local drop = Vector3.new(0, ROAD_DECK / 2, 0)
	local function deck(list)
		if not tracing() then return list end
		for _, part in ipairs(list) do
			if typeof(part) == "Instance" then pcall(part.SetAttribute, part, ROAD_ATTRIBUTE, true) end
		end
		return list
	end
	local height = depth - ROAD_DECK
	local function slab(a, b, c)
		markGraded(deck(triangle(api, a - drop, b - drop, c - drop, ROAD_DECK, key)), made)
		local normal = (b - a):Cross(c - a)
		if normal.Magnitude <= EPS then return end
		normal = normal.Unit * (normal.Y < 0 and -1 or 1)
		local below = normal * ((ROAD_DECK + height) / 2)
		markGraded(triangle(api, a - drop - below, b - drop - below, c - drop - below, height, baseKey), made)
	end
	for i = 1, #line - 1 do
		local j = i + 1
		slab(left[i], right[i], right[j])
		slab(left[i], right[j], left[j])
	end
	return made
end

local function encodeProfile(profile)
	local out = {}
	for _, p in ipairs(profile) do
		out[#out + 1] = ("%.3f,%.3f,%.3f"):format(p.X, p.Y, p.Z)
	end
	return table.concat(out, ";")
end

local function decodeProfile(text)
	if type(text) ~= "string" then return nil end
	local out = {}
	for x, y, z in text:gmatch("([^,;]+),([^,;]+),([^,;]+)") do
		local px, py, pz = tonumber(x), tonumber(y), tonumber(z)
		if not (px and py and pz) then return nil end
		out[#out + 1] = Vector3.new(px, py, pz)
	end
	return #out >= 2 and out or nil
end

-- A road's identity is its centre line in plan and its width, not its heights,
-- which may have been read from the ground before or after grading.
local function roadKey(pts, width)
	local hash = 5381
	local function feed(value)
		for i = 1, #value do hash = (hash * 33 + string.byte(value, i)) % 4294967296 end
	end
	for _, p in ipairs(pts) do feed(("%.2f,%.2f;"):format(p.X, p.Z)) end
	feed(("%.2f"):format(width))
	return ("road_%08x"):format(hash)
end

-- A road, street, plaza strip or path along points ({x,y,z, ...}, as SG.curve
-- returns). The Terrain under it is graded to its profile, and an earlier road
-- it crosses keeps its height at the crossing. A paved road's deck stands on a
-- foundation; with opts.foundation = false the path is the graded Terrain
-- itself, painted with opts.material, and no part is built. y is used only
-- where there is no Terrain. Returns the top line as {x,y,z, ...}. opts: depth
-- (foundation below the deck top, default 6), shoulder (blend width, default
-- 10), smooth (studs of smoothing along the road), material (graded Terrain
-- under the core, and an unpaved path's surface; default Ground), base (key
-- for the foundation; default key), name (the deck's Model, default Road).
function SG.road(data, width, key, opts)
	local api = "road"
	local pts = points(api, data)
	if #pts < 2 then return nil end
	width = pos(api, width, "width")
	opts = type(opts) == "table" and opts or {}
	-- Profiles live in world space, which is what an element's build and its
	-- Generator both author in; the deck is built back in the caller's frame.
	local base = S.xforms[1]:Inverse() * S.xforms[#S.xforms]
	for i, p in ipairs(pts) do pts[i] = base * p end
	local id = roadKey(pts, width)
	local profile
	if grading() then
		profile = roadProfile(api, pts, width, opts)
		gradeRoad(api, profile, width, opts)
		S.gradeProfiles[id] = profile
		local store = gradeStore(true)
		if store then pcall(store.SetAttribute, store, id, encodeProfile(profile)) end
	else
		profile = S.gradeProfiles[id]
		if not profile then
			local store = gradeStore(false)
			profile = store and decodeProfile(store:GetAttribute(id)) or nil
		end
		if not profile then
			issue(api, "this road was not graded when the scene built; following the ground as it is")
			profile = roadProfile(api, pts, width, opts)
		end
	end
	local line = {}
	for i, p in ipairs(profile) do line[i] = base:PointToObjectSpace(p) end
	if not S.gradePass and opts.foundation ~= false then
		local name = type(opts.name) == "string" and opts.name ~= "" and opts.name or "Road"
		scoped(api, name, nil, function()
			buildDeck(api, line, width, key, opts)
		end)
	end
	local out = {}
	for _, p in ipairs(line) do
		out[#out + 1], out[#out + 2], out[#out + 3] = p.X, p.Y, p.Z
	end
	return out
end

-- Level the Terrain up to a seated object's base across its whole footprint,
-- carving a slope or filling a hollow. No part is built. The footprint is what
-- reaches down to the base, so a roof overhang does not widen it. opts.pad is
-- true or {shoulder, material}.
padUnder = function(api, model, cf, opts)
	if typeof(model) ~= "Instance" then return end
	local settings = type(opts.pad) == "table" and opts.pad or {}
	-- frame is the seat in world space; parts are measured from their place in
	-- the container's root frame.
	local root = S.xforms[1]
	local frame = root:Inverse() * S.xforms[#S.xforms] * cf
	local near = { math.huge, -math.huge, math.huge, -math.huge }
	local all = { math.huge, -math.huge, math.huge, -math.huge }
	local function grow(box, p)
		box[1], box[2] = math.min(box[1], p.X), math.max(box[2], p.X)
		box[3], box[4] = math.min(box[3], p.Z), math.max(box[4], p.Z)
	end
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("BasePart") then
			local half, corners, lowest = item.Size / 2, {}, math.huge
			for _, sx in ipairs({ -1, 1 }) do
				for _, sy in ipairs({ -1, 1 }) do
					for _, sz in ipairs({ -1, 1 }) do
						local corner = frame:PointToObjectSpace(root:PointToObjectSpace(
							item.CFrame:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))))
						corners[#corners + 1] = corner
						lowest = math.min(lowest, corner.Y)
					end
				end
			end
			for _, corner in ipairs(corners) do
				grow(all, corner)
				if lowest <= 1 then grow(near, corner) end
			end
		end
	end
	local box = near[1] < math.huge and near or all
	if box[1] == math.huge then return end
	local cx, cz = (box[1] + box[2]) / 2, (box[3] + box[4]) / 2
	local hx, hz = (box[2] - box[1]) / 2, (box[4] - box[3]) / 2
	if grading() then
		local shoulder = settings.shoulder ~= nil and math.max(0, num(api, settings.shoulder, "pad shoulder"))
			or GRADE_SHOULDER
		local floor = frame.Position.Y
		local reach = math.max(hx, hz) + GRADE_EDGE + shoulder + TERRAIN_VOXEL
		local centre = frame:PointToWorldSpace(Vector3.new(cx, 0, cz))
		gradeTerrain(api, centre.X - reach * 1.5, centre.Z - reach * 1.5, centre.X + reach * 1.5,
			centre.Z + reach * 1.5, shoulder, settings.material or GRADE_MATERIAL, function(x, z)
				local p = frame:PointToObjectSpace(Vector3.new(x, floor, z))
				local dx = math.abs(p.X - cx) - hx - GRADE_EDGE
				local dz = math.abs(p.Z - cz) - hz - GRADE_EDGE
				local outside = math.sqrt(math.max(dx, 0) ^ 2 + math.max(dz, 0) ^ 2)
				return outside > 0 and outside or math.max(dx, dz), floor + PAD_RISE, floor
			end)
	end
end

function SG.noise(x, z, scale, octaves, seed)
	local api = "noise"
	x, z = num(api, x, "x"), num(api, z, "z")
	scale = pos(api, scale or 64, "scale")
	octaves = math.min(8, octaves ~= nil and whole(api, octaves, "octaves") or 4)
	seed = seed ~= nil and num(api, seed, "seed") or 0
	local fx, fz = x / scale, z / scale
	-- Fractional offsets keep samples off the integer lattice, where math.noise is 0.
	local w = (seed % 4096) * 0.6180339 + 0.5
	local sum, amplitude, power = 0, 1, 0
	for o = 1, octaves do
		sum += amplitude * math.noise(fx + o * 13.37 + 0.31, fz - o * 7.91 + 0.73, w + o * 3.17)
		power += amplitude * amplitude
		amplitude *= 0.5
		fx *= 2
		fz *= 2
	end
	return math.clamp(sum / math.sqrt(power) / NOISE_PEAK, -1, 1)
end

function SG.pathDistance(data, x, z, stride)
	local api = "pathDistance"
	stride = stride == 3 and 3 or 2
	data = arr(api, data, stride)
	x, z = num(api, x, "x"), num(api, z, "z")
	local count = #data // stride
	if count == 0 then
		issue(api, "points must hold at least one point; returning math.huge")
		return math.huge, 0
	end
	local zOffset = stride - 1
	local ax, az = data[1], data[1 + zOffset]
	local best = math.sqrt((x - ax) ^ 2 + (z - az) ^ 2)
	local bestAlong, travelled = 0, 0
	for p = 2, count do
		local bx, bz = data[(p - 1) * stride + 1], data[(p - 1) * stride + 1 + zOffset]
		local dx, dz = bx - ax, bz - az
		local length2 = dx * dx + dz * dz
		local length = math.sqrt(length2)
		local t = length2 > 0 and math.clamp(((x - ax) * dx + (z - az) * dz) / length2, 0, 1) or 0
		local d = math.sqrt((x - ax - t * dx) ^ 2 + (z - az - t * dz) ^ 2)
		if d < best then
			best, bestAlong = d, travelled + t * length
		end
		travelled += length
		ax, az = bx, bz
	end
	return best, travelled > 0 and bestAlong / travelled or 0
end

function SG.blend(h, target, distance, inner, outer)
	local api = "blend"
	h, target = num(api, h, "h"), num(api, target, "target")
	distance = num(api, distance, "distance")
	inner, outer = num(api, inner, "inner"), num(api, outer, "outer")
	if outer < inner then inner, outer = outer, inner end
	if distance <= inner then return target end
	if distance >= outer then return h end
	local t = (outer - distance) / (outer - inner)
	t = t * t * (3 - 2 * t)
	return h + (target - h) * t
end

-- Edge noise is sampled on a circle of this radius in noise space, so the
-- outline wraps around without a seam.
local BLOB_NOISE_RADIUS = 1.6

function SG.ellipseDistance(x, z, cx, cz, rx, rz, roughness, seed)
	local api = "ellipseDistance"
	x, z = num(api, x, "x"), num(api, z, "z")
	cx, cz = num(api, cx, "cx"), num(api, cz, "cz")
	rx = pos(api, rx, "rx")
	rz = rz ~= nil and pos(api, rz, "rz") or rx
	roughness = roughness ~= nil and math.clamp(num(api, roughness, "roughness"), 0, 0.9) or 0
	local nx, nz = (x - cx) / rx, (z - cz) / rz
	local r = math.sqrt(nx * nx + nz * nz)
	if r == 0 or roughness == 0 then return r end
	local edge = 1 + roughness * SG.noise(nx / r * BLOB_NOISE_RADIUS, nz / r * BLOB_NOISE_RADIUS, 1, 3, seed)
	return r / edge
end

-- An SG function the model invented does not exist, and calling a nil field
-- would kill the whole scene on the spot. Every other SG mistake warns and
-- keeps building, so this one does too.
setmetatable(SG, {
	__index = function(_, key)
		return function()
			issue(tostring(key), "no such SG function; skipping call")
			return nil
		end
	end,
})

SG.assets({

})
SG.provenance({ Quality = "low", Source = "prompt" })
SG.generators({
	decalRuntime = [===[
local DecalPrimitives = {}
local function _dpDoc()
	return DecalPrimitives.dslModule
end
DecalPrimitives.dslModule = setmetatable({}, {
	__index = function()
		return _dpDoc
	end,
})
local NORMAL_ID_BY_NAME: { [string]: Enum.NormalId } = {
	Top = Enum.NormalId.Top,
	Bottom = Enum.NormalId.Bottom,
	Front = Enum.NormalId.Front,
	Back = Enum.NormalId.Back,
	Left = Enum.NormalId.Left,
	Right = Enum.NormalId.Right,
}

local function resolveNormalId(face: any): Enum.NormalId
	if face == nil then
		return Enum.NormalId.Front
	end
	if typeof(face) == "EnumItem" and (face :: EnumItem).EnumType == Enum.NormalId then
		return face :: Enum.NormalId
	end
	if type(face) == "string" and NORMAL_ID_BY_NAME[face] then
		return NORMAL_ID_BY_NAME[face]
	end
	error("addTexture: invalid 'face' (use Enum.NormalId.Top/Bottom/Front/Back/Left/Right)")
end

-- Marks an un-uploaded decal whose pixels travel in the decal manifest rather than
-- in a published asset. Generation rewrites DP.decal([[<svg>]]) to one of these
-- when it rasterizes without publishing; the host paints it from the manifest.
local DECAL_REF_PREFIX = "pgdecal:"

local function isDecalRef(textureId: any): boolean
	return type(textureId) == "string" and string.sub(textureId, 1, #DECAL_REF_PREFIX) == DECAL_REF_PREFIX
end

-- Accepts a numeric asset id, a content string, or a decal ref, and returns a
-- normalized identifier.
local function normalizeContentId(textureId: any): string
	if type(textureId) == "number" then
		return "rbxassetid://" .. tostring(math.floor(textureId))
	end
	if type(textureId) == "string" then
		if #textureId == 0 then
			error("addTexture: 'textureId' is empty")
		end
		-- Refs are manifest keys, not content; never coerce them to an asset id.
		if isDecalRef(textureId) then
			return textureId
		end
		if string.find(textureId, "://", 1, true) then
			return textureId
		end
		if string.match(textureId, "^%d+$") then
			return "rbxassetid://" .. textureId
		end
		return textureId
	end
	error("addTexture: 'textureId' must be an asset id (number) or content string")
end

-- Point a Texture at its imagery. A published asset goes straight onto .Texture.
-- The host replaces a decal ref with that asset id before this script is saved.
local function assignDecalContent(texture: Texture, contentId: string)
	if isDecalRef(contentId) then
		texture:SetAttribute("DecalRef", contentId)
	else
		texture.Texture = contentId
	end
end

-- Width/height of a BasePart face in studs, expressed along the Texture's U/V axes.
local function faceStudSize(part: BasePart, face: Enum.NormalId): (number, number)
	local s = part.Size
	if face == Enum.NormalId.Top or face == Enum.NormalId.Bottom then
		return s.X, s.Z
	elseif face == Enum.NormalId.Left or face == Enum.NormalId.Right then
		return s.Z, s.Y
	end
	return s.X, s.Y
end

local function faceArea(part: BasePart, face: Enum.NormalId): number
	local u, v = faceStudSize(part, face)
	return u * v
end

-- Preference order is used to break area ties between opposite faces (which always
-- have equal area). Front first keeps a cube/box defaulting to its Front face, while
-- a flat plate/quad/prism (broad face on Top) resolves to Top, and a thin wall
-- (broad face on Front/Back) resolves to Front.
local LARGEST_FACE_PREFERENCE: { Enum.NormalId } = {
	Enum.NormalId.Front,
	Enum.NormalId.Top,
	Enum.NormalId.Right,
	Enum.NormalId.Back,
	Enum.NormalId.Bottom,
	Enum.NormalId.Left,
}

-- Returns the face with the greatest surface area (the "broad" face). Ties are broken
-- by LARGEST_FACE_PREFERENCE so the result is deterministic and intuitive.
local function largestFace(part: BasePart): Enum.NormalId
	local best = Enum.NormalId.Front
	local bestArea = -1
	for _, f in LARGEST_FACE_PREFERENCE do
		local a = faceArea(part, f)
		if a > bestArea + 1e-4 then
			bestArea = a
			best = f
		end
	end
	return best
end

-- Outward unit normal of each face in the PART'S LOCAL space (Roblox convention:
-- Front = -Z, Back = +Z, Right = +X, Left = -X, Top = +Y, Bottom = -Y).
local LOCAL_FACE_NORMAL: { [Enum.NormalId]: Vector3 } = {
	[Enum.NormalId.Front] = Vector3.new(0, 0, -1),
	[Enum.NormalId.Back] = Vector3.new(0, 0, 1),
	[Enum.NormalId.Right] = Vector3.new(1, 0, 0),
	[Enum.NormalId.Left] = Vector3.new(-1, 0, 0),
	[Enum.NormalId.Top] = Vector3.new(0, 1, 0),
	[Enum.NormalId.Bottom] = Vector3.new(0, -1, 0),
}

local ALL_FACES: { Enum.NormalId } = {
	Enum.NormalId.Front,
	Enum.NormalId.Back,
	Enum.NormalId.Right,
	Enum.NormalId.Left,
	Enum.NormalId.Top,
	Enum.NormalId.Bottom,
}

-- The LOCAL-space direction that a Texture's "up" (its +V axis) points when Texture.Rotation
-- is 0, per face -- the BLOCK frame. Measured by rendering an arrow marker on each face of an
-- axis-aligned block. The four side faces share +Y; the two horizontal caps point +Z. This
-- frame holds for blocks and ALL CSG PartOperations; native Ball/Cylinder Parts flip the
-- BOTTOM face (handled by faceDecalUp). Used to right an oriented decal without re-baking art.
local LOCAL_FACE_UP: { [Enum.NormalId]: Vector3 } = {
	[Enum.NormalId.Front] = Vector3.new(0, 1, 0),
	[Enum.NormalId.Back] = Vector3.new(0, 1, 0),
	[Enum.NormalId.Right] = Vector3.new(0, 1, 0),
	[Enum.NormalId.Left] = Vector3.new(0, 1, 0),
	[Enum.NormalId.Top] = Vector3.new(0, 0, 1),
	[Enum.NormalId.Bottom] = Vector3.new(0, 0, 1),
}

-- Chooses the face whose OUTWARD WORLD normal points most nearly along worldDir, using
-- the part's actual CFrame. This is the reliable way to texture "the surface facing the
-- camera / a given direction" regardless of how a primitive oriented its local axes
-- (quadFromFourPoints, prisms, wedges, rotated parts, CSG results, etc.).
--
-- World convention used across PrimitiveGen: the model's front faces the camera at -Z,
-- the viewer's left is +X, and up is +Y. So e.g. worldDir = Vector3.new(0,0,-1) selects
-- the front-facing surface; Vector3.new(0,1,0) selects the upward surface.
--
-- When two faces point nearly the same way (within DIR_TIE), the larger-area face wins,
-- which prevents picking a thin sliver edge that happens to share the direction.
local function faceForWorldDirection(part: BasePart, worldDir: Vector3): Enum.NormalId
	local mag = worldDir.Magnitude
	if mag < 1e-6 then
		return largestFace(part)
	end
	local dir = worldDir / mag
	local cf = part.CFrame
	local DIR_TIE = 0.02
	local best = Enum.NormalId.Front
	local bestDot = -math.huge
	local bestArea = -1
	for _, f in ALL_FACES do
		local worldNormal = cf:VectorToWorldSpace(LOCAL_FACE_NORMAL[f])
		local dot = worldNormal:Dot(dir)
		local area = faceArea(part, f)
		if dot > bestDot + DIR_TIE or (dot > bestDot - DIR_TIE and area > bestArea + 1e-4) then
			bestDot = math.max(dot, bestDot)
			bestArea = area
			best = f
		end
	end
	return best
end

-- ===========================================================================
-- Shape-driven texture orientation
-- ---------------------------------------------------------------------------
-- Which faces are flat vs curved, which way a decal's "up" points, and which axis
-- a pattern wraps around are all fixed properties of the part's SHAPE. Native Parts
-- expose it as part.Shape; our CSG builders record it in a "Shape" attribute (e.g.
-- "Capsule"). shapeOf() unifies the two, and the tables below are the single source
-- of truth -- no per-part world-space curve vectors are stored or trig-derived.
-- ===========================================================================

-- Plain shape name: a native Part's PartType (Block/Ball/Cylinder/Wedge/...), or the
-- "Shape" attribute set by the GP CSG constructors, or nil for an untagged/generic
-- solid (e.g. a user-made union of several parts).
local function shapeOf(part: BasePart): string?
	if part:IsA("Part") then
		return (part :: Part).Shape.Name
	end
	local attr = part:GetAttribute("Shape")
	if type(attr) == "string" then
		return attr
	end
	return nil
end

-- How a shape's faces curve, for applyDecalOnFace's flat-vs-curved decision:
--   "all"      every face curved (sphere, capsule, dome shell)
--   "axial"    flat only on the end caps (local normal parallel to the long axis)
--   "hemiflat" flat only on the single flat face (local normal = -long axis)
--   (absent)   flat-faced: block, prism, wedge, rounded box, pyramid, tube, generic CSG
local SHAPE_CURVATURE: { [string]: string } = {
	Ball = "all",
	Cylinder = "axial",
	Capsule = "all",
	Cone = "axial",
	TaperedCylinder = "axial",
	HollowCylinder = "axial",
	HollowTaperedCylinder = "axial",
	Hemisphere = "hemiflat",
	HollowHemisphere = "all",
}

-- The shape's long axis in its OWN LOCAL frame. Every GP round/axial shape is built with
-- its length along local +X (cylinder, cone, tapered/hollow cylinder, capsule, hemisphere
-- pole); regularPrism runs along local +Y. Used both to find the end caps (above) and as the
-- default axis for DP.wrapDecalAround. A multi-segment tube's union frame is NOT
-- length-aligned, so it is intentionally omitted -- the wrap estimates its axis from the bounding
-- box or takes an explicit wrapAxis.
local SHAPE_LOCAL_AXIS: { [string]: Vector3 } = {
	Cylinder = Vector3.new(1, 0, 0),
	Cone = Vector3.new(1, 0, 0),
	TaperedCylinder = Vector3.new(1, 0, 0),
	HollowCylinder = Vector3.new(1, 0, 0),
	HollowTaperedCylinder = Vector3.new(1, 0, 0),
	Capsule = Vector3.new(1, 0, 0),
	Hemisphere = Vector3.new(1, 0, 0),
	HollowHemisphere = Vector3.new(1, 0, 0),
	RegularPrism = Vector3.new(0, 1, 0),
}

-- LOCAL-space direction the Texture's +V ("up") points at Rotation 0, per face. The block
-- frame (LOCAL_FACE_UP) holds for blocks and ALL CSG PartOperations; native Ball and Cylinder
-- Parts are the lone exception -- their BOTTOM face is flipped 180 deg (its +V points to the
-- front, -Z, not the back). Measured by rendering arrow markers on every face of every shape.
local function faceDecalUp(part: BasePart, face: Enum.NormalId): Vector3
	if face == Enum.NormalId.Bottom and part:IsA("Part") then
		local shp = (part :: Part).Shape
		if shp == Enum.PartType.Ball or shp == Enum.PartType.Cylinder then
			return Vector3.new(0, 0, -1)
		end
	end
	return LOCAL_FACE_UP[face]
end

-- Determines whether a given face of a part is a CURVED surface (round barrel, sphere,
-- cone slope, dome) as opposed to a genuinely flat face (box face, prism side, cylinder/
-- cone flat cap, hemisphere flat face). A flat Texture cannot follow curvature, so painting
-- a curved face produces stretch/seam/abrupt-edge artifacts; applyDecalOnFace restricts those.
-- Driven entirely by the shape tables above, in the part's local frame.
local FLAT_ALIGN_DOT = 0.95
local function faceIsCurved(part: BasePart, normalId: Enum.NormalId): boolean
	local shape = shapeOf(part)
	local kind = shape and SHAPE_CURVATURE[shape]
	if kind == nil then
		return false
	end
	if kind == "all" then
		return true
	end
	local axis = shape and SHAPE_LOCAL_AXIS[shape]
	if axis == nil then
		return true
	end
	local nLocal = LOCAL_FACE_NORMAL[normalId]
	if kind == "axial" then
		-- end caps (local normal parallel to the long axis) are flat; the barrel is curved
		return math.abs(nLocal:Dot(axis)) < FLAT_ALIGN_DOT
	elseif kind == "hemiflat" then
		-- only the single flat face (local normal = -long axis) is flat
		return nLocal:Dot(-axis) < FLAT_ALIGN_DOT
	end
	return true
end

-- Texture.Rotation (degrees) so a decal's "up" (+V) on the chosen face points along
-- upDirWorld, projected into that face and then SNAPPED to the nearest 90 deg. The snap is
-- deliberate: upDirWorld is treated like a world faceDir, mapped into face space and quantized to
-- the FACE EDGE closest to it, so the image always stays axis-aligned to the face (never a
-- diagonal tilt) and upDirWorld merely picks WHICH of the four edges is "up" -- exactly the way a
-- world faceDir picks one of the six discrete faces. This rights an oriented image (logo, smiley,
-- eyes) on ANY surface: the default upDir of +Y keeps art upright in the world (a smiley reads
-- right-side-up on a cylinder whether it lies along X or stands along Y). On a face nearly
-- perpendicular to upDir (a pole/cap where the projection vanishes) it falls back to the +Z front
-- meridian, then +X, so the angle is always defined. Uses faceDecalUp so native Ball/Cylinder
-- bottom caps are handled. Same signed-angle form as aroundWrapRotation, including the same NEGATE
-- (Roblox winds Texture.Rotation opposite the right-handed angle). For an axis-aligned part the raw
-- angle is already a multiple of 90, so the snap is a no-op; it only matters when the part and/or
-- upDirWorld sit at an odd angle.
local function faceTextureRotation(part: BasePart, normalId: Enum.NormalId, upDirWorld: Vector3): number
	local cf = part.CFrame
	local n = cf:VectorToWorldSpace(LOCAL_FACE_NORMAL[normalId])
	local up0 = cf:VectorToWorldSpace(faceDecalUp(part, normalId))

	local function projectRef(ref: Vector3): Vector3?
		local t = ref - ref:Dot(n) * n
		if t.Magnitude < 1e-3 then
			return nil
		end
		return t.Unit
	end
	local t = projectRef(upDirWorld) or projectRef(Vector3.new(0, 0, 1)) or projectRef(Vector3.new(1, 0, 0))
	if t == nil then
		return 0
	end

	local s = up0:Cross(t):Dot(n)
	local c = up0:Dot(t)
	-- NEGATE: the signed angle above is measured about the outward normal (right-handed), but
	-- Roblox's Texture.Rotation winds the IMAGE the opposite way -- the same correction
	-- aroundWrapRotation applies. It is a no-op on the 0/180 faces (so flat box/panel art is
	-- unaffected) but flips 90 <-> 270, which is exactly the upside-down case on a decal whose
	-- face frame is rolled (e.g. a default-up emblem on a vertically-built cylinder/taperedCylinder).
	local deg = -math.deg(math.atan2(s, c))
	-- Snap to the nearest 90 deg (face edge): quantize the world up into face space.
	deg = math.floor(deg / 90 + 0.5) * 90
	return (deg % 360 + 360) % 360
end

-- Signed angle (degrees) to rotate a Texture on a PERIMETER face of a barrel so its +V axis
-- points AROUND the curve (along the circumferential tangent = axisUnit x outwardNormal). This
-- makes a wrapped pattern flow continuously around the body. The result is SNAPPED to the nearest
-- 90 deg so the wrap always aligns with the face's own up/left/right/down edges (never a diagonal
-- tilt) -- like textureUpDir, the wrapDir is quantized into face space. For a part whose curve axis
-- is one of its local axes (every GP barrel/capsule) the raw angle is already exactly 0 or 180,
-- matching the hand-derived recipe (e.g. a local-X capsule: Front 0, Top 0, Back 180, Bottom 180),
-- so the snap is a no-op there; it only matters when the axis sits at an odd angle to the part.
-- Uses faceDecalUp so a native Ball/Cylinder bottom cap is handled, and the live CFrame so it is
-- correct for ANY world orientation.
local function aroundWrapRotation(part: BasePart, normalId: Enum.NormalId, axisUnit: Vector3): number
	local cf = part.CFrame
	local n = cf:VectorToWorldSpace(LOCAL_FACE_NORMAL[normalId])
	local up0 = cf:VectorToWorldSpace(faceDecalUp(part, normalId))
	local t = axisUnit:Cross(n)
	if t.Magnitude < 1e-4 then
		return 0
	end
	t = t.Unit
	local s = up0:Cross(t):Dot(n)
	local c = up0:Dot(t)
	-- NEGATE: the signed angle above is measured about the outward normal (right-handed), but
	-- Roblox's Texture.Rotation winds the IMAGE the opposite way. This is invisible on the 0/180
	-- faces (negation is a no-op there) but flips 90 <-> 270, which is exactly the case that was
	-- wrong before -- e.g. a cube's Top/Bottom under a perpendicular wrap, where the bands must run
	-- the SAME way around as the un-rotated side faces to stay continuous at the shared edges.
	local deg = -math.deg(math.atan2(s, c))
	-- Snap to the nearest 90 deg (face edge): quantize the wrap direction into face space.
	deg = math.floor(deg / 90 + 0.5) * 90
	return (deg % 360 + 360) % 360
end

-- Resolve the WORLD-space axis to wrap a pattern around, in priority order:
--   1. an explicit wrapAxis (any nonzero world Vector3 the author passes), else
--   2. the shape's known long axis (local, from SHAPE_LOCAL_AXIS) taken to world, else
--   3. a best-effort estimate from the longest local bounding-box dimension, but only when the
--      part is CLEARLY elongated (tube, generic CSG union); ambiguous for near-cubic parts.
-- Returns nil when nothing is meaningful (a box/sphere/near-cube with no shape axis), so the
-- caller can fall back to a single-face decal or the square all-faces wrap.
local function resolveWrapAxisWorld(part: BasePart, wrapAxis: Vector3?): Vector3?
	if typeof(wrapAxis) == "Vector3" and (wrapAxis :: Vector3).Magnitude > 1e-6 then
		return (wrapAxis :: Vector3).Unit
	end
	local shape = shapeOf(part)
	local localAxis = shape and SHAPE_LOCAL_AXIS[shape]
	if localAxis ~= nil then
		return part.CFrame:VectorToWorldSpace(localAxis).Unit
	end
	local sz = part.Size
	local m = math.max(sz.X, sz.Y, sz.Z)
	local others = (sz.X + sz.Y + sz.Z - m) / 2
	if m > others * 1.15 then
		local axisLocal: Vector3
		if m == sz.X then
			axisLocal = Vector3.new(1, 0, 0)
		elseif m == sz.Y then
			axisLocal = Vector3.new(0, 1, 0)
		else
			axisLocal = Vector3.new(0, 0, 1)
		end
		return part.CFrame:VectorToWorldSpace(axisLocal).Unit
	end
	return nil
end

-- Paint a repeating image SEAMLESSLY AROUND THE PERIMETER of an elongated body, treating the four
-- faces around `axis` as one loop. ONE ring pitch is used for the WHOLE part so every face shows the
-- SAME stripe/motif width: it is derived from the length ALONG the wrap axis, snapped to a whole
-- number of repeats over that length, so the rings fit edge-to-edge along the axis (and therefore
-- line up face-to-face). Every face uses that pitch on BOTH axes (square cells, so Roblox's
-- Rotation -- which spins the image but leaves StudsPerTileU/V pinned to the face axes -- never
-- changes the width); perimeter faces are then rotated so the bands run around the axis. When
-- skipCaps is false the caps are tiled at the same pitch (a flat Texture can't make them concentric,
-- but the width matches the body); when true the caps are left bare for separate texturing. This is
-- the engine of DP.wrapDecalAround.
local function applyAroundWrap(part: BasePart, contentId: string, color: Color3?, studsAlong: number?, transparency: number?, axis: Vector3, skipCaps: boolean?)
	-- PartOperation/CSG grids are face-CENTER anchored; base Parts are face-CORNER anchored. See
	-- applyAllOverWrap for the offset reasoning (odd repeat count -> phase by half a tile).
	local centerAnchored = not part:IsA("Part")
	local PERP_DOT = 0.95 -- |faceNormal . axis|: above this the face is an end cap

	-- Single pitch for the whole part: length along the axis, snapped to a whole number of rings.
	local localAxis = part.CFrame:VectorToObjectSpace(axis)
	local sz = part.Size
	local ax, ay, az = math.abs(localAxis.X), math.abs(localAxis.Y), math.abs(localAxis.Z)
	local lengthDim
	if ax >= ay and ax >= az then
		lengthDim = sz.X
	elseif ay >= az then
		lengthDim = sz.Y
	else
		lengthDim = sz.Z
	end
	local pitch
	if studsAlong ~= nil and studsAlong > 0 then
		pitch = lengthDim / math.max(1, math.floor(lengthDim / studsAlong + 0.5))
	else
		pitch = math.max(lengthDim, 0.05) -- no spacing requested: one ring spans the length
	end

	for _, face in ALL_FACES do
		local nWorld = part.CFrame:VectorToWorldSpace(LOCAL_FACE_NORMAL[face])
		local isCap = math.abs(nWorld:Dot(axis)) >= PERP_DOT
		-- skipCaps: caller is handling the end caps with a separate texture, so leave them bare.
		if isCap and skipCaps then
			continue
		end
		local fu, fv = faceStudSize(part, face)

		local texture = Instance.new("Texture")
		texture.Name = part.Name .. "_WrapAround_" .. face.Name
		texture.Face = face
		assignDecalContent(texture, contentId)
		if color ~= nil then
			texture.Color3 = color
		end
		if transparency ~= nil then
			texture.Transparency = math.clamp(transparency, 0, 1)
		end

		texture.StudsPerTileU = pitch
		texture.StudsPerTileV = pitch
		if centerAnchored then
			-- Phase a CSG center-anchored grid by half a tile when a face spans an odd count, so a
			-- band sits centred rather than straddling the center line.
			local nU = math.max(1, math.floor(fu / pitch + 0.5))
			local nV = math.max(1, math.floor(fv / pitch + 0.5))
			texture.OffsetStudsU = (nU % 2 == 1) and (pitch / 2) or 0
			texture.OffsetStudsV = (nV % 2 == 1) and (pitch / 2) or 0
		end

		-- Perimeter faces rotate so the bands run AROUND the axis; caps keep the flat projection.
		if not isCap then
			local rot = aroundWrapRotation(part, face, axis)
			if rot ~= 0 then
				(texture :: any).Rotation = rot
			end
		end

		texture.Parent = part
	end
end

-- Paint a repeating image ALL OVER the part: the SAME tile on all six faces with edge-aligned,
-- near-square tiling, so a curved/boxy body is fully covered (spots, scales, camo, textile). Each
-- face axis snaps the target tile to a whole number of repeats so a tile boundary lands on every
-- edge (no motif sliced at a seam). This is the engine of DP.wrapDecal.
local function applyAllOverWrap(part: BasePart, contentId: string, color: Color3?, studsPerTile: number?, transparency: number?)
	local sz = part.Size
	local minDim = math.min(sz.X, sz.Y, sz.Z)
	local target: number = studsPerTile or 0
	if target <= 0 then
		target = math.max(minDim / 3, 0.05)
	end

	local function fitAxis(L: number): (number, number)
		if L <= 0 then
			return target, 1
		end
		local n = math.max(1, math.floor(L / target + 0.5))
		return L / n, n
	end

	-- base Part grids anchor at the face CORNER (offset 0); PartOperation/CSG grids anchor at the
	-- face CENTER, so an ODD repeat count needs a half-tile phase to land a boundary on each edge.
	local centerAnchored = not part:IsA("Part")

	for _, face in ALL_FACES do
		local fu, fv = faceStudSize(part, face)
		local sptU, nU = fitAxis(fu)
		local sptV, nV = fitAxis(fv)

		local texture = Instance.new("Texture")
		texture.Name = part.Name .. "_AllOver_" .. face.Name
		texture.Face = face
		assignDecalContent(texture, contentId)
		if color ~= nil then
			texture.Color3 = color
		end
		if transparency ~= nil then
			texture.Transparency = math.clamp(transparency, 0, 1)
		end
		texture.StudsPerTileU = sptU
		texture.StudsPerTileV = sptV
		if centerAnchored then
			texture.OffsetStudsU = (nU % 2 == 1) and (sptU / 2) or 0
			texture.OffsetStudsV = (nV % 2 == 1) and (sptV / 2) or 0
		end
		texture.Parent = part
	end
end

-- Apply a single planar decal to one already-resolved face. The engine of DP.applyDecalOnFace.
-- On a FLAT face repeating tiles are seamless, so the requested tile size is honored (default = one
-- tile spanning the face) and the art sits SQUARE (no rotation), keeping ordinary panel/sign art
-- unaffected. On a CURVED face (sphere, round barrel, cone slope, dome) a flat image is planar-
-- projected and cannot wrap, so it is restricted to a SINGLE non-repeating decal (tile clamped to at
-- least the full face span) and AUTO-RIGHTED to world up (+Y) so a logo/face/eyes read upright no
-- matter how the part is turned. Keep curved art centered with transparent margins so it never seams
-- at the silhouette.
local function applyFaceDecal(part: BasePart, normalId: Enum.NormalId, contentId: string, color: Color3?, studsPerTileU: number?, studsPerTileV: number?, transparency: number?): Instance
	local curved = faceIsCurved(part, normalId)

	local texture = Instance.new("Texture")
	texture.Name = part.Name .. "_Texture"
	texture.Face = normalId
	assignDecalContent(texture, contentId)
	if color ~= nil then
		texture.Color3 = color
	end
	if transparency ~= nil then
		texture.Transparency = math.clamp(transparency, 0, 1)
	end

	local defaultU, defaultV = faceStudSize(part, normalId)
	if curved then
		if (studsPerTileU ~= nil and studsPerTileU < defaultU) or (studsPerTileV ~= nil and studsPerTileV < defaultV) then
			warn(string.format(
				"applyDecalOnFace: '%s' (face %s) is a curved surface; repeating tiles would seam where they wrap, "
					.. "so a single non-repeating decal is used. Keep the art centered with transparent margins.",
				part.Name, tostring(normalId)
			))
		end
		texture.StudsPerTileU = math.max(studsPerTileU or defaultU, defaultU)
		texture.StudsPerTileV = math.max(studsPerTileV or defaultV, defaultV)
	else
		texture.StudsPerTileU = math.max(studsPerTileU or defaultU, 0.001)
		texture.StudsPerTileV = math.max(studsPerTileV or defaultV, 0.001)
	end

	-- base Part grids anchor at the face CORNER (offset 0 fills it exactly); PartOperation/CSG grids
	-- anchor at the face CENTER, so phase a face-spanning tile by half a tile to re-center the art.
	local centerAnchored = not part:IsA("Part")
	if centerAnchored then
		texture.OffsetStudsU = texture.StudsPerTileU / 2
		texture.OffsetStudsV = texture.StudsPerTileV / 2
	end

	if curved then
		local rot = faceTextureRotation(part, normalId, Vector3.new(0, 1, 0))
		if rot ~= 0 then
			(texture :: any).Rotation = rot
		end
	end

	texture.Parent = part
	return texture
end

DecalPrimitives.dslModule:addFunction("decal", {
	description = [==[
	Declares a custom image to paint on a surface, specified inline as an SVG
	vector-graphics document, and returns a texture id to pass to DP.applyDecalOnFace /
	DP.wrapDecal / DP.wrapDecalAround.

	Use this whenever a surface needs arbitrary imagery that a solid Color3 +
	Material cannot express: signs, labels, text, faces/eyes, flags, emblems,
	playing-card pips, dartboards, packaging art, decals, repeating patterns, etc.
	You do NOT supply a Roblox asset id — the SVG is rasterized and published to an
	image asset automatically during generation, and this call is replaced with the
	resulting "rbxassetid://..." string.

	Provide a complete, self-contained SVG document inside a Lua long-bracket
	string ([[ ... ]]):

	    local label = DP.decal([[
	        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
	          <rect width="100" height="100" fill="#c0392b"/>
	          <circle cx="50" cy="50" r="34" fill="#ffffff"/>
	        </svg>
	    ]])
	    -- Target the surface by the WORLD direction it faces (front = toward camera, -Z):
	    DP.applyDecalOnFace(part, Vector3.new(0, 0, -1), label)

	Guidelines:
	- Always set a viewBox; match the aspect ratio to the face you are texturing.
	- Use flat shapes, paths, gradients, and <text>; do NOT reference external
	  files or embed raster images.
	- Make the background opaque to cover the whole face, or leave regions
	  transparent to let the part's own Color3 show through.
	- Author artwork in its normal, readable orientation — do NOT pre-mirror or
	  reverse it; the texture is applied as-drawn.
	- For an all-over pattern (spots/stripes/scales) keep the motif centered with a
	  transparent margin (or make a seamless tile) and apply it with DP.wrapDecal (all-over) or
	  DP.wrapDecalAround (rings). For stripes/bands, author vertical bands in a <pattern> that
	  are straight (vertical) at the tile's top/bottom edges so they stay seamless across a round
	  body's projection seams; add only a gentle mid-height bulge for an organic look (see
	  DP.wrapDecalAround for a worked zebra example).
	- Define each distinct image once (reuse the returned value) instead of
	  repeating identical SVG.

	SEAMLESS TILING (wrapU / wrapV): pass wrapU=true and/or wrapV=true to force the
	finished texture to tile perfectly on that axis. The rasterized image is MIRRORED
	across the chosen edge (a reflected copy is appended) so opposite edges become
	pixel-identical and the repeat seam disappears — no matter how the SVG's own edges
	were drawn. Use this as a safety net for stripes/patterns whose top and bottom (or
	left and right) edges may not line up:
	    -- mirror top<->bottom so vertical stripes wrap continuously at the seam:
	    local stripes = DP.decal([[ <svg> ...vertical bands... </svg> ]], false, true)
	    DP.wrapDecalAround(body, stripes, nil, 1.2)
	Note the result becomes mirror-symmetric on the wrapped axis (usually fine for
	stripes/spots/organic patterns); wrap only the axis that needs it (e.g. wrapU for
	vertical bands around a body), and do NOT wrap an axis carrying readable text or a
	directional logo, which would appear reflected.
	]==],
	parameters = {
		{ name = "svg", type = "string", description = "A complete SVG document inside a [[ ]] long string." },
		{ name = "wrapU", type = "boolean", description = "Optional. When true, mirror the image left<->right so its vertical (U) edges tile seamlessly. Default false." },
		{ name = "wrapV", type = "boolean", description = "Optional. When true, mirror the image top<->bottom so its horizontal (V) edges tile seamlessly. Default false." },
	},
	returnType = "string",
})
function DecalPrimitives.decal(svg: string, wrapU: boolean?, wrapV: boolean?): string
	if type(svg) ~= "string" or #svg == 0 then
		error("texture: 'svg' must be a non-empty SVG document string")
	end
	-- At generation time this call is replaced out-of-band with the published
	-- rbxassetid:// of the rasterized SVG. If it survives to runtime (no
	-- substitution happened), return the string unchanged so addTexture degrades
	-- gracefully instead of erroring.
	return svg
end

DecalPrimitives.dslModule:addFunction("applyDecalOnFace", {
	description = [=[
	Put a single image/decal on ONE face of a part (or CSG result) — signs, labels, a face/eyes, an
	emblem, a TV screen, a book cover, a logo. The image is a Roblox asset id (numeric or
	"rbxassetid://..."), usually a DP.decal(...) result.

	Pick the face by the WORLD direction it points (a Vector3): the decal lands on whichever face
	actually faces that way in the finished model, robust to however a primitive/CSG oriented its
	local axes. Convention: model faces the camera at -Z, viewer-left is +X, up is +Y. (An
	Enum.NormalId also works; a thin sliver face auto-redirects to the broad face.)

	    DP.applyDecalOnFace(panel, Vector3.new(0, 0, -1), art)   -- front, camera-facing
	    DP.applyDecalOnFace(tabletop, Vector3.new(0, 1, 0), art) -- top surface

	FLAT faces allow repeating tiles and edge-to-edge art. A CURVED face (sphere, barrel, cone slope,
	dome) is restricted to a SINGLE non-repeating decal and auto-righted to world up — make the SVG a
	centered emblem with TRANSPARENT margins so it never seams at the silhouette. Texture the visible
	outer surface; do NOT decal a part that is recessed behind or hidden by other geometry.

	Apply textures AFTER any CSG operation (CSG consumes its input parts and any textures on them).
	]=],
	parameters = {
		{ name = "part", type = "Instance", description = "The part (BasePart or CSG result) to texture." },
		{ name = "face", type = "Enum.NormalId | Vector3", description = "WORLD-space direction (preferred) or Enum.NormalId of the face to texture. Convention: camera at -Z, viewer-left +X, up +Y." },
		{ name = "textureId", type = "string", description = "Image asset id, e.g. \"rbxassetid://123\" or a numeric id." },
		{ name = "color", type = "Color3", description = "Optional RGB tint multiplied with the image. Default is white (no tint)." },
		{ name = "studsPerTileU", type = "number", description = "Optional horizontal tile size in studs (default = face width). On a curved face it is clamped to a single non-repeating decal." },
		{ name = "studsPerTileV", type = "number", description = "Optional vertical tile size in studs (default = face height). On a curved face it is clamped to a single non-repeating decal." },
		{ name = "transparency", type = "number", description = "Optional texture transparency, 0 (opaque) to 1 (invisible). Default 0." },
	},
	returnType = "Instance",
})

DecalPrimitives.dslModule:addFunction("wrapDecal", {
	description = [=[
	Tile the SAME image ALL OVER a part (every face) so a whole curved or boxy body is covered —
	spots, scales, camo, textile, polka dots, a repeating motif. The image is a Roblox asset id
	(numeric or "rbxassetid://..."), usually a DP.decal(...) result.

	    local spots = DP.decal([[ <svg> ...a dot with a transparent margin... </svg> ]])
	    DP.wrapDecal(body, spots, nil, 0.6)   -- 0.6-stud square tiles on every face

	The image MUST be a genuinely TILEABLE motif whose opposite edges match. Roblox tiles the WHOLE
	SVG CANVAS (viewBox + background <rect>), NOT the inner <pattern>, so the canvas must equal the
	pattern WxH (or an exact integer multiple). Keep a motif fully inside the tile with a transparent
	margin, or use DP.decal(svg, wrapU, wrapV) to force seamless tiling by mirroring an edge.

	For continuous stripes/rings around an elongated body use DP.wrapDecalAround instead.
	Apply textures AFTER any CSG operation.
	]=],
	parameters = {
		{ name = "part", type = "Instance", description = "The part (BasePart or CSG result) to cover." },
		{ name = "textureId", type = "string", description = "Image asset id, e.g. \"rbxassetid://123\" or a numeric id." },
		{ name = "color", type = "Color3", description = "Optional RGB tint multiplied with the image. Default is white (no tint)." },
		{ name = "studsPerTile", type = "number", description = "Optional square tile size in studs used on every face. Default ~1/3 of the smallest dimension; smaller = denser." },
		{ name = "transparency", type = "number", description = "Optional texture transparency, 0 (opaque) to 1 (invisible). Default 0." },
	},
	returnType = "Instance",
})

DecalPrimitives.dslModule:addFunction("wrapDecalAround", {
	description = [=[
	Wrap an image as CONTINUOUS RINGS/BANDS AROUND an elongated body's long axis — tiger/zebra/snake
	stripes, barber poles, barrel hoops. The four faces around the axis are treated as ONE loop (each
	shows one tile across the cross-section, rotated so the bands flow the same way around) and the
	image repeats along the length (spacing = studsAlong). The image is a Roblox asset id, usually a
	DP.decal(...) result.

	    -- continuous stripes around a torso capsule that lies along X:
	    DP.wrapDecalAround(torso, stripes, nil, 1.0)

	The axis defaults to the shape's known long axis; pass `axis` (a world Vector3) for a generic
	union or to override. By default the end caps are tiled too; pass coverCaps=false to leave them
	bare for a separate DP.applyDecalOnFace. For seamless rings the image must be SEAMLESS TOP-TO-
	BOTTOM: vertical bands the full tile height that start and end at the same x with VERTICAL end
	tangents (e.g. "M 25,0 C 25,14 42,26 38,38 S 28,62 32,70 S 25,88 25,100"); avoid big sine waves.

	Apply textures AFTER any CSG operation.
	]=],
	parameters = {
		{ name = "part", type = "Instance", description = "The elongated part (BasePart or CSG result) to wrap." },
		{ name = "textureId", type = "string", description = "Image asset id, e.g. \"rbxassetid://123\" or a numeric id." },
		{ name = "color", type = "Color3", description = "Optional RGB tint multiplied with the image. Default is white (no tint)." },
		{ name = "studsAlong", type = "number", description = "Optional ring/band spacing ALONG THE LENGTH in studs (snapped to a whole number of rings). Default: one ring spans the length." },
		{ name = "transparency", type = "number", description = "Optional texture transparency, 0 (opaque) to 1 (invisible). Default 0." },
		{ name = "axis", type = "Vector3", description = "Optional WORLD direction of the long axis to wrap around. Defaults to the shape's known long axis (or the longest bounding-box dimension for an elongated union)." },
		{ name = "coverCaps", type = "boolean", description = "Optional. When true (default) the end caps are tiled too; pass false to leave the caps bare for a separate face texture." },
	},
	returnType = "Instance",
})
function DecalPrimitives.applyDecalOnFace(part: BasePart, face: Enum.NormalId | Vector3 | nil, textureId: string | number, color: Color3?, studsPerTileU: number?, studsPerTileV: number?, transparency: number?): Instance
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		error("applyDecalOnFace: 'part' must be a BasePart created by a GP/CSG function")
	end
	local contentId = normalizeContentId(textureId)

	-- Resolve which face to paint. 'face' may be:
	--   * a Vector3  -> a WORLD-SPACE direction; we texture the face that actually points that way
	--                   in the finished model (most reliable; immune to how a primitive oriented its
	--                   local axes). e.g. Vector3.new(0,0,-1) = the camera-facing front surface.
	--   * Enum.NormalId / string -> that explicit LOCAL face, except a thin-sliver face (the
	--                   paper-thin edge of a plate/quad/prism) is auto-redirected to the broad face.
	--   * nil -> the broad face (a sensible default, though the prompt always passes a direction).
	local normalId: Enum.NormalId
	if typeof(face) == "Vector3" then
		normalId = faceForWorldDirection(part, face :: Vector3)
	elseif face == nil then
		normalId = largestFace(part)
	else
		normalId = resolveNormalId(face)
		local broad = largestFace(part)
		local broadArea = faceArea(part, broad)
		if broadArea > 0 and faceArea(part, normalId) < 0.5 * broadArea then
			normalId = broad
		end
	end

	return applyFaceDecal(part, normalId, contentId, color, studsPerTileU, studsPerTileV, transparency)
end

function DecalPrimitives.wrapDecal(part: BasePart, textureId: string | number, color: Color3?, studsPerTile: number?, transparency: number?): Instance
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		error("wrapDecal: 'part' must be a BasePart created by a GP/CSG function")
	end
	local contentId = normalizeContentId(textureId)
	applyAllOverWrap(part, contentId, color, studsPerTile, transparency)
	return part
end

function DecalPrimitives.wrapDecalAround(part: BasePart, textureId: string | number, color: Color3?, studsAlong: number?, transparency: number?, axis: Vector3?, coverCaps: boolean?): Instance
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		error("wrapDecalAround: 'part' must be a BasePart created by a GP/CSG function")
	end
	local contentId = normalizeContentId(textureId)
	local resolved = resolveWrapAxisWorld(part, axis)
	if resolved == nil then
		-- No usable long axis (a box/sphere/near-cube with no shape axis and no explicit one):
		-- fall back to all-over tiling so the pattern still appears instead of silently doing nothing.
		warn(string.format(
			"wrapDecalAround: '%s' has no clear long axis; falling back to all-over tiling. "
				.. "Pass an explicit 'axis' if you intended concentric rings.",
			part.Name
		))
		applyAllOverWrap(part, contentId, color, studsAlong, transparency)
		return part
	end
	-- coverCaps defaults to true (caps tiled too); pass false to leave the caps bare so they can be
	-- textured separately with DP.applyDecalOnFace.
	local skipCaps = coverCaps == false
	applyAroundWrap(part, contentId, color, studsAlong, transparency, resolved, skipCaps)
	return part
end
return DecalPrimitives
]===],
	runtime = [=[
-- scene-generation compact geometry runtime. Generated source follows this prelude.
SG = {}

local EPS = 1e-5
local MIN_SIZE = 1e-3
local MAX_WARNINGS = 100
local SIZE_TOLERANCE = 0.05
local INSTALLER_NAME = "SceneGenerationInstaller"
-- Build-time channels live in ServerStorage as non-archivable instances, so a
-- saved place carries none of them. The warnings log is shared by the scene
-- and every Generator's copy of SG. The build marker exists while the scene
-- script runs. A host that reads the per-part markers after the build (the
-- z-fighting audit, glTF export) adds the trace marker to keep them, and the
-- export host adds the capture marker to record mesh placements instead.
local WARNINGS_LOG = "__SGWarnings"
local BUILD_MARKER = "__SGBuild"
local TRACE_MARKER = "__SGTrace"
local CAPTURE_MARKER = "__SGCaptureMeshes"
local MESH_PLACEMENT = "__SGMeshPlacement"
-- Per-part build markers. Each is removed when the scene finishes unless the
-- trace marker is present.
local ZF_SCOPE = "ZFScope"
local ZF_INDEX = "ZFIndex"
local GRADED_ATTRIBUTE = "Graded"
local ROAD_ATTRIBUTE = "Road"
local BUILD_ATTRIBUTES = { ZF_SCOPE, ZF_INDEX, GRADED_ATTRIBUTE, ROAD_ATTRIBUTE }
local S = {
	root = nil, parents = {}, xforms = { CFrame.identity }, palette = {},
	protos = {}, counts = {}, style = { nil, Enum.Material.SmoothPlastic, 0, true },
	lookByKey = {},
	assets = {}, assetTemplates = {}, assetFailures = {}, assetsLocked = false,
	meshPlacementCount = 0,
	warningSet = {}, logged = {},
	generators = {}, elements = {}, generatorsLocked = false,
	looks = nil, ownsLooks = false, generating = nil, intoWarnings = nil,
	provenance = {}, building = false, intoTrace = nil, bound = nil,
	zfBody = nil, zfModels = nil, zfBodyIndex = 0, zfSerial = 0,
	zfIndex = 0, zfScope = nil, zfActive = nil, liftActive = nil,
	lastCenter = nil, lastExtent = nil, sizeAsked = false, fitSize = nil,
	scopes = {}, shared = {}, wrapperNames = {}, protoBoxes = {}, instanceFolder = nil,
	gradeCols = {}, gradeProfiles = {}, gradePass = false, elementSources = {},
}

local function serverStorage()
	local ok, service = pcall(function() return game:GetService("ServerStorage") end)
	return ok and service or nil
end

local function marked(name)
	local storage = serverStorage()
	return storage ~= nil and storage:FindFirstChild(name) ~= nil
end

local function setMarker(name, present)
	local storage = serverStorage()
	if not storage then return end
	local found = storage:FindFirstChild(name)
	if present and not found then
		pcall(function()
			local marker = Instance.new("Folder")
			marker.Name = name
			marker.Archivable = false
			marker.Parent = storage
		end)
	elseif not present and found then
		found:Destroy()
	end
end

-- Whether parts carry their build markers. A generation decides once, in SG.into.
local function tracing()
	if S.generating and S.intoTrace ~= nil then return S.intoTrace end
	return S.building or marked(BUILD_MARKER) or marked(TRACE_MARKER)
end

local function warningLog(create)
	local storage = serverStorage()
	if not storage then return nil end
	local found = storage:FindFirstChild(WARNINGS_LOG)
	if found and found:IsA("StringValue") then return found end
	if not create then return nil end
	local made
	pcall(function()
		made = Instance.new("StringValue")
		made.Name = WARNINGS_LOG
		made.Archivable = false
		made.Parent = storage
	end)
	return made
end

local function logWarning(text)
	local log = warningLog(true)
	if not log then return end
	local value = log.Value
	if value == "" then
		log.Value = text
		return
	end
	if string.find("\n" .. value .. "\n", "\n" .. text .. "\n", 1, true) then return end
	local _, lines = string.gsub(value, "\n", "")
	if lines + 1 < MAX_WARNINGS then
		log.Value = value .. "\n" .. text
	elseif lines + 1 == MAX_WARNINGS then
		log.Value = value .. "\nSG: further warnings suppressed"
	end
end

-- A generation's warnings are logged together when it ends, so the same
-- warning from another generation of the same object is still recorded.
local function issue(api, message)
	local cleaned = (tostring(message):gsub("[\r\n]+", " "))
	local text = ("SG.%s: %s"):format(api, cleaned)
	if #text > 500 then text = text:sub(1, 497) .. "..." end
	if S.intoWarnings then table.insert(S.intoWarnings, text) end
	if S.warningSet[text] then return end
	S.warningSet[text] = true
	warn(text)
	if not S.intoWarnings then
		if #S.logged <= MAX_WARNINGS then table.insert(S.logged, text) end
		logWarning(text)
	end
end

local function num(api, value, label, fallback)
	local converted = type(value) == "number" and value or tonumber(value)
	if converted == nil or converted ~= converted or math.abs(converted) == math.huge then
		issue(api, ("%s must be a finite number; using %s"):format(label, fallback or 0))
		return fallback or 0
	end
	if converted ~= value then
		issue(api, ("%s converted to number %s"):format(label, converted))
	end
	return converted
end

local function pos(api, value, label)
	value = num(api, value, label)
	if value <= 0 then
		local corrected = math.max(math.abs(value), MIN_SIZE)
		issue(api, ("%s must be positive; using %s"):format(label, tostring(corrected)))
		value = corrected
	end
	return value
end

local function whole(api, value, label, zero)
	value = num(api, value, label)
	local minimum = zero and 0 or 1
	local rounded = math.max(minimum, math.floor(value + 0.5))
	if rounded ~= value then
		issue(api, ("%s must be an integer in range; using %d"):format(label, rounded))
	end
	return rounded
end

local function arr(api, value, stride)
	if type(value) ~= "table" then
		issue(api, "data must be a table; skipping call")
		return {}
	end
	local usable = #value - (#value % stride)
	if usable ~= #value then
		issue(api, ("data must be an array divisible by %d; ignoring %d trailing value(s)")
			:format(stride, #value - usable))
		local trimmed = {}
		for i = 1, usable do trimmed[i] = value[i] end
		return trimmed
	end
	return value
end

local function parent(api)
	local p = S.parents[#S.parents] or S.root
	if not p then
		issue(api, "call SG.scene first; creating an implicit Scene")
		p = SG.scene("Scene")
	end
	return p
end

-- Scenes with ProceduralModels keep their palette and keyed looks on
-- ReplicatedStorage.SceneGeneration.Looks, so a generator that regenerates
-- later in Studio, in a fresh copy of SG, still finds the scene's colours.
local LOOK_KEY = "^[%w_]+$"

local function lookStore()
	if S.looks and S.looks.Parent then return S.looks end
	local ok, found = pcall(function()
		local shared = game:GetService("ReplicatedStorage"):FindFirstChild("SceneGeneration")
		return shared and shared:FindFirstChild("Looks")
	end)
	S.looks = ok and found or nil
	return S.looks
end

local function persistLook(key)
	if not S.ownsLooks or S.generating or type(key) ~= "string"
		or not key:match(LOOK_KEY) or #key > 90 then
		return
	end
	local store = lookStore()
	if not store then return end
	if S.palette[key] then store:SetAttribute(key, S.palette[key]) end
	local rec = S.lookByKey[key]
	if rec then
		store:SetAttribute(key .. "__look", ("%s,%s,%s"):format(
			rec.material and rec.material.Name or "",
			rec.transparency == nil and "" or tostring(rec.transparency),
			rec.collision == nil and "" or tostring(rec.collision)))
	end
end

local function loadLook(key)
	if type(key) ~= "string" or S.palette[key] or not key:match(LOOK_KEY) then return end
	local store = lookStore()
	if not store then return end
	local stored = store:GetAttribute(key)
	if typeof(stored) ~= "Color3" then return end
	S.palette[key] = stored
	local look = store:GetAttribute(key .. "__look")
	if type(look) == "string" and not S.lookByKey[key] then
		local material, transparency, collision = look:match("^([^,]*),([^,]*),([^,]*)$")
		local rec = {}
		if material and material ~= "" then
			local ok, item = pcall(function() return Enum.Material[material] end)
			if ok then rec.material = item end
		end
		rec.transparency = tonumber(transparency)
		if collision == "true" then rec.collision = true elseif collision == "false" then rec.collision = false end
		S.lookByKey[key] = rec
	end
end

local function color(api, key)
	key = key == nil and S.style[1] or key
	if key == nil then return Color3.fromRGB(163, 162, 165) end
	if typeof(key) == "Color3" then return key end
	loadLook(key)
	if type(key) ~= "string" or not S.palette[key] then
		issue(api, ("unknown palette key %q; using grey"):format(tostring(key)))
		return Color3.fromRGB(163, 162, 165)
	end
	return S.palette[key]
end

local function localCF(api, value)
	if value == nil then return CFrame.identity end
	if typeof(value) == "Vector3" then return CFrame.new(value) end
	if typeof(value) ~= "CFrame" then
		issue(api, "transform must be CFrame or Vector3; using identity")
		return CFrame.identity
	end
	return value
end

local function nextName(holder, kind)
	local counts = S.counts[holder]
	if not counts then
		counts = {}
		S.counts[holder] = counts
	end
	counts[kind] = (counts[kind] or 0) + 1
	return ("%s_%03d"):format(kind, counts[kind])
end

local function zfNumbers(row, key)
	local value = type(row) == "table" and row[key] or nil
	if type(value) ~= "table" then return nil end
	return tonumber(value[1]) or 0, tonumber(value[2]) or 0, tonumber(value[3]) or 0
end

-- Repairs for the generation in progress come from its wrapper Generator (see
-- SG.bind). Body repairs live on this script. Either way the part grows along
-- its own axes.
local function zfAdjust(size, cf, index)
	local bucket = S.generating and S.zfActive or S.zfBody
	local row = type(bucket) == "table" and (bucket[tostring(index)] or bucket[index]) or nil
	local sx, sy, sz = zfNumbers(row, "size")
	local ox, oy, oz = zfNumbers(row, "offset")
	if sx then
		size = Vector3.new(
			math.max(math.abs(size.X + sx), MIN_SIZE),
			math.max(math.abs(size.Y + sy), MIN_SIZE),
			math.max(math.abs(size.Z + sz), MIN_SIZE))
	end
	if ox then cf = cf * CFrame.new(ox, oy, oz) end
	return size, cf
end

-- Remember which generated model this is, and return the repairs its parts
-- apply when it generates. The serial follows creation order, so the same
-- scene source addresses the same model on every run.
local function bindZFight(instance)
	S.zfSerial += 1
	local scope = "m" .. tostring(S.zfSerial)
	S.scopes[instance] = scope
	local repairs = S.zfModels and S.zfModels[scope]
	return scope, type(repairs) == "table" and repairs or nil
end

-- A generation's parts know their creation index but not which model they
-- belong to, so the scene labels them once the model has generated.
local function labelScope(model)
	local scope = S.scopes[model]
	if not scope or not tracing() then return end
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("BasePart") and item:GetAttribute(ZF_INDEX) ~= nil then
			item:SetAttribute(ZF_SCOPE, scope)
		end
	end
end

local function make(api, kind, className, size, cf, key)
	if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
		issue(api, "size must be positive; clamping invalid axes")
		size = Vector3.new(
			math.max(math.abs(size.X), MIN_SIZE),
			math.max(math.abs(size.Y), MIN_SIZE),
			math.max(math.abs(size.Z), MIN_SIZE))
	end
	local holder = parent(api)
	local p = Instance.new(className)
	local material, transparency, collision = S.style[2], S.style[3], S.style[4]
	-- A palette key on a primitive uses that key's remembered look when one
	-- was set with SG.style. Colour always comes from the key; material,
	-- transparency, and collision stay on the current defaults only if the
	-- key was never styled.
	if type(key) == "string" then
		loadLook(key)
		local rec = S.lookByKey[key]
		if rec then
			if rec.material then material = rec.material end
			transparency = rec.transparency or 0
			collision = rec.collision == nil and true or rec.collision
		end
	end
	p.Name, p.Anchored, p.CanCollide, p.CastShadow = nextName(holder, kind), true, collision, true
	p.Material, p.Transparency, p.Color = material, transparency, color(api, key)
	local index, scope
	if S.generating then
		S.zfIndex += 1
		index, scope = S.zfIndex, S.zfScope
	else
		S.zfBodyIndex += 1
		index, scope = S.zfBodyIndex, "body"
	end
	local world = S.xforms[#S.xforms] * localCF(api, cf)
	size, world = zfAdjust(size, world, index)
	if S.generating and type(S.liftActive) == "table" then
		local delta = S.liftActive[tostring(index)]
		if type(delta) ~= "number" then delta = tonumber(delta) end
		if type(delta) == "number" and delta ~= 0 then
			world = world + Vector3.new(0, delta, 0)
		end
	end
	p.Size, p.CFrame, p.Parent = size, world, holder
	if tracing() then
		pcall(p.SetAttribute, p, ZF_INDEX, index)
		-- A generated part with no scope shares no repair slot. Stamping the
		-- fallback name "model" on every generator collapsed their indices together.
		if type(scope) == "string" and scope ~= "" then pcall(p.SetAttribute, p, ZF_SCOPE, scope) end
	end
	return p
end

-- Baked coplanar-face shifts. `payload` is JSON: body parts keyed by creation
-- index, and one table per generated model keyed by the serial bindZFight assigns.
function SG.zFight(payload)
	if type(payload) ~= "string" then
		issue("zFight", "repairs must be a JSON string; ignoring them")
		return nil
	end
	local ok, data = pcall(function()
		return game:GetService("HttpService"):JSONDecode(payload)
	end)
	if not ok or type(data) ~= "table" then
		issue("zFight", "repairs are not valid JSON; ignoring them")
		return nil
	end
	S.zfBody = type(data.body) == "table" and data.body or nil
	S.zfModels = type(data.models) == "table" and data.models or nil
	return nil
end

local function scoped(api, name, cf, build)
	if type(name) ~= "string" or name == "" then
		issue(api, "name must be a non-empty string; using Object")
		name = "Object"
	end
	if type(cf) == "function" and build == nil then build, cf = cf, nil end
	if type(build) ~= "function" then
		issue(api, "build must be a function; skipping group")
		return nil
	end
	local model = Instance.new("Model")
	model.Name, model.Parent = name, parent(api)
	local saved = { S.style[1], S.style[2], S.style[3], S.style[4] }
	-- put starts opaque and collidable; g/o keep the caller's style.
	-- All three restore style when the callback returns.
	if api == "put" then
		S.style[3], S.style[4] = 0, true
	end
	table.insert(S.parents, model)
	table.insert(S.xforms, S.xforms[#S.xforms] * localCF(api, cf))
	local ok, result = pcall(build, model)
	table.remove(S.xforms)
	table.remove(S.parents)
	S.style[1], S.style[2], S.style[3], S.style[4] = saved[1], saved[2], saved[3], saved[4]
	if not ok then issue(api, "build stopped early: " .. tostring(result)) end
	return model
end

function SG.scene(name, into)
	name, into = name or "Scene", into or workspace
	if type(name) ~= "string" or name == "" then
		issue("scene", "invalid name; using Scene")
		name = "Scene"
	end
	if typeof(into) ~= "Instance" then
		issue("scene", "parent must be an Instance; using workspace")
		into = workspace
	end
	if S.root then S.root:Destroy() end
	local old = into:FindFirstChild(name)
	if old then old:Destroy() end
	S.parents, S.xforms, S.palette, S.protos, S.counts = {}, { CFrame.identity }, {}, {}, {}
	S.lookByKey = {}
	S.meshPlacementCount = 0
	S.zfBodyIndex, S.zfSerial = 0, 0
	S.scopes, S.shared, S.wrapperNames, S.protoBoxes = {}, {}, {}, {}
	S.gradeCols, S.gradeProfiles = {}, {}
	S.style = { nil, Enum.Material.SmoothPlastic, 0, true }
	S.building = true
	setMarker(BUILD_MARKER, true)
	-- The log starts with this scene: the prelude's warnings, then its own.
	local log = warningLog(true)
	if log then log.Value = "" end
	for _, text in ipairs(S.logged) do logWarning(text) end
	local root = Instance.new("Folder")
	root.Name, root.Parent, S.root = name, into, root
	return root
end

-- Reserved for the trusted prelude: how the scene was generated (Quality,
-- Source). The prelude line is the record; revisions read it back from there.
function SG.provenance(data)
	if type(data) ~= "table" then
		issue("provenance", "provenance must be a table")
		return nil
	end
	for field, value in pairs(data) do
		if type(field) == "string" and (type(value) == "string" or type(value) == "number") then
			S.provenance[field] = value
		end
	end
	return nil
end

function SG.palette(data)
	data = arr("palette", data, 4)
	for i = 1, #data, 4 do
		local key = data[i]
		if type(key) ~= "string" or key == "" then
			issue("palette", ("invalid key at entry %d; skipping color"):format((i + 3) / 4))
		else
			local r = math.clamp(math.floor(num("palette", data[i + 1], "r") + 0.5), 0, 255)
			local g = math.clamp(math.floor(num("palette", data[i + 2], "g") + 0.5), 0, 255)
			local b = math.clamp(math.floor(num("palette", data[i + 3], "b") + 0.5), 0, 255)
			S.palette[key] = Color3.fromRGB(r, g, b)
			persistLook(key)
		end
	end
end

-- A material may be given as an Enum.Material or, more compactly, as its name:
-- "Wood" instead of Enum.Material.Wood. The name lookup is case-insensitive and
-- built once from the live enum, so it tracks whatever materials the engine has.
local materialByName
local function resolveMaterial(api, value)
	if typeof(value) == "EnumItem" and value.EnumType == Enum.Material then
		return value
	end
	if type(value) == "string" then
		if not materialByName then
			materialByName = {}
			for _, item in ipairs(Enum.Material:GetEnumItems()) do
				materialByName[item.Name:lower()] = item
			end
		end
		local item = materialByName[value:lower()]
		if item then return item end
		issue(api, ("unknown material %q; keeping current material"):format(value))
		return nil
	end
	issue(api, "material must be an Enum.Material or a material name; keeping current material")
	return nil
end

function SG.style(key, material, transparency, collision)
	if key ~= nil then
		color("style", key)
		S.style[1] = key
	end
	-- A palette key remembers the whole look it was styled with -- material,
	-- transparency, and collision -- so a later bare SG.style(key) or passing
	-- that key on a primitive restores all three. Transparency and collision
	-- are recorded per key, not left on the global style, so setting a
	-- translucent key does not bleed onto the opaque objects styled after it.
	local rec
	if type(key) == "string" then
		rec = S.lookByKey[key]
		if not rec then rec = {}; S.lookByKey[key] = rec end
	end
	if material ~= nil then
		local resolved = resolveMaterial("style", material)
		if resolved then
			S.style[2] = resolved
			if rec then rec.material = resolved end
		end
	elseif rec and rec.material then
		S.style[2] = rec.material
	end
	-- A boolean in the transparency slot is a collision shorthand: it sets
	-- collision and leaves the object opaque.
	if type(transparency) == "boolean" then
		if collision == nil then collision = transparency end
		transparency = 0
	end
	if transparency ~= nil then
		local t = math.clamp(num("style", transparency, "transparency"), 0, 1)
		S.style[3] = t
		if rec then rec.transparency = t end
	elseif rec then
		S.style[3] = rec.transparency or 0
	end
	if collision ~= nil then
		if type(collision) ~= "boolean" then
			issue("style", "collision must be boolean; keeping current collision")
		else
			S.style[4] = collision
			if rec then rec.collision = collision end
		end
	elseif rec then
		S.style[4] = rec.collision == nil and true or rec.collision
	end
	if rec then persistLook(key) end
end

function SG.cframe(x, y, z, rx, ry, rz)
	return CFrame.new(num("cframe", x or 0, "x"), num("cframe", y or 0, "y"), num("cframe", z or 0, "z"))
		* CFrame.Angles(
			math.rad(num("cframe", rx or 0, "rx")),
			math.rad(num("cframe", ry or 0, "ry")),
			math.rad(num("cframe", rz or 0, "rz")))
end

-- A position without rotation, for the common case. Shorter than SG.cframe and
-- says outright that only a location is meant.
function SG.pos(x, y, z)
	return CFrame.new(num("pos", x or 0, "x"), num("pos", y or 0, "y"), num("pos", z or 0, "z"))
end

function SG.group(name, cf, build) return scoped("group", name, cf, build) end

function SG.transform(cf, build)
	if type(build) ~= "function" then
		issue("transform", "build must be a function; skipping transform")
		return nil
	end
	table.insert(S.xforms, S.xforms[#S.xforms] * localCF("transform", cf))
	local ok, result = pcall(build)
	table.remove(S.xforms)
	if not ok then
		issue("transform", "build stopped early: " .. tostring(result))
		return nil
	end
	return result
end

function SG.box(sx, sy, sz, cf, key)
	return make("box", "Box", "Part",
		Vector3.new(pos("box", sx, "sx"), pos("box", sy, "sy"), pos("box", sz, "sz")), cf, key)
end

function SG.sphere(d, cf, key)
	d = pos("sphere", d, "diameter")
	local p = make("sphere", "Sphere", "Part", Vector3.new(d, d, d), cf, key)
	p.Shape = Enum.PartType.Ball
	return p
end

function SG.disc(r, h, cf, key)
	r, h = pos("disc", r, "radius"), pos("disc", h or 0.1, "thickness")
	local p = make("disc", "Disc", "Part", Vector3.new(h, r * 2, r * 2),
		localCF("disc", cf) * CFrame.Angles(0, 0, math.pi / 2), key)
	p.Shape = Enum.PartType.Cylinder
	return p
end

function SG.segment(ax, ay, az, bx, by, bz, width, key, round)
	local a = Vector3.new(num("segment", ax, "ax"), num("segment", ay, "ay"), num("segment", az, "az"))
	local b = Vector3.new(num("segment", bx, "bx"), num("segment", by, "by"), num("segment", bz, "bz"))
	local length, mid = (b - a).Magnitude, (a + b) / 2
	if length <= EPS then
		issue("segment", "endpoints must be distinct; skipping segment")
		return nil
	end
	width = pos("segment", width or 0.2, "width")
	local cf = CFrame.lookAt(mid, b)
	if round then
		local p = make("segment", "Segment", "Part", Vector3.new(length, width, width),
			cf * CFrame.Angles(0, math.pi / 2, 0), key)
		p.Shape = Enum.PartType.Cylinder
		return p
	end
	return make("segment", "Segment", "Part", Vector3.new(width, width, length), cf, key)
end

local function triangle(api, a, b, c, thickness, key)
	local ab, ac, bc = b - a, c - a, c - b
	if ab:Dot(ab) > ac:Dot(ac) and ab:Dot(ab) > bc:Dot(bc) then
		a, b, c = c, a, b
	elseif ac:Dot(ac) > ab:Dot(ab) and ac:Dot(ac) > bc:Dot(bc) then
		a, b, c = b, c, a
	end
	ab, ac, bc = b - a, c - a, c - b
	if bc.Magnitude <= EPS or ac:Cross(ab).Magnitude <= EPS then
		issue(api, "triangle must be non-degenerate; skipping triangle")
		return {}
	end
	local right, back = ac:Cross(ab).Unit, bc.Unit
	local up, height, made = bc:Cross(right).Unit, math.abs(ab:Dot(bc:Cross(right).Unit)), {}
	local function one(mid, xAxis, zAxis, run)
		if run > EPS then
			table.insert(made, make(api, "Triangle", "WedgePart",
				Vector3.new(thickness, height, run), CFrame.fromMatrix(mid, xAxis, up, zAxis), key))
		end
	end
	one((a + b) / 2, right, back, math.abs(ab:Dot(back)))
	one((a + c) / 2, -right, -back, math.abs(ac:Dot(back)))
	return made
end

function SG.triangle(ax, ay, az, bx, by, bz, cx, cy, cz, w, key)
	return triangle("triangle",
		Vector3.new(num("triangle", ax, "ax"), num("triangle", ay, "ay"), num("triangle", az, "az")),
		Vector3.new(num("triangle", bx, "bx"), num("triangle", by, "by"), num("triangle", bz, "bz")),
		Vector3.new(num("triangle", cx, "cx"), num("triangle", cy, "cy"), num("triangle", cz, "cz")),
		pos("triangle", w or 0.05, "thickness"), key)
end

function SG.quad(ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, w, key)
	local a = Vector3.new(num("quad", ax, "ax"), num("quad", ay, "ay"), num("quad", az, "az"))
	local b = Vector3.new(num("quad", bx, "bx"), num("quad", by, "by"), num("quad", bz, "bz"))
	local c = Vector3.new(num("quad", cx, "cx"), num("quad", cy, "cy"), num("quad", cz, "cz"))
	local d = Vector3.new(num("quad", dx, "dx"), num("quad", dy, "dy"), num("quad", dz, "dz"))
	w = pos("quad", w or 0.05, "thickness")
	return { triangle("quad", a, b, c, w, key), triangle("quad", a, c, d, w, key) }
end

function SG.frustum(r1, r2, h, sides, cf, key)
	r1, r2, h = pos("frustum", r1, "bottom radius"), num("frustum", r2, "top radius"), pos("frustum", h, "height")
	if r2 < 0 then
		issue("frustum", "top radius must be non-negative; using 0")
		r2 = 0
	end
	sides = whole("frustum", sides or 8, "sides")
	if sides < 3 then
		issue("frustum", "sides must be at least 3; using 3")
		sides = 3
	end
	local made = {}
	local function face(a, b, c)
		for _, part in ipairs(triangle("frustum", a, b, c, 0.05, key)) do made[#made + 1] = part end
	end
	SG.transform(cf or CFrame.identity, function()
		local lo, hi = {}, {}
		for i = 0, sides - 1 do
			local angle = i * math.pi * 2 / sides
			lo[i + 1] = Vector3.new(math.cos(angle) * r1, -h / 2, math.sin(angle) * r1)
			hi[i + 1] = Vector3.new(math.cos(angle) * r2, h / 2, math.sin(angle) * r2)
		end
		for i = 1, sides do
			local j = i % sides + 1
			if r2 <= EPS then
				face(lo[i], lo[j], Vector3.new(0, h / 2, 0))
			else
				face(lo[i], lo[j], hi[j])
				face(lo[i], hi[j], hi[i])
			end
			face(Vector3.new(0, -h / 2, 0), lo[j], lo[i])
			if r2 > EPS then
				face(Vector3.new(0, h / 2, 0), hi[i], hi[j])
			end
		end
	end)
	return made
end

function SG.roundedSlab(sx, sy, sz, radius, cf, key)
	sx, sy, sz, radius = pos("roundedSlab", sx, "sx"), pos("roundedSlab", sy, "sy"),
		pos("roundedSlab", sz, "sz"), pos("roundedSlab", radius, "radius")
	radius = math.min(radius, math.min(sx, sz) * 0.499)
	local made = {}
	SG.transform(cf or CFrame.identity, function()
		if sz - 2 * radius > EPS then made[#made + 1] = SG.box(sx, sy, sz - 2 * radius, nil, key) end
		if sx - 2 * radius > EPS then made[#made + 1] = SG.box(sx - 2 * radius, sy, sz, nil, key) end
		for _, x in ipairs({ -1, 1 }) do
			for _, z in ipairs({ -1, 1 }) do
				made[#made + 1] = SG.disc(radius, sy, SG.cframe(x * (sx / 2 - radius), 0, z * (sz / 2 - radius)), key)
			end
		end
	end)
	return made
end

-- Block lettering on a 5 x 7 grid, top row first.
local GLYPH_ROWS = {
	A = { " ### ", "#   #", "#   #", "#####", "#   #", "#   #", "#   #" },
	B = { "#### ", "#   #", "#   #", "#### ", "#   #", "#   #", "#### " },
	C = { " ### ", "#   #", "#    ", "#    ", "#    ", "#   #", " ### " },
	D = { "#### ", "#   #", "#   #", "#   #", "#   #", "#   #", "#### " },
	E = { "#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####" },
	F = { "#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#    " },
	G = { " ### ", "#   #", "#    ", "# ###", "#   #", "#   #", " ### " },
	H = { "#   #", "#   #", "#   #", "#####", "#   #", "#   #", "#   #" },
	I = { "#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "#####" },
	J = { "  ###", "   # ", "   # ", "   # ", "   # ", "#  # ", " ##  " },
	K = { "#   #", "#  # ", "# #  ", "##   ", "# #  ", "#  # ", "#   #" },
	L = { "#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####" },
	M = { "#   #", "## ##", "# # #", "# # #", "#   #", "#   #", "#   #" },
	N = { "#   #", "##  #", "# # #", "#  ##", "#   #", "#   #", "#   #" },
	O = { " ### ", "#   #", "#   #", "#   #", "#   #", "#   #", " ### " },
	P = { "#### ", "#   #", "#   #", "#### ", "#    ", "#    ", "#    " },
	Q = { " ### ", "#   #", "#   #", "#   #", "# # #", "#  # ", " ## #" },
	R = { "#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #" },
	S = { " ####", "#    ", "#    ", " ### ", "    #", "    #", "#### " },
	T = { "#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  " },
	U = { "#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### " },
	V = { "#   #", "#   #", "#   #", "#   #", "#   #", " # # ", "  #  " },
	W = { "#   #", "#   #", "#   #", "# # #", "# # #", "## ##", "#   #" },
	X = { "#   #", "#   #", " # # ", "  #  ", " # # ", "#   #", "#   #" },
	Y = { "#   #", "#   #", " # # ", "  #  ", "  #  ", "  #  ", "  #  " },
	Z = { "#####", "    #", "   # ", "  #  ", " #   ", "#    ", "#####" },
	["0"] = { " ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### " },
	["1"] = { "  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### " },
	["2"] = { " ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####" },
	["3"] = { "#### ", "    #", "    #", " ### ", "    #", "    #", "#### " },
	["4"] = { "   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # " },
	["5"] = { "#####", "#    ", "#### ", "    #", "    #", "#   #", " ### " },
	["6"] = { " ### ", "#    ", "#    ", "#### ", "#   #", "#   #", " ### " },
	["7"] = { "#####", "    #", "   # ", "  #  ", "  #  ", "  #  ", "  #  " },
	["8"] = { " ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### " },
	["9"] = { " ### ", "#   #", "#   #", " ####", "    #", "    #", " ### " },
	["-"] = { "     ", "     ", "     ", "#####", "     ", "     ", "     " },
	["+"] = { "     ", "  #  ", "  #  ", "#####", "  #  ", "  #  ", "     " },
	["."] = { "     ", "     ", "     ", "     ", "     ", "     ", "  #  " },
	[","] = { "     ", "     ", "     ", "     ", "     ", "  #  ", " #   " },
	[":"] = { "     ", "  #  ", "     ", "     ", "     ", "  #  ", "     " },
	["!"] = { "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "     ", "  #  " },
	["?"] = { " ### ", "#   #", "    #", "   # ", "  #  ", "     ", "  #  " },
	["'"] = { "  #  ", "  #  ", "     ", "     ", "     ", "     ", "     " },
	["/"] = { "    #", "    #", "   # ", "  #  ", " #   ", "#    ", "#    " },
	["&"] = { " ##  ", "#  # ", "# #  ", " #   ", "# # #", "#  # ", " ## #" },
}
local GLYPH_COLUMNS, GLYPH_LINES, GLYPH_ADVANCE, MAX_TEXT = 5, 7, 6, 40
local glyphRects = {}

-- Cover a glyph's cells with as few rectangles as a greedy scan finds, so a
-- letter costs a handful of parts rather than one per cell.
local function rectsFor(char)
	local cached = glyphRects[char]
	if cached then return cached end
	local rows = GLYPH_ROWS[char]
	if not rows then return nil end
	local filled, used, rects = {}, {}, {}
	for r = 1, GLYPH_LINES do
		filled[r], used[r] = {}, {}
		for c = 1, GLYPH_COLUMNS do filled[r][c] = rows[r]:sub(c, c) == "#" end
	end
	for r = 1, GLYPH_LINES do
		for c = 1, GLYPH_COLUMNS do
			if filled[r][c] and not used[r][c] then
				local w = 1
				while c + w <= GLYPH_COLUMNS and filled[r][c + w] and not used[r][c + w] do w += 1 end
				local h = 1
				while r + h <= GLYPH_LINES do
					local full = true
					for k = c, c + w - 1 do
						if not filled[r + h][k] or used[r + h][k] then full = false; break end
					end
					if not full then break end
					h += 1
				end
				for rr = r, r + h - 1 do
					for k = c, c + w - 1 do used[rr][k] = true end
				end
				rects[#rects + 1] = { c - 1, r - 1, w, h }
			end
		end
	end
	glyphRects[char] = rects
	return rects
end

-- Block letters centred on cf in its local XY plane, `height` studs tall and
-- `depth` thick along Z. They read left to right from cf's -Z side, the side a
-- front faces, so a sign on a -Z front needs no rotation. maxWidth shrinks the
-- letters to fit. Returns the lettering's width in studs.
function SG.text(text, cf, height, key, maxWidth, depth)
	text = tostring(text or ""):upper()
	if #text > MAX_TEXT then
		issue("text", ("text longer than %d characters; truncating"):format(MAX_TEXT))
		text = text:sub(1, MAX_TEXT)
	end
	height = pos("text", height, "height")
	local count = #text
	if count == 0 then return 0 end
	local cells = count * GLYPH_ADVANCE - 1
	local cell = height / GLYPH_LINES
	if maxWidth ~= nil then
		maxWidth = pos("text", maxWidth, "maxWidth")
		cell = math.min(cell, maxWidth / cells)
	end
	depth = depth ~= nil and pos("text", depth, "depth") or cell
	local width, tall = cells * cell, GLYPH_LINES * cell
	local frame = localCF("text", cf)
	for i = 1, count do
		local char = text:sub(i, i)
		local rects = char ~= " " and rectsFor(char)
		if char ~= " " and not rects then
			issue("text", ("no glyph for %q; leaving a gap"):format(char))
		end
		local start = (i - 1) * GLYPH_ADVANCE
		for _, rect in ipairs(rects or {}) do
			local u = start + rect[1] + rect[3] / 2
			local v = rect[2] + rect[4] / 2
			make("text", "Letter", "Part", Vector3.new(rect[3] * cell, rect[4] * cell, depth),
				frame * CFrame.new(width / 2 - u * cell, tall / 2 - v * cell, 0), key)
		end
	end
	return width
end

-- Lights and effects sit on a small invisible holder part at cf, so they work
-- the same in scene code and inside a generator, where regeneration rebuilds
-- them with the rest of the object.
local LIGHT_COLOR = Color3.fromRGB(255, 214, 160)
local LIGHT_CLASSES = { point = "PointLight", spot = "SpotLight", surface = "SurfaceLight" }
local PARTICLE_TEXTURES = {
	sparkle = "rbxasset://textures/particles/sparkles_main.dds",
	smoke = "rbxasset://textures/particles/smoke_main.dds",
	fire = "rbxasset://textures/particles/fire_main.dds",
}
-- texture, colour, size, transparency, lifetime, rate, speed, spread, rise, light emission
local PARTICLE_PRESETS = {
	embers = { "sparkle", Color3.fromRGB(255, 140, 40), 0.25, 0.1, 2.5, 12, 3, 25, 2, 1 },
	steam = { "smoke", Color3.fromRGB(235, 235, 240), 1.5, 0.6, 3, 6, 2, 15, 1.5, 0 },
	mist = { "smoke", Color3.fromRGB(210, 220, 230), 4, 0.8, 6, 3, 0.4, 180, 0, 0 },
	dust = { "sparkle", Color3.fromRGB(230, 215, 180), 0.12, 0.3, 5, 8, 0.3, 180, 0, 0 },
	magic = { "sparkle", Color3.fromRGB(150, 120, 255), 0.4, 0.1, 2, 14, 1.5, 180, 0.5, 1 },
	flame = { "fire", Color3.fromRGB(255, 150, 50), 1.2, 0.2, 0.8, 20, 3, 10, 2, 1 },
}

local function fxColor(api, value, fallback)
	if value == nil then return fallback end
	if type(value) == "table" and #value == 3 then
		return Color3.fromRGB(
			math.clamp(num(api, value[1], "r"), 0, 255),
			math.clamp(num(api, value[2], "g"), 0, 255),
			math.clamp(num(api, value[3], "b"), 0, 255))
	end
	return color(api, value)
end

local function fxHolder(api, kind, cf, size)
	local holder = parent(api)
	local p = Instance.new("Part")
	p.Name, p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery = nextName(holder, kind), true, false, false, false
	p.CastShadow, p.Transparency, p.Size = false, 1, size
	p.CFrame, p.Parent = S.xforms[#S.xforms] * localCF(api, cf), holder
	return p
end

local function optTable(api, opts)
	if opts == nil then return {} end
	if type(opts) ~= "table" then
		issue(api, "options must be a table; ignoring them")
		return {}
	end
	return opts
end

-- A light at cf. kind is "point" (all around), "spot" (a cone along cf's -Z,
-- the way a front faces), or "surface" (a panel facing cf's -Z). Shadows are
-- off unless opts.shadows is true. opts.angle sets the spot or surface spread.
function SG.light(kind, cf, colorKey, range, brightness, opts)
	kind = kind or "point"
	local className = LIGHT_CLASSES[kind]
	if not className then
		issue("light", ("unknown light kind %q; using point"):format(tostring(kind)))
		kind, className = "point", "PointLight"
	end
	opts = optTable("light", opts)
	range = math.clamp(range ~= nil and pos("light", range, "range") or 16, 1, 60)
	brightness = math.clamp(brightness ~= nil and num("light", brightness, "brightness") or 1, 0, 10)
	local holder = fxHolder("light", "Light", cf, Vector3.new(0.2, 0.2, 0.2))
	local light = Instance.new(className)
	light.Color, light.Range, light.Brightness = fxColor("light", colorKey, LIGHT_COLOR), range, brightness
	light.Shadows = opts.shadows == true
	if kind ~= "point" then
		light.Face = Enum.NormalId.Front
		if opts.angle ~= nil then
			light.Angle = math.clamp(num("light", opts.angle, "angle"), 0, 180)
		end
	end
	light.Parent = holder
	return light
end

-- A fire, smoke, sparkle, or particle effect at cf. size is the effect's scale
-- in studs: flame height for fire and smoke, emitter width for particles.
-- Particle kinds: embers, steam, mist, dust, magic, flame. opts: color,
-- secondary (fire), rate (particles), opacity (smoke).
function SG.effect(kind, cf, size, opts)
	opts = optTable("effect", opts)
	local preset = PARTICLE_PRESETS[kind]
	if kind ~= "fire" and kind ~= "smoke" and kind ~= "sparkles" and not preset then
		issue("effect", ("unknown effect kind %q; skipping"):format(tostring(kind)))
		return nil
	end
	size = math.clamp(size ~= nil and pos("effect", size, "size") or 2, 0.2, 30)
	local effect
	if preset then
		local holder = fxHolder("effect", "Effect", cf, Vector3.new(size, 0.2, size))
		effect = Instance.new("ParticleEmitter")
		effect.Texture = PARTICLE_TEXTURES[preset[1]]
		effect.Color = ColorSequence.new(fxColor("effect", opts.color, preset[2]))
		effect.Size = NumberSequence.new(preset[3], preset[3] * 1.5)
		effect.Transparency = NumberSequence.new(preset[4], 1)
		effect.Lifetime = NumberRange.new(preset[5] * 0.7, preset[5])
		effect.Rate = math.max(opts.rate ~= nil and num("effect", opts.rate, "rate") or preset[6], 0)
		effect.Speed = NumberRange.new(preset[7] * 0.5, preset[7])
		effect.SpreadAngle = Vector2.new(preset[8], preset[8])
		effect.Acceleration = Vector3.new(0, preset[9], 0)
		effect.LightEmission = preset[10]
		effect.EmissionDirection = Enum.NormalId.Top
		effect.Shape = Enum.ParticleEmitterShape.Box
		effect.Parent = holder
		return effect
	end
	local holder = fxHolder("effect", "Effect", cf, Vector3.new(0.2, 0.2, 0.2))
	if kind == "fire" then
		effect = Instance.new("Fire")
		effect.Size, effect.Heat = size, math.clamp(size * 2, 1, 25)
		effect.Color = fxColor("effect", opts.color, Color3.fromRGB(236, 139, 70))
		effect.SecondaryColor = fxColor("effect", opts.secondary, Color3.fromRGB(139, 80, 55))
	elseif kind == "smoke" then
		effect = Instance.new("Smoke")
		effect.Size, effect.RiseVelocity = size, math.clamp(size, 1, 10)
		effect.Opacity = math.clamp(opts.opacity ~= nil and num("effect", opts.opacity, "opacity") or 0.25, 0, 1)
		effect.Color = fxColor("effect", opts.color, Color3.fromRGB(120, 120, 120))
	else
		effect = Instance.new("Sparkles")
		effect.SparkleColor = fxColor("effect", opts.color, Color3.fromRGB(255, 240, 180))
	end
	effect.Parent = holder
	return effect
end

local function lightingColor(value)
	if value == nil then return nil end
	return fxColor("lighting", value, nil)
end

local FOG_DENSITY = 0.6
local FOG_DARK = 0.12
local FOG_DARK_DENSITY = 0.4

-- The place's time of day and mood. Lighting is global to the place, so only
-- scene code may call this, not a generator. opts: time (0-24 clock hours),
-- brightness, ambient, outdoor (outdoor ambient), exposure, fog (0-1, where 1
-- is thick fog that still shows the near scene), fogColor, haze (0-10).
function SG.lighting(opts)
	if S.generating then
		issue("lighting", "lighting is global to the place; call it from scene code, not a generator")
		return
	end
	opts = optTable("lighting", opts)
	local ok, Lighting = pcall(game.GetService, game, "Lighting")
	if not ok then
		issue("lighting", "Lighting is not available; skipping")
		return
	end
	if opts.time ~= nil then Lighting.ClockTime = num("lighting", opts.time, "time") % 24 end
	if opts.brightness ~= nil then
		Lighting.Brightness = math.clamp(num("lighting", opts.brightness, "brightness"), 0, 10)
	end
	if opts.exposure ~= nil then
		Lighting.ExposureCompensation = math.clamp(num("lighting", opts.exposure, "exposure"), -3, 3)
	end
	Lighting.Ambient = lightingColor(opts.ambient) or Lighting.Ambient
	Lighting.OutdoorAmbient = lightingColor(opts.outdoor) or Lighting.OutdoorAmbient
	if opts.fog ~= nil or opts.fogColor ~= nil or opts.haze ~= nil then
		local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
		if not atmosphere then
			atmosphere = Instance.new("Atmosphere")
			atmosphere.Name = "SceneGenerationAtmosphere"
			atmosphere.Parent = Lighting
		end
		if opts.haze ~= nil then atmosphere.Haze = math.clamp(num("lighting", opts.haze, "haze"), 0, 10) end
		atmosphere.Color = lightingColor(opts.fogColor) or atmosphere.Color
		if opts.fog ~= nil then
			-- Atmosphere.Density 1 hides everything past arm's length, so the
			-- authored 0-1 scale tops out at FOG_DENSITY. Dark fog reads as a
			-- blackout well below that, so it is capped lower still.
			local density = math.clamp(num("lighting", opts.fog, "fog"), 0, 1) * FOG_DENSITY
			local c = atmosphere.Color
			if 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B < FOG_DARK and density > FOG_DARK_DENSITY then
				issue("lighting", ("fog %.2f with a near-black fogColor blacks out the scene; using %.2f"):format(
					num("lighting", opts.fog, "fog"), FOG_DARK_DENSITY / FOG_DENSITY))
				density = FOG_DARK_DENSITY
			end
			atmosphere.Density = density
		end
	end
end

local function points(api, data)
	data = arr(api, data, 3)
	if #data < 6 then
		issue(api, "at least two points are required; skipping call")
		return {}
	end
	local result = {}
	for i = 1, #data, 3 do
		result[#result + 1] = Vector3.new(
			num(api, data[i], "x"), num(api, data[i + 1], "y"), num(api, data[i + 2], "z"))
	end
	return result
end

function SG.curve(data, steps, closed)
	local p = points("curve", data)
	if #p < 2 then return {} end
	steps = whole("curve", steps or 6, "steps")
	local out, segments = {}, closed and #p or #p - 1
	local function get(i) return closed and p[(i - 1) % #p + 1] or p[math.clamp(i, 1, #p)] end
	for segment = 1, segments do
		local p0, p1, p2, p3 = get(segment - 1), get(segment), get(segment + 1), get(segment + 2)
		for j = 0, steps - 1 do
			local u, u2, u3 = j / steps, (j / steps) ^ 2, (j / steps) ^ 3
			local v = 0.5 * ((2 * p1) + (-p0 + p2) * u
				+ (2 * p0 - 5 * p1 + 4 * p2 - p3) * u2
				+ (-p0 + 3 * p1 - 3 * p2 + p3) * u3)
			out[#out + 1], out[#out + 2], out[#out + 3] = v.X, v.Y, v.Z
		end
	end
	local last = closed and p[1] or p[#p]
	out[#out + 1], out[#out + 2], out[#out + 3] = last.X, last.Y, last.Z
	return out
end

function SG.path(data, width, key, round, closed)
	local p = points("path", data)
	if #p < 2 then return nil end
	for i = 1, closed and #p or #p - 1 do
		local a, b = p[i], p[i % #p + 1]
		SG.segment(a.X, a.Y, a.Z, b.X, b.Y, b.Z, width, key, round)
	end
	return nil
end

function SG.ribbon(data, width, key, closed)
	local p, left, right = points("ribbon", data), {}, {}
	if #p < 2 then return nil end
	width = pos("ribbon", width, "width")
	for i, point in ipairs(p) do
		local previous = p[i == 1 and (closed and #p or 1) or i - 1]
		local following = p[i == #p and (closed and 1 or #p) or i + 1]
		local tangent = following - previous
		if tangent.Magnitude <= EPS then
			issue("ribbon", "zero tangent; using x axis")
			tangent = Vector3.xAxis
		end
		local side = Vector3.yAxis:Cross(tangent.Unit)
		if side.Magnitude <= EPS then
			issue("ribbon", "vertical tangent; using z axis")
			side = Vector3.zAxis
		end
		side = side.Unit * width / 2
		left[i], right[i] = point - side, point + side
	end
	for i = 1, closed and #p or #p - 1 do
		local j = i % #p + 1
		triangle("ribbon", left[i], right[i], right[j], 0.05, key)
		triangle("ribbon", left[i], right[j], left[j], 0.05, key)
	end
	return nil
end

local function arc(cx, cy, cz, radius, a0, a1, steps)
	cx, cy, cz = num("arc", cx, "cx"), num("arc", cy, "cy"), num("arc", cz, "cz")
	a0, a1 = num("arc", a0, "a0"), num("arc", a1, "a1")
	local p = {}
	for i = 0, steps do
		local angle = a0 + (a1 - a0) * i / steps
		p[i + 1] = Vector3.new(cx + math.cos(angle) * radius, cy + math.sin(angle) * radius, cz)
	end
	return p
end

function SG.archFill(cx, cy, cz, inner, outer, a0, a1, steps, w, key)
	outer, inner = pos("archFill", outer, "outer radius"), num("archFill", inner or 0, "inner radius")
	if inner < 0 or inner >= outer then
		local corrected = math.clamp(inner, 0, math.max(0, outer - MIN_SIZE))
		issue("archFill", ("invalid inner radius; using %s"):format(corrected))
		inner = corrected
	end
	a0, a1, steps, w = num("archFill", a0 or 0, "a0"), num("archFill", a1 or math.pi, "a1"),
		whole("archFill", steps or 12, "steps"),
		pos("archFill", w or 0.05, "thickness")
	local outside, inside = arc(cx, cy, cz, outer, a0, a1, steps),
		arc(cx, cy, cz, math.max(inner, EPS), a0, a1, steps)
	for i = 1, steps do
		if inner == 0 then
			triangle("archFill", Vector3.new(cx, cy, cz), outside[i], outside[i + 1], w, key)
		else
			triangle("archFill", inside[i], outside[i], outside[i + 1], w, key)
			triangle("archFill", inside[i], outside[i + 1], inside[i + 1], w, key)
		end
	end
end

function SG.archTrim(cx, cy, cz, radius, a0, a1, steps, width, key, round)
	steps = whole("archTrim", steps or 12, "steps")
	local p = arc(cx, cy, cz, pos("archTrim", radius, "radius"),
		num("archTrim", a0 or 0, "a0"), num("archTrim", a1 or math.pi, "a1"), steps)
	for i = 1, steps do
		local a, b = p[i], p[i + 1]
		SG.segment(a.X, a.Y, a.Z, b.X, b.Y, b.Z, width, key, round)
	end
end

function SG.boxes(data)
	data = arr("boxes", data, 7)
	for i = 1, #data, 7 do
		SG.box(data[i], data[i + 1], data[i + 2],
			SG.cframe(data[i + 3], data[i + 4], data[i + 5]), data[i + 6])
	end
end

function SG.spheres(data)
	data = arr("spheres", data, 5)
	for i = 1, #data, 5 do
		SG.sphere(data[i], SG.cframe(data[i + 1], data[i + 2], data[i + 3]), data[i + 4])
	end
	return nil
end

function SG.discs(data)
	data = arr("discs", data, 6)
	for i = 1, #data, 6 do
		SG.disc(data[i], data[i + 1],
			SG.cframe(data[i + 2], data[i + 3], data[i + 4]), data[i + 5])
	end
	return nil
end

function SG.define(key, build)
	if type(key) ~= "string" or key == "" or type(build) ~= "function" then
		issue("define", "expected non-empty key and build function; skipping definition")
		return nil
	end
	if S.protos[key] then
		issue("define", ("prototype %q already exists; replacing it"):format(key))
	end
	S.protos[key] = build
	return nil
end

-- Set once the ProceduralModel helpers below exist. Returns the placed
-- ProceduralModel, or nil when key has no prototype Generator.
local prototypeModel
-- Also set below. Binds each lifted ProceduralModel to its lift and removes
-- the build markers.
local finishScene

-- A box size from a Vector3 or {width, height, depth}, or nil when absent.
local function boxSize(api, value)
	if value == nil then return nil end
	if typeof(value) == "Vector3" then value = { value.X, value.Y, value.Z } end
	local w, h, d = type(value) == "table" and tonumber(value[1]), type(value) == "table" and tonumber(value[2]),
		type(value) == "table" and tonumber(value[3])
	if not (w and h and d and w > EPS and h > EPS and d > EPS) then
		issue(api, "size must be {width, height, depth} with positive numbers; ignoring it")
		return nil
	end
	return Vector3.new(w, h, d)
end
-- Set with the Terrain grading below. Levels the ground under a seated object.
local padUnder

-- A copy built as plain parts, when the prototype has no Generator or its
-- ProceduralModel failed. SG.attributes still reads the copy's attributes, so
-- the plain copy is the same object a generated one would have been, and
-- SG.size returns size when one was asked for.
local function plainCopy(api, name, cf, build, attributes, size)
	local saved, savedSize = S.plainAttributes, S.plainSize
	S.plainAttributes = type(attributes) == "table" and attributes or nil
	S.plainSize = size
	local model = scoped(api, name, cf, build)
	S.plainAttributes, S.plainSize = saved, savedSize
	if model and type(attributes) == "table" then
		for attribute, value in pairs(attributes) do
			pcall(model.SetAttribute, model, tostring(attribute), value)
		end
	end
	return model
end

-- attributes optionally sets the prototype's SG.attributes on every copy.
function SG.place(key, base, data, attributes)
	local build = S.protos[key]
	if not build then
		issue("place", ("prototype %q is not defined; skipping placements"):format(tostring(key)))
		return nil
	end
	data = arr("place", data, 6)
	if type(base) ~= "string" or base == "" then
		issue("place", "invalid base name; using prototype key")
		base = tostring(key)
	end
	for i = 1, #data, 6 do
		local n = (i + 5) / 6
		local name = ("%s_%03d"):format(base, n)
		local cf = SG.cframe(data[i], data[i + 1], data[i + 2], data[i + 3], data[i + 4], data[i + 5])
		if not prototypeModel("place", key, name, cf, attributes) then
			plainCopy("place", name, cf, build, attributes)
		end
	end
	return nil
end

function SG.assets(data)
	if S.assetsLocked then
		issue("assets", "asset manifest is already registered; ignoring replacement")
		return nil
	end
	if type(data) ~= "table" then
		issue("assets", "asset manifest must be a table")
		return nil
	end
	for _, template in pairs(S.assetTemplates) do
		template:Destroy()
	end
	S.assetTemplates, S.assetFailures = {}, {}
	S.assets = data
	S.assetsLocked = true
	return nil
end

local function assetTemplate(key)
	if S.assetTemplates[key] then return S.assetTemplates[key] end
	if S.assetFailures[key] then return nil end
	local spec = S.assets[key]
	if type(spec) ~= "table" or tonumber(spec.assetId) == nil then
		issue("mesh", ("asset %q is not registered; skipping mesh"):format(tostring(key)))
		S.assetFailures[key] = true
		return nil
	end
	local service = game:GetService("InsertService")
	local ok, loaded = pcall(service.LoadAsset, service, tonumber(spec.assetId))
	if not ok or not loaded then
		issue("mesh", ("could not load asset %s for %s: %s")
			:format(tostring(spec.assetId), tostring(key), tostring(loaded)))
		S.assetFailures[key] = true
		return nil
	end
	loaded.Name = tostring(key) .. "_Template"
	loaded.Parent = nil
	for _, item in ipairs(loaded:GetDescendants()) do
		if item:IsA("LuaSourceContainer") then
			item:Destroy()
		elseif item:IsA("BasePart") then
			item.Anchored = true
		end
	end
	S.assetTemplates[key] = loaded
	return loaded
end

local function recordMeshPlacement(key, base, targetHeight, spec)
	local extent = type(spec) == "table" and spec.extent
	if type(extent) ~= "table"
		or tonumber(extent[1]) == nil
		or tonumber(extent[2]) == nil
		or tonumber(extent[3]) == nil then
		issue("mesh", ("asset %q has no measured extent; skipping export placement")
			:format(tostring(key)))
		return
	end
	local box = type(spec) == "table" and spec.box
	if type(box) ~= "table" or #box ~= 12 then
		issue("mesh", ("asset %q has no measured bounding-box frame; skipping export placement")
			:format(tostring(key)))
		return
	end
	for i = 1, 12 do
		if tonumber(box[i]) == nil then
			issue("mesh", ("asset %q has an invalid bounding-box frame; skipping export placement")
				:format(tostring(key)))
			return
		end
	end
	local record = Instance.new("CFrameValue")
	S.meshPlacementCount += 1
	record.Name = MESH_PLACEMENT
	record.Archivable = false
	record.Value = base
	record:SetAttribute("Key", tostring(key))
	record:SetAttribute("Ordinal", S.meshPlacementCount)
	record:SetAttribute("TargetHeight", targetHeight)
	record:SetAttribute("ExtentX", tonumber(extent[1]))
	record:SetAttribute("ExtentY", tonumber(extent[2]))
	record:SetAttribute("ExtentZ", tonumber(extent[3]))
	record:SetAttribute("BoxCFrame", CFrame.new(table.unpack(box)))
	record.Parent = parent("mesh")
end

-- Published MeshGen assets face +Z, but every SG front faces -Z, so the half
-- turn makes yaw 0 mean the same thing for meshes, prototypes, and generators.
-- The turned frame is also what export records for the composite GLB.
local MESH_FRONT = CFrame.Angles(0, math.pi, 0)

function SG.mesh(key, cf, targetHeight)
	targetHeight = pos("mesh", targetHeight, "targetHeight")
	local base = S.xforms[#S.xforms] * localCF("mesh", cf) * MESH_FRONT
	local spec = S.assets[key]
	if marked(CAPTURE_MARKER) then
		recordMeshPlacement(key, base, targetHeight, spec)
		return nil
	end
	local template = assetTemplate(key)
	if not template then return nil end
	local model
	local ok, err = pcall(function()
		model = template:Clone()
		model.Name = nextName(parent("mesh"), tostring(key))
		model:PivotTo(CFrame.identity)
		local box, extent = model:GetBoundingBox()
		if extent.Y <= EPS then
			error(("asset %q has no measurable height"):format(tostring(key)))
		end
		model:ScaleTo(model:GetScale() * targetHeight / extent.Y)
		model:PivotTo(CFrame.identity)
		local fitted
		box, fitted = model:GetBoundingBox()
		local wantedBox = base * CFrame.new(0, fitted.Y / 2, 0)
		model:PivotTo(wantedBox * box:Inverse())
		model.Parent = parent("mesh")
	end)
	if not ok then
		if model then model:Destroy() end
		issue("mesh", ("asset %q could not be fitted; skipping mesh: %s")
			:format(tostring(key), tostring(err)))
		return nil
	end
	return model
end

function SG.boxRegion(x, y, z, sx, sy, sz)
	x, y, z = num("boxRegion", x, "x"), num("boxRegion", y, "y"), num("boxRegion", z, "z")
	sx, sy, sz = num("boxRegion", sx, "sx"), num("boxRegion", sy, "sy"), num("boxRegion", sz, "sz")
	if sx < 0 or sy < 0 or sz < 0 then
		issue("boxRegion", "region sizes must be non-negative; using absolute values")
		sx, sy, sz = math.abs(sx), math.abs(sy), math.abs(sz)
	end
	if sx + sy + sz <= 0 then
		issue("boxRegion", "invalid region; scatter will be skipped")
		return nil
	end
	return { "b", x, y, z, sx, sy, sz }
end

function SG.discRegion(x, y, z, radius)
	return { "d", num("discRegion", x, "x"), num("discRegion", y, "y"), num("discRegion", z, "z"),
		pos("discRegion", radius, "radius") }
end

function SG.scatter(seed, count, region, build)
	count = whole("scatter", count, "count", true)
	if type(region) ~= "table" or type(build) ~= "function" then
		issue("scatter", "expected region and build function; skipping scatter")
		return nil
	end
	seed = whole("scatter", seed or 0, "seed", true)
	local rng = Random.new(seed)
	for i = 1, count do
		local point
		if region[1] == "b" then
			if #region < 7 then
				issue("scatter", "box region is incomplete; skipping scatter")
				return nil
			end
			local x, y, z = num("scatter", region[2], "region x"),
				num("scatter", region[3], "region y"), num("scatter", region[4], "region z")
			local sx, sy, sz = math.abs(num("scatter", region[5], "region sx")),
				math.abs(num("scatter", region[6], "region sy")),
				math.abs(num("scatter", region[7], "region sz"))
			point = Vector3.new(
				x + rng:NextNumber(-sx / 2, sx / 2),
				y + rng:NextNumber(-sy / 2, sy / 2),
				z + rng:NextNumber(-sz / 2, sz / 2))
		elseif region[1] == "d" then
			if #region < 5 then
				issue("scatter", "disc region is incomplete; skipping scatter")
				return nil
			end
			local x, y, z = num("scatter", region[2], "region x"),
				num("scatter", region[3], "region y"), num("scatter", region[4], "region z")
			local angle = rng:NextNumber(0, math.pi * 2)
			local radius = math.sqrt(rng:NextNumber()) * pos("scatter", region[5], "region radius")
			point = Vector3.new(
				x + math.cos(angle) * radius, y, z + math.sin(angle) * radius)
		else
			issue("scatter", "unknown region; skipping scatter")
			return nil
		end
		local ok, result = pcall(build, point, i, rng)
		if not ok then issue("scatter", ("item %d stopped early: %s"):format(i, tostring(result))) end
	end
	return nil
end

-- Seating on the ground. A raycast straight down finds whatever support the
-- caller named and reports its surface height. The seating wrappers below run
-- this BEFORE entering a build callback, so an object is placed at a height the
-- ground decided, and no ray is ever fired from inside a group (where it would
-- hit the sibling part placed a moment earlier and walk the object into the sky).
-- RCC export replaces Terrain with parts under I2LFakedTerrain, and rewrites
-- Terrain references in the scene's own chunk only. Looking the folder up by
-- name keeps seating correct in a ModuleScript copy of SG as well.
local function terrainSupport()
	return workspace:FindFirstChild("I2LFakedTerrain") or workspace.Terrain
end

local function normalizeSupports(api, supports)
	if supports == nil then return { terrainSupport() } end
	if typeof(supports) == "Instance" then return { supports } end
	if type(supports) ~= "table" then
		issue(api, "supports must be an Instance or a table of Instances; using Terrain")
		return { terrainSupport() }
	end
	local out = {}
	for _, inst in ipairs(supports) do
		if typeof(inst) == "Instance" then
			out[#out + 1] = inst
		else
			issue(api, "each support must be an Instance; ignoring one entry")
		end
	end
	if #out == 0 then
		issue(api, "no valid supports given; using Terrain")
		return { terrainSupport() }
	end
	return out
end

local SKY = 4096

local function includeParams(supports, ignoreWater)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = supports
	params.IgnoreWater = ignoreWater
	return params
end

-- One downward ray against a fixed include-filter. Returns the world Y of the
-- hit, or nil when the column is empty. A ray from the sky stops on the first
-- surface, which inside a cave is the hill over it; `below` starts the ray at
-- that height instead, so it lands on the floor under that point.
local function raycastSupport(x, z, supports, ignoreWater, below)
	local start = below or SKY
	local hit = workspace:Raycast(Vector3.new(x, start, z), Vector3.new(0, -(start + SKY), 0),
		includeParams(supports, ignoreWater))
	return hit and hit.Position.Y or nil
end

-- The underside of whatever is above (x, y, z), up to reach studs, or nil.
local function raycastCeiling(x, y, z, supports, reach)
	local hit = workspace:Raycast(Vector3.new(x, y, z), Vector3.new(0, reach, 0), includeParams(supports, true))
	return hit and hit.Position.Y or nil
end

-- The highest hit across a footprint, so no corner of a wide object sinks. A
-- footprint is a side length or a {width, depth} pair along the object's own
-- axes, so its corners turn with yaw. It is sampled at its centre and four
-- corners; nil footprint samples the centre alone. Returns nil if every sample
-- misses.
local function highestSupport(api, x, z, supports, footprint, ignoreWater, yaw, below)
	local best = raycastSupport(x, z, supports, ignoreWater, below)
	if footprint ~= nil then
		local hw, hd
		if type(footprint) == "table" then
			hw = pos(api, footprint[1], "footprint width") / 2
			hd = pos(api, footprint[2], "footprint depth") / 2
		else
			hw = pos(api, footprint, "footprint") / 2
			hd = hw
		end
		local turn = math.rad(yaw or 0)
		local c, s = math.cos(turn), math.sin(turn)
		for _, o in ipairs({ { -hw, -hd }, { hw, -hd }, { -hw, hd }, { hw, hd } }) do
			-- CFrame.Angles(0, turn, 0) carries a local (x, z) to these world offsets.
			local ox, oz = o[1] * c + o[2] * s, -o[1] * s + o[2] * c
			local y = raycastSupport(x + ox, z + oz, supports, ignoreWater, below)
			if y and (not best or y > best) then best = y end
		end
	end
	return best
end

-- Resolve a seating request to a world CFrame. (x, z) are the caller's footprint
-- centre, taken through the current transform so seating works inside a
-- translated group; yaw is degrees about world Y. When nothing supports the
-- column we warn and fall back to y = 0 rather than dropping the object.
-- The root transform maps world into a scene element's ProceduralModel space,
-- so it is undone before raycasting and reapplied to the seated result.
local function seatWorld(api, label, x, z, yaw, opts)
	opts = type(opts) == "table" and opts or {}
	local root = S.xforms[1]
	local base = root:Inverse() * S.xforms[#S.xforms]
	local below = opts.below ~= nil and num(api, opts.below, "below") or nil
	local column = base * Vector3.new(num(api, x, "x"), below or 0, num(api, z, "z"))
	yaw = num(api, yaw or 0, "yaw")
	local y = opts.y
	if y ~= nil then
		y = num(api, y, "y")
	else
		local supports = normalizeSupports(api, opts.supports)
		local ignoreWater = opts.ignoreWater
		if ignoreWater == nil then ignoreWater = true end
		y = highestSupport(api, column.X, column.Z, supports, opts.footprint, ignoreWater, yaw,
			below and column.Y or nil)
		if y == nil then
			issue(api, ("nothing supports %q; placing it at y = 0"):format(tostring(label)))
			y = 0
		end
	end
	local world = CFrame.new(column.X, y, column.Z) * CFrame.Angles(0, math.rad(yaw), 0)
	return base:Inverse() * world
end

-- The raw support height at a world column, for callers doing their own math.
-- Returns nil when the column is empty; handle that rather than indexing it.
function SG.ground(x, z, supports, ignoreWater)
	x, z = num("ground", x, "x"), num("ground", z, "z")
	supports = normalizeSupports("ground", supports)
	if ignoreWater == nil then ignoreWater = true end
	return raycastSupport(x, z, supports, ignoreWater)
end

-- The first support at or below y in a column: a cave or interior floor rather
-- than the roof above it. nil when nothing is below.
function SG.floor(x, y, z, supports, ignoreWater)
	x, y, z = num("floor", x, "x"), num("floor", y, "y"), num("floor", z, "z")
	supports = normalizeSupports("floor", supports)
	if ignoreWater == nil then ignoreWater = true end
	return raycastSupport(x, z, supports, ignoreWater, y)
end

-- The parts of the scene and the Terrain, for helpers that attach to whatever
-- the scene has already built.
local function sceneSupports()
	local out = { terrainSupport() }
	if S.root then out[2] = S.root end
	return out
end

-- The underside of the first thing above y in a column, up to reach studs
-- (default 64): a cave roof, a beam, or an eave. nil when nothing is above.
function SG.ceiling(x, y, z, supports, reach)
	x, y, z = num("ceiling", x, "x"), num("ceiling", y, "y"), num("ceiling", z, "z")
	supports = supports == nil and sceneSupports() or normalizeSupports("ceiling", supports)
	reach = reach ~= nil and pos("ceiling", reach, "reach") or 64
	return raycastCeiling(x, y, z, supports, reach)
end

-- How far a thin surface may sit under the terrain and still be lifted onto it.
-- Deeper than this is a basement or a span, not the 2-stud voxel bleed.
local SURFACE_BURIAL = 6
local SURFACE_THICKNESS = 2.5
local SURFACE_CLEARANCE = 0.1

local function worldSpan(cf, size, axis)
	local function component(vector)
		if axis == "x" then return math.abs(vector.X) end
		if axis == "z" then return math.abs(vector.Z) end
		return math.abs(vector.Y)
	end
	return component(cf.RightVector) * size.X
		+ component(cf.UpVector) * size.Y
		+ component(cf.LookVector) * size.Z
end

-- Grass blades grow through any part laid over Grass Terrain. A part at least
-- GRASS_COVER studs across whose underside is within GRASS_REACH of the ground
-- covers it, and the Grass under it becomes LeafyGrass, which has no blades.
-- Narrower parts (posts, flowers, trunks) leave the meadow around them alone.
local GRASS_COVER = 2
local GRASS_REACH = 2
local GRASS_VOXEL = 4

local function clearGrassUnder(parts, supports)
	local terrain = workspace.Terrain
	if typeof(terrain) ~= "Instance" then return end
	local columns, order = {}, {}
	for _, part in ipairs(parts) do
		local cf, size, p = part.CFrame, part.Size, part.Position
		local spanX, spanY, spanZ = worldSpan(cf, size, "x"), worldSpan(cf, size, "y"), worldSpan(cf, size, "z")
		-- A slab on a slope is seated or lifted to its highest corner, so the
		-- ground under its centre can sit well below it.
		local low, high = math.huge, -math.huge
		for _, o in ipairs({ { 0, 0 }, { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
			local ground = raycastSupport(p.X + o[1] * spanX / 2, p.Z + o[2] * spanZ / 2, supports, true)
			if ground then low, high = math.min(low, ground), math.max(high, ground) end
		end
		local bottom = p.Y - spanY / 2
		if low < math.huge and bottom <= high + GRASS_REACH and bottom + spanY >= low - 0.5 then
			local lo = math.floor((low - 8) / GRASS_VOXEL)
			local hi = math.ceil((high + 6) / GRASS_VOXEL)
			for ix = math.floor((p.X - spanX / 2) / GRASS_VOXEL), math.ceil((p.X + spanX / 2) / GRASS_VOXEL) - 1 do
				for iz = math.floor((p.Z - spanZ / 2) / GRASS_VOXEL), math.ceil((p.Z + spanZ / 2) / GRASS_VOXEL) - 1 do
					local key = ix .. "," .. iz
					local column = columns[key]
					if column then
						column[3], column[4] = math.min(column[3], lo), math.max(column[4], hi)
					else
						columns[key] = { ix, iz, lo, hi }
						order[#order + 1] = columns[key]
					end
				end
			end
		end
	end
	table.sort(order, function(a, b)
		if a[1] ~= b[1] then return a[1] < b[1] end
		return a[2] < b[2]
	end)
	local i = 1
	while i <= #order do
		local first, last = order[i], order[i]
		while order[i + 1] and order[i + 1][1] == first[1] and order[i + 1][2] == last[2] + 1
			and order[i + 1][3] == first[3] and order[i + 1][4] == first[4] do
			i += 1
			last = order[i]
		end
		local region = Region3.new(
			Vector3.new(first[1], first[3], first[2]) * GRASS_VOXEL,
			Vector3.new(first[1] + 1, first[4], last[2] + 1) * GRASS_VOXEL)
		pcall(terrain.ReplaceMaterial, terrain, region, GRASS_VOXEL, Enum.Material.Grass, Enum.Material.LeafyGrass)
		i += 1
	end
end

-- Roads, decks and treads authored at a fill height end up under the visible
-- surface. Lift each thin horizontal part so its top clears the terrain under
-- it. Water is ignored, so a pier over the sea stays at its drafted height
-- while the same deck rises where it crosses land. A part buried deeper than
-- SURFACE_BURIAL is left where it was.
function SG.liftSurfaces()
	if S.generating then
		issue("liftSurfaces", "call it from scene code, after the scene has built")
		return nil
	end
	for _ = 1, 4 do task.wait() end
	local supports = { terrainSupport() }
	local function buried(x, z, top)
		local ground = raycastSupport(x, z, supports, true)
		if not ground then return nil end
		local depth = ground + SURFACE_CLEARANCE - top
		if depth <= 0 or depth > SURFACE_BURIAL then return nil end
		return depth
	end
	local lifts, covers = {}, {}
	for _, part in ipairs(workspace:GetDescendants()) do
		if part:IsA("BasePart") and not part:IsA("Terrain") then
			local skipped = false
			local current = part.Parent
			while typeof(current) == "Instance" do
				if current.Name == "I2LFakedTerrain" then
					skipped = true
					break
				end
				current = current.Parent
			end
			-- A paved road already sits on Terrain shaped for it.
			local readGraded, graded = pcall(part.GetAttribute, part, GRADED_ATTRIBUTE)
			skipped = skipped or (readGraded and graded == true)
			local cf, size = part.CFrame, part.Size
			local spanY = worldSpan(cf, size, "y")
			local spanX, spanZ = worldSpan(cf, size, "x"), worldSpan(cf, size, "z")
			if not skipped and part.Transparency < 0.95 and math.min(spanX, spanZ) >= GRASS_COVER then
				covers[#covers + 1] = part
			end
			if not skipped and spanY <= SURFACE_THICKNESS and spanY <= spanX and spanY <= spanZ then
				local top = part.Position.Y + spanY / 2
				local hx, hz = spanX / 2, spanZ / 2
				local depth = buried(part.Position.X, part.Position.Z, top)
				for _, corner in ipairs({ { -hx, -hz }, { hx, -hz }, { -hx, hz }, { hx, hz } }) do
					local sample = buried(part.Position.X + corner[1], part.Position.Z + corner[2], top)
					if sample and (not depth or sample > depth) then depth = sample end
				end
				if depth then
					pcall(function()
						part.CFrame = part.CFrame + Vector3.new(0, depth, 0)
					end)
					-- A ProceduralModel rebuilds its parts from the generator, so a
					-- CFrame edit here is gone on the next Size or Attribute change.
					-- The index is the one make() stamps, and generation adds the
					-- same delta back in the model's unscaled space.
					local readIndex, index = pcall(part.GetAttribute, part, ZF_INDEX)
					local host = part.Parent
					while typeof(host) == "Instance" and not host:IsA("ProceduralModel") do
						host = host.Parent
					end
					if readIndex and type(index) == "number" and typeof(host) == "Instance" and host:IsA("ProceduralModel") then
						local bucket = lifts[host]
						if not bucket then
							bucket = {}
							lifts[host] = bucket
						end
						local readScale, scale = pcall(host.GetScale, host)
						if not readScale or type(scale) ~= "number" or scale <= EPS then scale = 1 end
						bucket[tostring(index)] = depth / scale
					end
				end
			end
		end
	end
	clearGrassUnder(covers, supports)
	finishScene(lifts)
	return nil
end

-- An SG.group that seats itself: builds the object in local space around a base
-- at y = 0, then rests it on the ground at (x, z) facing yaw. opts may carry
-- supports (Instance or list; default Terrain), footprint (side or {w, d} for
-- highest-corner sampling), ignoreWater (default true), and y (an explicit
-- height that skips the raycast).
function SG.seat(name, x, z, yaw, build, opts)
	if type(yaw) == "function" and build == nil then
		yaw, build = 0, yaw
	end
	local cf = seatWorld("seat", name, x, z, yaw, opts)
	local model = scoped("seat", name, cf, build)
	if type(opts) == "table" and opts.pad then padUnder("seat", model, cf, opts) end
	return model
end

-- Place a generated mesh resting on the ground at (x, z) facing yaw, scaled to
-- targetHeight studs. The mesh analogue of SG.seat; opts matches SG.seat.
function SG.meshOn(key, x, z, yaw, targetHeight, opts)
	local cf = seatWorld("meshOn", key, x, z, yaw, opts)
	local model = SG.mesh(key, cf, targetHeight)
	if type(opts) == "table" and opts.pad then padUnder("meshOn", model, cf, opts) end
	return model
end

-- How far below the given point a hanging object may find what it hangs from,
-- so a point a little under a beam's underside still finds that beam.
local HANG_SLACK = 1.5

-- Hang a mesh so its top meets what it hangs from. (x, y, z) is a point just
-- under a beam, eave, branch or ceiling, or in front of a wall or cliff with
-- opts.wall. The search starts there and only looks up (or back, for a wall),
-- never from the sky, so it cannot land on a roof or a hilltop over the point.
-- opts: reach (studs to search, default 24), wall (hang against the surface
-- behind the mesh, which faces away from it), supports (default the scene's
-- parts and the Terrain).
function SG.hang(key, x, y, z, yaw, targetHeight, opts)
	local api = "hang"
	opts = type(opts) == "table" and opts or {}
	targetHeight = pos(api, targetHeight, "targetHeight")
	yaw = num(api, yaw or 0, "yaw")
	local reach = opts.reach ~= nil and pos(api, opts.reach, "reach") or 24
	local supports = opts.supports == nil and sceneSupports() or normalizeSupports(api, opts.supports)
	local root = S.xforms[1]
	local base = root:Inverse() * S.xforms[#S.xforms]
	local point = base * Vector3.new(num(api, x, "x"), num(api, y, "y"), num(api, z, "z"))
	local turn = base.Rotation * CFrame.Angles(0, math.rad(yaw), 0)
	local top, column = point.Y, point
	if opts.wall then
		local back = turn:VectorToWorldSpace(Vector3.zAxis)
		local start = point - Vector3.new(0, math.min(1, targetHeight * 0.1), 0)
		local hit = workspace:Raycast(start, back * reach, includeParams(supports, true))
		if hit then
			local normal = Vector3.new(hit.Normal.X, 0, hit.Normal.Z)
			if normal.Magnitude > EPS then
				normal = normal.Unit
				turn = CFrame.Angles(0, math.atan2(-normal.X, -normal.Z), 0)
			else
				normal = -back
			end
			local spec = S.assets[key]
			local extent = type(spec) == "table" and type(spec.extent) == "table" and spec.extent or {}
			local height, deep = tonumber(extent[2]), tonumber(extent[3])
			local depth = 0
			if height and deep and height > EPS then depth = deep * targetHeight / height end
			column = Vector3.new(hit.Position.X, point.Y, hit.Position.Z) + normal * (depth / 2 + 0.05)
		else
			issue(api, ("no wall within %g studs behind %q; hanging it at the given point")
				:format(reach, tostring(key)))
		end
	else
		local ceiling = raycastCeiling(point.X, point.Y - HANG_SLACK, point.Z, supports, reach + HANG_SLACK)
		if ceiling then
			top = ceiling
		else
			issue(api, ("nothing within %g studs above %q; hanging it from the given point")
				:format(reach, tostring(key)))
		end
	end
	local world = CFrame.new(column.X, top - targetHeight, column.Z) * turn
	return SG.mesh(key, base:Inverse() * world, targetHeight)
end

-- SG.place, seated. rows is a flat array of (x, z, yaw) triples; each placement
-- is dropped onto the ground at its column. opts matches SG.seat and applies to
-- every placement.
function SG.placeOn(key, base, rows, opts)
	local build = S.protos[key]
	if not build then
		issue("placeOn", ("prototype %q is not defined; skipping placements"):format(tostring(key)))
		return nil
	end
	rows = arr("placeOn", rows, 3)
	if type(base) ~= "string" or base == "" then
		issue("placeOn", "invalid base name; using prototype key")
		base = tostring(key)
	end
	local attributes = type(opts) == "table" and opts.attributes or nil
	local size = type(opts) == "table" and boxSize("placeOn", opts.size) or nil
	if size and type(opts) == "table" and opts.footprint == nil then
		local seated = {}
		for k, v in pairs(opts) do seated[k] = v end
		seated.footprint = { size.X, size.Z }
		opts = seated
	end
	for i = 1, #rows, 3 do
		local n = (i + 2) / 3
		local name = ("%s_%03d"):format(base, n)
		local cf = seatWorld("placeOn", name, rows[i], rows[i + 1], rows[i + 2], opts)
		local model = prototypeModel("placeOn", key, name, cf, attributes, size)
		if not model then model = plainCopy("placeOn", name, cf, build, attributes, size) end
		if type(opts) == "table" and opts.pad then padUnder("placeOn", model, cf, opts) end
	end
	return nil
end

-- ProceduralModels. A Generator ModuleScript builds its object with SG inside
-- SG.into; ProceduralModel:GetBoundingBox() reports Size rather than what was
-- generated, so placement always measures the generated parts.
local function measureParts(instance)
	local low = Vector3.new(math.huge, math.huge, math.huge)
	local high = -low
	local count = 0
	for _, item in ipairs(instance:GetDescendants()) do
		if item:IsA("BasePart") then
			count += 1
			local half = item.Size / 2
			for _, sx in ipairs({ -1, 1 }) do
				for _, sy in ipairs({ -1, 1 }) do
					for _, sz in ipairs({ -1, 1 }) do
						local corner = item.CFrame:PointToWorldSpace(
							Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))
						low = low:Min(corner)
						high = high:Max(corner)
					end
				end
			end
		end
	end
	return count, low, high
end

local function recentre(container, offset)
	for _, item in ipairs(container:GetDescendants()) do
		if item:IsA("BasePart") then
			item.CFrame = item.CFrame - offset
		elseif item:IsA("Model") and not item.PrimaryPart then
			item.WorldPivot = item.WorldPivot - offset
		end
	end
end

-- A scene RCC runs as a game script may not write ModuleScript.Source (it lacks
-- PluginOrOpenCloud). The RCC host script, which may, leaves a
-- BindableFunction that writes it instead.
local function generatorModule(folder, name, source)
	local module = Instance.new("ModuleScript")
	module.Name = name
	local written, writeError = pcall(function() module.Source = source end)
	if not written then
		module:Destroy()
		local installer = game:GetService("ServerStorage"):FindFirstChild(INSTALLER_NAME)
		if not (installer and installer:IsA("BindableFunction")) then error(writeError, 0) end
		module = installer:Invoke(name, source)
		if typeof(module) ~= "Instance" or not module:IsA("ModuleScript") then
			error("the generator installer returned no ModuleScript", 0)
		end
	end
	module.Parent = folder
	return module
end

local LUA_NAME = "^[%a_][%w_]*$"

local function luaLiteral(value, depth)
	depth = depth or 1
	local kind = type(value)
	if kind == "number" then
		if value ~= value or math.abs(value) == math.huge then return "0" end
		return ("%.9g"):format(value)
	elseif kind == "string" then
		return ("%q"):format(value)
	elseif kind == "boolean" then
		return tostring(value)
	elseif kind ~= "table" then
		return "nil"
	end
	local keys = {}
	for key in pairs(value) do keys[#keys + 1] = key end
	if #keys == 0 then return "{}" end
	if #value == #keys then
		local items = {}
		for i = 1, #value do items[i] = luaLiteral(value[i], depth + 1) end
		return "{ " .. table.concat(items, ", ") .. " }"
	end
	table.sort(keys, function(a, b)
		local na, nb = tonumber(a), tonumber(b)
		if na and nb then return na < nb end
		return tostring(a) < tostring(b)
	end)
	local pad = string.rep("\t", depth)
	local lines = {}
	for _, key in ipairs(keys) do
		local label = type(key) == "string" and key:match(LUA_NAME) and key or ("[%s]"):format(luaLiteral(key))
		lines[#lines + 1] = ("%s%s = %s,"):format(pad, label, luaLiteral(value[key], depth + 1))
	end
	return "{\n" .. table.concat(lines, "\n") .. "\n" .. string.rep("\t", depth - 1) .. "}"
end

local function wrapperName(name)
	local folder = S.instanceFolder
	local candidate, extra = name, 1
	while S.wrapperNames[candidate] or (folder and folder:FindFirstChild(candidate)) do
		extra += 1
		candidate = ("%s_%d"):format(name, extra)
	end
	S.wrapperNames[candidate] = true
	return candidate
end

-- The Generator for one ProceduralModel. A model with repairs gets its own
-- wrapper module in Generators.Instances that binds them to the shared one;
-- the rest use the shared module directly.
local function generatorFor(made, shared, state)
	S.shared[made] = shared
	if type(state) ~= "table" or next(state) == nil or not S.instanceFolder then return shared end
	local source = ('local SG = require(game:GetService("ReplicatedStorage").SceneGeneration.SG)\n'
		.. "return SG.bind(require(script.Parent.Parent[%q][%q]), %s)\n")
		:format(shared.Parent.Name, shared.Name, luaLiteral(state))
	local ok, module = pcall(generatorModule, S.instanceFolder, wrapperName(made.Name), source)
	if ok then return module end
	issue("generators", ("%s keeps the shared Generator, so its repairs are lost when it regenerates: %s")
		:format(made.Name, tostring(module)))
	return shared
end

-- Engines without ForceGeneration (roblox-cli 0.730) generate a frame or two
-- later instead, so there the first GeneratedFolder content is waited for.
local function forceGeneration(made)
	local ok, finished = pcall(made.ForceGeneration, made)
	if ok then return finished == true end
	if not tostring(finished):find("not available", 1, true) then error(finished, 0) end
	local deadline = os.clock() + 10
	repeat
		task.wait()
		if tostring(made.GenerationError) ~= "" then return false end
		local folder = made:FindFirstChildOfClass("GeneratedFolder")
		if folder and #folder:GetChildren() > 0 then return true end
	until os.clock() > deadline
	return false
end

-- Studio regenerates a ProceduralModel whenever its Size or Attributes change,
-- and lays the new parts out relative to its pivot. SG.into centres every
-- generation on the generator's origin, so a pivot there is the centre of the
-- Size box Studio draws. The first generation moves the pivot to the first
-- part's rotation, so it is pinned back to the origin afterwards.
local function generateAtOrigin(made)
	made.WorldPivot = CFrame.identity
	if not forceGeneration(made) then
		error("generation did not finish: " .. tostring(made.GenerationError))
	end
	made.WorldPivot = CFrame.identity
end

-- Size the box to what generated, for a model whose first build was measured
-- in the scene's copy of SG and came out otherwise.
local function matchSize(made)
	local count, low, high = measureParts(made)
	if count == 0 then return end
	local extent = high - low
	local delta = extent - made.Size
	if math.max(math.abs(delta.X), math.abs(delta.Y), math.abs(delta.Z)) > SIZE_TOLERANCE then
		made.Size = extent
		generateAtOrigin(made)
	end
end

-- Move a generated object so the bottom centre of its parts lands on base.
local function seatGenerated(model, base)
	local count, low, high = measureParts(model)
	if count == 0 then error("generated no parts") end
	local bottom = Vector3.new((low.X + high.X) / 2, low.Y, (low.Z + high.Z) / 2)
	model:PivotTo(base * CFrame.new(-bottom) * model:GetPivot())
	return high - low
end

-- The drafted centre and box of a prototype copy, built once per key,
-- attributes and size as plain parts that are thrown away. A generation is
-- centred on its parts, so this is where the prototype's own origin lands.
local function prototypeBox(key, attributes, size)
	local id = ("%s|%s|%s"):format(tostring(key), tostring(attributes), tostring(size))
	local box = S.protoBoxes[id]
	if box then return box[1], box[2] end
	local build = S.protos[key]
	if type(build) ~= "function" then return nil, nil end
	local scratch = Instance.new("Model")
	SG.into(scratch, build, attributes, size)
	local centre, extent = S.lastCenter, S.lastExtent
	scratch:Destroy()
	if centre then S.protoBoxes[id] = { centre, extent } end
	return centre, extent
end

-- One copy of an SG.define prototype that the prelude registered as a
-- Generator. The prototype builds in its own local space, so the copy is
-- generated at the origin and then pivoted onto cf, exactly where SG.place
-- would have built it. Inside a generation, prototypes stay plain parts.
-- A size other than the prototype's own box makes its SG.size fit it.
prototypeModel = function(api, key, name, cf, attributes, size)
	local module = S.prototypes and S.prototypes[key]
	if not module or S.generating then return nil end
	if attributes ~= nil and type(attributes) ~= "table" then
		issue(api, "attributes must be a table; ignoring them")
		attributes = nil
	end
	local holder = parent(api)
	local world = S.xforms[#S.xforms] * localCF(api, cf)
	local made
	local ok, err = pcall(function()
		local centre, extent = prototypeBox(key, attributes, size)
		if not centre then error("generated no parts") end
		made = Instance.new("ProceduralModel")
		made.Name = name
		made.Size = size or extent
		for attribute, value in pairs(attributes or {}) do
			if not pcall(made.SetAttribute, made, tostring(attribute), value) then
				issue(api, ("%s attribute %s has an unsupported value; ignoring it"):format(name, tostring(attribute)))
			end
		end
		made.Parent = holder
		local _, repairs = bindZFight(made)
		made.Generator = generatorFor(made, module, repairs and { zf = repairs } or nil)
		generateAtOrigin(made)
		matchSize(made)
		made:PivotTo(world * CFrame.new(centre))
		labelScope(made)
	end)
	if ok then return made end
	if made then made:Destroy() end
	issue(api, ("%s is a plain Model because ProceduralModel failed: %s"):format(name, tostring(err)))
	return nil
end

-- The parts' box in frame's space.
local function partsIn(model, frame)
	local low = Vector3.new(math.huge, math.huge, math.huge)
	local high = -low
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("BasePart") then
			local half = item.Size / 2
			for _, sx in ipairs({ -1, 1 }) do
				for _, sy in ipairs({ -1, 1 }) do
					for _, sz in ipairs({ -1, 1 }) do
						local corner = frame:PointToObjectSpace(item.CFrame:PointToWorldSpace(
							Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)))
						low = low:Min(corner)
						high = high:Max(corner)
					end
				end
			end
		end
	end
	return low, high
end

-- The end of the scene. Each lifted ProceduralModel gets a wrapper Generator
-- with its lift (and any z-fighting repairs) and regenerates from it, so the
-- lift survives the next Size or Attribute change. Its box grows to the lifted
-- parts, and its pivot moves to their centre, which is where the regenerated
-- parts are centred. Then the per-part build markers come off, unless a host
-- asked to keep them.
finishScene = function(lifts)
	for host, bucket in pairs(type(lifts) == "table" and lifts or {}) do
		local shared = S.shared[host]
		if shared and host.Parent then
			local state = { lift = bucket }
			local scope = S.scopes[host]
			local repairs = scope and S.zfModels and S.zfModels[scope]
			if type(repairs) == "table" then state.zf = repairs end
			local old = host.Generator
			local module = generatorFor(host, shared, state)
			if module ~= old then
				local ok, err = pcall(function()
					local pivot = host:GetPivot()
					local low, high = partsIn(host, pivot)
					local readScale, scale = pcall(host.GetScale, host)
					if not readScale or type(scale) ~= "number" or scale <= EPS then scale = 1 end
					if low.X <= high.X then host.Size = (high - low) / scale end
					host.Generator = module
					if not forceGeneration(host) then
						error("generation did not finish: " .. tostring(host.GenerationError), 0)
					end
					host.WorldPivot = pivot
					if low.X <= high.X then host:PivotTo(pivot * CFrame.new((low + high) / 2)) end
				end)
				if ok then
					if old and old ~= shared then
						local name = old.Name
						old:Destroy()
						module.Name = name
					end
					labelScope(host)
				else
					issue("liftSurfaces", ("%s could not take its lift: %s"):format(host.Name, tostring(err)))
				end
			end
		end
	end
	if S.root and not marked(TRACE_MARKER) then
		for _, item in ipairs(S.root:GetDescendants()) do
			if item:IsA("BasePart") then
				for _, attribute in ipairs(BUILD_ATTRIBUTES) do
					if item:GetAttribute(attribute) ~= nil then item:SetAttribute(attribute, nil) end
				end
			end
		end
	end
	S.building = false
	setMarker(BUILD_MARKER, false)
end

-- Build into container with a fresh palette, style, and transform scope.
-- Generators use this instead of SG.scene. attributes is what SG.attributes
-- reads back while build runs, and size (the generator's parameters.Size) is
-- what SG.size reads.
--
-- The object is built at its default size first. If it asked SG.size for its
-- box and that box is not Size, a builder resized it in Studio or the scene
-- asked for a size, so it is built again to fit Size. Either way the parts are
-- then centred on the container's origin, which is the ProceduralModel's pivot.
function SG.into(container, build, attributes, size)
	if typeof(container) ~= "Instance" then
		issue("into", "container must be an Instance; skipping build")
		return nil
	end
	if type(build) ~= "function" then
		issue("into", "build must be a function; skipping build")
		return nil
	end
	local saved = {
		S.parents, S.xforms, S.palette, S.protos, S.lookByKey, S.style,
		S.generating, S.intoWarnings, S.zfIndex, S.zfScope, S.zfActive, S.liftActive,
		S.generatingSize, S.plainSize, S.intoTrace, S.sizeAsked, S.fitSize,
	}
	S.generating = type(attributes) == "table" and attributes or {}
	S.generatingSize = typeof(size) == "Vector3" and size or nil
	S.plainSize = nil
	S.intoTrace = nil
	S.intoTrace = tracing()
	-- SG.bind leaves the wrapper's repairs for this generation. The scene's own
	-- plain-Model fallback leaves its scope too.
	local bound = type(S.bound) == "table" and S.bound or {}
	S.bound = nil
	S.zfScope = type(bound.scope) == "string" and bound.scope or nil
	S.zfActive = type(bound.zf) == "table" and bound.zf or nil
	S.liftActive = type(bound.lift) == "table" and bound.lift or nil
	local before = {}
	for _, child in ipairs(container:GetChildren()) do before[child] = true end
	local function run(fit)
		for _, child in ipairs(container:GetChildren()) do
			if not before[child] then child:Destroy() end
		end
		S.parents, S.xforms, S.palette, S.protos, S.lookByKey = { container }, { CFrame.identity }, {}, {}, {}
		S.style = { nil, Enum.Material.SmoothPlastic, 0, true }
		S.intoWarnings = {}
		S.zfIndex = 0
		S.sizeAsked = false
		S.fitSize = fit
		return pcall(build, container)
	end
	local ok, err = run(nil)
	local count, low, high = measureParts(container)
	-- A zero Size asks for the default build; the measurement host uses it.
	local given = S.generatingSize
	if given and math.max(given.X, given.Y, given.Z) <= EPS then given = nil end
	if ok and S.sizeAsked and given and count > 0 then
		local delta = given - (high - low)
		if math.max(math.abs(delta.X), math.abs(delta.Y), math.abs(delta.Z)) > SIZE_TOLERANCE then
			ok, err = run(given:Max(Vector3.new(MIN_SIZE, MIN_SIZE, MIN_SIZE)))
			count, low, high = measureParts(container)
		end
	end
	S.lastCenter, S.lastExtent = nil, nil
	if count > 0 then
		local centre = (low + high) / 2
		S.lastCenter, S.lastExtent = centre, high - low
		recentre(container, centre)
	end
	local warnings = S.intoWarnings
	S.parents, S.xforms, S.palette, S.protos, S.lookByKey, S.style = saved[1], saved[2], saved[3], saved[4], saved[5], saved[6]
	S.generating, S.intoWarnings = saved[7], saved[8]
	S.zfIndex, S.zfScope, S.zfActive, S.liftActive = saved[9], saved[10], saved[11], saved[12]
	S.generatingSize, S.plainSize, S.intoTrace = saved[13], saved[14], saved[15]
	S.sizeAsked, S.fitSize = saved[16], saved[17]
	if not ok then
		table.insert(warnings, "SG.into: build stopped early: " .. tostring(err))
		issue("into", "build stopped early: " .. tostring(err))
	end
	if S.intoWarnings then
		for _, text in ipairs(warnings) do table.insert(S.intoWarnings, text) end
	else
		for _, text in ipairs(warnings) do logWarning(text) end
	end
	return container
end

-- Reserved for wrapper Generators. A ProceduralModel whose parts were repaired
-- or lifted has its own Generator in ServerStorage.SceneGeneration.Generators
-- .Instances that binds those repairs to the shared Generator:
--   return SG.bind(require(script.Parent.Parent.Objects.Stall), { zf = {...}, lift = {...} })
-- so every generation, in Studio as on RCC, builds the repaired object.
function SG.bind(definition, state)
	if type(definition) ~= "table" or type(definition.OnGenerate) ~= "function" then
		error("SG.bind needs a Generator definition with an OnGenerate function", 2)
	end
	state = type(state) == "table" and state or {}
	local bound = {}
	for key, value in pairs(definition) do bound[key] = value end
	bound.OnGenerate = function(parameters, container)
		local saved = S.bound
		S.bound = state
		local ok, err = pcall(definition.OnGenerate, parameters, container)
		S.bound = saved
		if not ok then error(err, 0) end
	end
	return bound
end

-- The Attributes a generator or scene element declares, with the values the
-- current generation was given. Outside a generation it returns defaults.
function SG.attributes(defaults)
	if type(defaults) ~= "table" then
		issue("attributes", "defaults must be a table")
		return {}
	end
	local current = S.generating or S.plainAttributes
	if not current then return defaults end
	local out = {}
	for name, value in pairs(defaults) do
		local given = current[name]
		out[name] = (given ~= nil and typeof(given) == typeof(value)) and given or value
	end
	return out
end

-- The box an object builds to fit: default, unless SG.into is rebuilding it to
-- fit a Size other than the box its default build measured.
function SG.size(default)
	if typeof(default) ~= "Vector3" then
		issue("size", "default must be a Vector3; using 4 x 4 x 4")
		default = Vector3.new(4, 4, 4)
	end
	if S.plainSize then return S.plainSize end
	S.sizeAsked = true
	return S.fitSize or default
end

local function numbers(value)
	if type(value) ~= "table" then return nil end
	local out = {}
	for i = 1, #value do
		out[i] = tonumber(value[i])
		if out[i] == nil then return nil end
	end
	return out
end

-- A value of the same type as the generator's default, or nil.
local function coerceAttribute(default, value)
	local kind = typeof(default)
	if typeof(value) == kind then return value end
	if kind == "number" then return tonumber(value) end
	if kind == "boolean" and type(value) == "string" then
		local lowered = value:lower()
		if lowered == "true" then return true end
		if lowered == "false" then return false end
		return nil
	end
	if kind == "string" and (type(value) == "number" or type(value) == "boolean") then
		return tostring(value)
	end
	local v = numbers(value)
	if kind == "Color3" and v and #v == 3 then
		if v[1] > 1 or v[2] > 1 or v[3] > 1 then
			return Color3.fromRGB(math.clamp(v[1], 0, 255), math.clamp(v[2], 0, 255), math.clamp(v[3], 0, 255))
		end
		return Color3.new(v[1], v[2], v[3])
	end
	if kind == "Vector3" and v and #v == 3 then return Vector3.new(v[1], v[2], v[3]) end
	return nil
end

local function boundAttribute(api, label, name, schema, value)
	if type(schema) ~= "table" then return value end
	if type(value) == "number" then
		local low, high = tonumber(schema.min), tonumber(schema.max)
		local bounded = math.clamp(value, low or -math.huge, high or math.huge)
		if bounded ~= value then
			issue(api, ("%s attribute %s = %s is outside its range; using %s")
				:format(label, name, tostring(value), tostring(bounded)))
		end
		return bounded
	end
	if type(value) == "string" and type(schema.options) == "table" and #schema.options > 0
		and not table.find(schema.options, value) then
		issue(api, ("%s attribute %s = %q is not one of its options; using the default")
			:format(label, name, value))
		return nil
	end
	return value
end

-- Reserved for the trusted prelude. Installs SG itself as
-- ReplicatedStorage.SceneGeneration.SG and one Generator ModuleScript per
-- object type and scene element. Where a ModuleScript cannot be written, every
-- ProceduralModel is built as a plain Model from the same generator code.
function SG.generators(data)
	if S.generatorsLocked then
		issue("generators", "generators are already registered; ignoring replacement")
		return nil
	end
	if type(data) ~= "table" then
		issue("generators", "generator manifest must be a table")
		return nil
	end
	S.generatorsLocked = true
	S.generators, S.elements, S.prototypes = {}, {}, {}
	local objectFolder, elementFolder, prototypeFolder
	-- The SceneGeneration folder. Declared here so the DP install below can parent into it.
	local sceneFolder
	local installed, installError = pcall(function()
		local replicated = game:GetService("ReplicatedStorage")
		local server = game:GetService("ServerStorage")
		for _, holder in ipairs({ replicated, server }) do
			local old = holder:FindFirstChild("SceneGeneration")
			if old then old:Destroy() end
		end
		sceneFolder = Instance.new("Folder")
		sceneFolder.Name = "SceneGeneration"
		local looks = Instance.new("Configuration")
		looks.Name = "Looks"
		looks.Parent = sceneFolder
		generatorModule(sceneFolder, "SG", tostring(data.runtime or ""))
		sceneFolder.Parent = replicated
		local root = Instance.new("Folder")
		root.Name = "SceneGeneration"
		local generators = Instance.new("Folder")
		generators.Name = "Generators"
		generators.Parent = root
		objectFolder = Instance.new("Folder")
		objectFolder.Name = "Objects"
		objectFolder.Parent = generators
		elementFolder = Instance.new("Folder")
		elementFolder.Name = "Elements"
		elementFolder.Parent = generators
		prototypeFolder = Instance.new("Folder")
		prototypeFolder.Name = "Prototypes"
		prototypeFolder.Parent = generators
		local instanceFolder = Instance.new("Folder")
		instanceFolder.Name = "Instances"
		instanceFolder.Parent = generators
		S.instanceFolder = instanceFolder
		root.Parent = server
		S.looks, S.ownsLooks = looks, true
	end)
	local decalReady = false
	if not installed then
		objectFolder, elementFolder, prototypeFolder, S.instanceFolder = nil, nil, nil, nil
		issue("generators", "ProceduralModels are unavailable here; building plain Models: "
			.. tostring(installError))
	elseif type(data.decalRuntime) == "string" and data.decalRuntime ~= "" then
		-- Published decals. Generators require ReplicatedStorage.SceneGeneration.DP
		-- the same way they require SG. The scene script's own DP global is a
		-- different copy and is not visible inside a ModuleScript.
		local decalInstalled, decalError = pcall(generatorModule, sceneFolder, "DP", data.decalRuntime)
		decalReady = decalInstalled
		if not decalInstalled then
			issue("generators", "DP is unavailable; decal prototypes stay plain Models: "
				.. tostring(decalError))
		end
	end
	local function usesDecalModule(source)
		return type(source) == "string" and string.find(source, "SceneGeneration.DP", 1, true) ~= nil
	end
	for key, spec in pairs(type(data.objects) == "table" and data.objects or {}) do
		local entry = { key = tostring(key), variants = type(spec.variants) == "table" and spec.variants or {} }
		local ok, definition = pcall(spec.build)
		if ok and type(definition) == "table" and type(definition.OnGenerate) == "function" then
			definition.Attributes = type(definition.Attributes) == "table" and definition.Attributes or {}
			definition.Schema = type(definition.Schema) == "table" and definition.Schema or {}
			entry.definition = definition
		else
			issue("generators", ("generator %s did not load: %s"):format(entry.key, tostring(definition)))
		end
		if objectFolder and entry.definition then
			local made, module = pcall(generatorModule, objectFolder, entry.key, tostring(spec.source or ""))
			if made then
				entry.module = module
			else
				issue("generators", ("generator %s has no ModuleScript: %s"):format(entry.key, tostring(module)))
			end
		end
		S.generators[entry.key] = entry
	end
	for id, source in pairs(type(data.elements) == "table" and data.elements or {}) do
		S.elementSources[tostring(id)] = tostring(source)
		if elementFolder and (decalReady or not usesDecalModule(source)) then
			local made, module = pcall(generatorModule, elementFolder, tostring(id), tostring(source))
			if made then S.elements[tostring(id)] = module end
		end
	end
	for key, source in pairs(type(data.prototypes) == "table" and data.prototypes or {}) do
		if prototypeFolder and (decalReady or not usesDecalModule(source)) then
			local made, module = pcall(generatorModule, prototypeFolder, tostring(key), tostring(source))
			if made then S.prototypes[tostring(key)] = module end
		end
	end
	return nil
end

local function proceduralValues(api, label, entry, variant, attributes)
	local defaults, schema = entry.definition.Attributes, entry.definition.Schema
	local values = {}
	local fixed = type(variant) == "table" and type(variant.values) == "table" and variant.values or {}
	for name, raw in pairs(fixed) do
		local value = nil
		if defaults[name] ~= nil then
			value = coerceAttribute(defaults[name], raw)
			if value ~= nil then value = boundAttribute(api, label, name, schema[name], value) end
		end
		if value == nil then
			issue(api, ("%s variant value for %s does not fit the generator; ignoring it")
				:format(label, tostring(name)))
		else
			values[name] = value
		end
	end
	if attributes ~= nil and type(attributes) ~= "table" then
		issue(api, "attributes must be a table; ignoring them")
		attributes = nil
	end
	for name, raw in pairs(attributes or {}) do
		local rule = schema[name]
		if defaults[name] == nil then
			issue(api, ("%s has no attribute %s; ignoring it"):format(label, tostring(name)))
		elseif type(rule) == "table" and rule.shape and fixed[name] == nil then
			issue(api, ("%s attribute %s changes its shape; choose a variant instead")
				:format(label, tostring(name)))
		else
			local value = coerceAttribute(defaults[name], raw)
			if value ~= nil then value = boundAttribute(api, label, name, rule, value) end
			if value == nil then
				issue(api, ("%s attribute %s has the wrong type; ignoring it"):format(label, tostring(name)))
			else
				values[name] = value
			end
		end
	end
	return values
end

-- Place one ProceduralModel built by the generator registered as key.
-- variant names a measured shape ("default" when nil); cf is the centre of the
-- footprint on the ground; targetHeight sets one uniform scale; attributes may
-- only set style attributes. opts.size = {width, height, depth} rebuilds the
-- object to fit that box before targetHeight scales it.
function SG.procedural(key, variant, cf, targetHeight, attributes, opts)
	targetHeight = pos("procedural", targetHeight, "targetHeight")
	local fit = type(opts) == "table" and boxSize("procedural", opts.size) or nil
	local entry = S.generators[key]
	if not entry or not entry.definition then
		issue("procedural", ("generator %q is not registered; skipping object"):format(tostring(key)))
		return nil
	end
	variant = variant == nil and "default" or tostring(variant)
	local spec = entry.variants[variant]
	if type(spec) ~= "table" then
		issue("procedural", ("%s has no variant %q; using default"):format(entry.key, variant))
		variant, spec = "default", entry.variants.default
	end
	local extent = type(spec) == "table" and numbers(spec.extent)
	if not extent or #extent ~= 3 or extent[2] <= EPS then
		issue("procedural", ("%s variant %s has no measured size; skipping object"):format(entry.key, variant))
		return nil
	end
	local base = S.xforms[#S.xforms] * localCF("procedural", cf)
	local holder = parent("procedural")
	local name = nextName(holder, entry.key)
	local values = proceduralValues("procedural", name, entry, spec, attributes)
	local measured = Vector3.new(extent[1], extent[2], extent[3])
	local size = fit or measured
	local scale = targetHeight / size.Y
	if entry.module then
		local made
		local ok, err = pcall(function()
			made = Instance.new("ProceduralModel")
			made.Name = name
			made.Size = size
			for attribute, value in pairs(values) do made:SetAttribute(attribute, value) end
			made.Parent = holder
			local _, repairs = bindZFight(made)
			made.Generator = generatorFor(made, entry.module, repairs and { zf = repairs } or nil)
			made.WorldPivot = CFrame.identity
			if math.abs(scale - 1) > EPS then made:ScaleTo(scale) end
			generateAtOrigin(made)
			seatGenerated(made, base)
			labelScope(made)
		end)
		if ok then return made end
		if made then made:Destroy() end
		issue("procedural", ("%s is a plain Model because ProceduralModel failed: %s"):format(name, tostring(err)))
	end
	local model
	local ok, err = pcall(function()
		local merged = {}
		for attribute, value in pairs(entry.definition.Attributes) do merged[attribute] = value end
		for attribute, value in pairs(values) do merged[attribute] = value end
		model = Instance.new("Model")
		model.Name = name
		for attribute, value in pairs(merged) do pcall(model.SetAttribute, model, attribute, value) end
		local scope, repairs = bindZFight(model)
		local generated = Instance.new("Folder")
		generated.Name = "Generated"
		generated.Parent = model
		model.Parent = holder
		S.bound = { scope = scope, zf = repairs }
		local generatedOk, generateError = pcall(entry.definition.OnGenerate,
			{ Attributes = merged, Size = size, Pause = function() end }, generated)
		S.bound = nil
		if not generatedOk then error(generateError, 0) end
		if math.abs(scale - 1) > EPS then model:ScaleTo(scale) end
		seatGenerated(model, base)
	end)
	if not ok then
		if model then model:Destroy() end
		issue("procedural", ("%s could not be generated; skipping object: %s"):format(name, tostring(err)))
		return nil
	end
	return model
end

-- SG.procedural seated on the ground at (x, z) facing yaw, like SG.meshOn.
-- opts matches SG.seat; the footprint defaults to the scaled measured base.
function SG.proceduralOn(key, variant, x, z, yaw, targetHeight, attributes, opts)
	opts = type(opts) == "table" and opts or {}
	local entry = S.generators[key]
	local spec = entry and (entry.variants[variant == nil and "default" or tostring(variant)] or entry.variants.default)
	local extent = type(spec) == "table" and numbers(spec.extent)
	local fit = boxSize("proceduralOn", opts.size)
	if fit then extent = { fit.X, fit.Y, fit.Z } end
	if opts.footprint == nil and opts.y == nil and extent and #extent == 3 and extent[2] > EPS then
		local scale = pos("proceduralOn", targetHeight, "targetHeight") / extent[2]
		local seated = {}
		for k, v in pairs(opts) do seated[k] = v end
		seated.footprint = { math.max(extent[1] * scale, MIN_SIZE), math.max(extent[3] * scale, MIN_SIZE) }
		opts = seated
	end
	local cf = seatWorld("proceduralOn", key, x, z, yaw, opts)
	local model = SG.procedural(key, variant, cf, targetHeight, attributes, fit and { size = fit } or nil)
	if opts.pad then padUnder("proceduralOn", model, cf, opts) end
	return model
end

-- A scene element (road, path, fence, river, plaza, floor) or any other object
-- built from SG primitives, as its own ProceduralModel. build uses world
-- coordinates and may call SG.attributes once for its style Attributes. The
-- prelude registers a Generator made from the same code; without one, build
-- runs here as an ordinary group.
function SG.element(name, build)
	if type(name) ~= "string" or name == "" then
		issue("element", "name must be a non-empty string; using Element")
		name = "Element"
	end
	if type(build) ~= "function" then
		issue("element", "build must be a function; skipping element")
		return nil
	end
	local label = name:match("([^/]+)$") or name
	local module = S.elements[name]
	if module then
		-- The Generator must not edit the Terrain, since it regenerates whenever a
		-- builder retunes it. An element that grades a road or a pad runs once
		-- here first, into a scratch Model, to grade and store the result the
		-- Generator then builds from. Every element is then built once more as
		-- scratch to find where its parts are, since its generation is centred on
		-- them and so cannot say where in the world it belongs.
		local source = S.elementSources[name]
		local graded = not S.generating and type(source) == "string"
			and (source:find("SG%.road") or source:find("pad%s*=")) ~= nil
		if graded then
			local scratch = Instance.new("Model")
			S.gradePass = true
			SG.into(scratch, build)
			S.gradePass = false
			scratch:Destroy()
		end
		local scratch = Instance.new("Model")
		SG.into(scratch, build)
		local centre, extent = S.lastCenter, S.lastExtent
		scratch:Destroy()
		local holder = parent("element")
		local xform = S.xforms[#S.xforms]
		local made
		local ok, err = pcall(function()
			if not centre and graded then
				-- An unpaved path lives in the graded Terrain and builds no parts.
				made = false
				return
			end
			if not centre then error("generated no parts") end
			made = Instance.new("ProceduralModel")
			made.Name = label
			made.Size = extent
			made.Parent = holder
			local _, repairs = bindZFight(made)
			made.Generator = generatorFor(made, module, repairs and { zf = repairs } or nil)
			generateAtOrigin(made)
			if measureParts(made) == 0 then error("generated no parts") end
			matchSize(made)
			made:PivotTo(xform * CFrame.new(centre))
			labelScope(made)
		end)
		if ok and made == false then
			local empty = Instance.new("Model")
			empty.Name = label
			empty.Parent = holder
			return empty
		end
		if ok then return made end
		if made then made:Destroy() end
		issue("element", ("%s is a plain Model because ProceduralModel failed: %s"):format(name, tostring(err)))
	end
	return scoped("element", label, nil, build)
end

-- Terrain: height-field writer, noise and distance helpers for landscapes.

local TERRAIN_VOXEL = 4
local TERRAIN_CHUNK = 32 -- voxels per side in one WriteVoxels call
local TERRAIN_STAND_IN_CELLS = 5000 -- RCC stand-in parts, under the proxy's 12k cap
-- The isosurface sits 2 studs (1.75 to 2 on slopes) above the filled height,
-- measured in Studio; writing that much lower puts the surface at the height asked for.
-- Water shows no such offset: its surface lands where it is filled.
local TERRAIN_BLEED = 2
-- One-octave math.noise has a standard deviation of about 0.27 and peaks near
-- +/-0.98; dividing by this keeps the normalised sum inside -1..1.
local NOISE_PEAK = 0.9

local function terrainMaterial(api, value, fallback, cache)
	if value == nil then return fallback end
	local hit = cache[value]
	if hit then return hit end
	local material = resolveMaterial(api, value) or fallback
	cache[value] = material
	return material
end

function SG.terrainField(x0, z0, x1, z1, sample, opts)
	local api = "terrainField"
	if type(sample) ~= "function" then
		issue(api, "sample must be a function(x, z) returning height, material, waterLevel; skipping call")
		return
	end
	opts = type(opts) == "table" and opts or {}
	x0, z0 = num(api, x0, "x0"), num(api, z0, "z0")
	x1, z1 = num(api, x1, "x1"), num(api, z1, "z1")
	if x1 < x0 then x0, x1 = x1, x0 end
	if z1 < z0 then z0, z1 = z1, z0 end
	x0, z0 = math.floor(x0 / TERRAIN_VOXEL) * TERRAIN_VOXEL, math.floor(z0 / TERRAIN_VOXEL) * TERRAIN_VOXEL
	x1, z1 = math.ceil(x1 / TERRAIN_VOXEL) * TERRAIN_VOXEL, math.ceil(z1 / TERRAIN_VOXEL) * TERRAIN_VOXEL
	if x1 - x0 < TERRAIN_VOXEL or z1 - z0 < TERRAIN_VOXEL then
		issue(api, "the rectangle is smaller than one 4-stud voxel; skipping call")
		return
	end
	local cache = {}
	local ground = terrainMaterial(api, "Ground", Enum.Material.Ground, cache)
	local under = opts.under ~= nil and terrainMaterial(api, opts.under, nil, cache) or nil
	local underDepth = opts.underDepth ~= nil and pos(api, opts.underDepth, "underDepth") or 8
	-- sample may return a material function(y, depth) instead of a name; it is
	-- called per voxel with the voxel's centre y and its depth below the surface.
	local layerFailed = false
	local function layer(fn, y, depth)
		local ok, value = pcall(fn, y, depth)
		if not ok then
			if not layerFailed then
				issue(api, ("material function failed: %s; using Ground"):format(tostring(value)))
				layerFailed = true
			end
			return ground
		end
		return terrainMaterial(api, value, ground, cache)
	end

	-- In RCC the Terrain is a part-building proxy (a table, not an Instance).
	-- There one coarse box per cell stands in for the voxels.
	local terrain = workspace.Terrain
	local standIn = typeof(terrain) ~= "Instance"
	local step = TERRAIN_VOXEL
	if standIn then
		local columns = (x1 - x0) * (z1 - z0) / (TERRAIN_VOXEL * TERRAIN_VOXEL)
		step = TERRAIN_VOXEL * math.max(1, math.ceil(math.sqrt(columns / TERRAIN_STAND_IN_CELLS)))
	end
	local nx, nz = math.ceil((x1 - x0) / step), math.ceil((z1 - z0) / step)

	local heights, materials, waters = {}, {}, {}
	local lowest, highest = math.huge, -math.huge
	local badHeight = false
	for i = 1, nx do
		local x = x0 + (i - 0.5) * step
		for k = 1, nz do
			local z = z0 + (k - 0.5) * step
			local ok, h, m, w = pcall(sample, x, z)
			if not ok then
				issue(api, ("sample(%g, %g) failed: %s; skipping call"):format(x, z, tostring(h)))
				return
			end
			h = tonumber(h)
			if h == nil or h ~= h or math.abs(h) == math.huge then
				badHeight = true
				h = 0
			end
			w = tonumber(w)
			if w ~= nil and (w ~= w or math.abs(w) == math.huge) then w = nil end
			local index = (i - 1) * nz + k
			heights[index] = h
			materials[index] = type(m) == "function" and m or terrainMaterial(api, m, ground, cache)
			waters[index] = w
			lowest = math.min(lowest, h)
			highest = math.max(highest, h, w or h)
		end
	end
	if badHeight then
		issue(api, "sample returned a height that is not a finite number; using 0 there")
	end
	local bottom = opts.bottom ~= nil and num(api, opts.bottom, "bottom") or (lowest - underDepth - 8)
	bottom = math.floor(bottom / TERRAIN_VOXEL) * TERRAIN_VOXEL
	local top = math.ceil((highest + TERRAIN_VOXEL) / TERRAIN_VOXEL) * TERRAIN_VOXEL

	if standIn then
		for i = 1, nx do
			local x = x0 + (i - 0.5) * step
			for k = 1, nz do
				local z = z0 + (k - 0.5) * step
				local index = (i - 1) * nz + k
				local h, m, w = heights[index], materials[index], waters[index]
				if type(m) == "function" then
					m = layer(m, h - TERRAIN_VOXEL / 2, TERRAIN_VOXEL / 2)
				end
				if h > bottom then
					terrain:FillBlock(CFrame.new(x, (bottom + h) / 2, z), Vector3.new(step, h - bottom, step), m)
				end
				if w and w > math.max(h, bottom) then
					local base = math.max(h, bottom)
					terrain:FillBlock(CFrame.new(x, (base + w) / 2, z), Vector3.new(step, w - base, step), Enum.Material.Water)
				end
			end
		end
		return
	end

	local ny = (top - bottom) / TERRAIN_VOXEL
	local air, water = Enum.Material.Air, Enum.Material.Water
	for ci = 1, nx, TERRAIN_CHUNK do
		local sx = math.min(TERRAIN_CHUNK, nx - ci + 1)
		for ck = 1, nz, TERRAIN_CHUNK do
			local sz = math.min(TERRAIN_CHUNK, nz - ck + 1)
			local mats, occs = {}, {}
			for i = 1, sx do
				local mi, oi = {}, {}
				mats[i], occs[i] = mi, oi
				for j = 1, ny do
					mi[j], oi[j] = {}, {}
				end
				for k = 1, sz do
					local index = (ci + i - 2) * nz + (ck + k - 1)
					local surface, m, w = heights[index], materials[index], waters[index]
					local h = surface - TERRAIN_BLEED
					local layered = type(m) == "function"
					for j = 1, ny do
						local base = bottom + (j - 1) * TERRAIN_VOXEL
						local fill = math.clamp((h - base) / TERRAIN_VOXEL, 0, 1)
						local wet = w and math.clamp((w - base) / TERRAIN_VOXEL, 0, 1) or 0
						-- A voxel holds one material: a thin bed voxel (under half full)
						-- holding at least half a voxel more water than ground becomes
						-- water, so shallow water such as a flooded paddy is not lost.
						if fill > 0 and not (fill < 0.5 and wet >= fill + 0.5) then
							local centre = base + TERRAIN_VOXEL / 2
							if layered then
								mi[j][k] = layer(m, centre, surface - centre)
							else
								mi[j][k] = (under and base + TERRAIN_VOXEL <= h - underDepth) and under or m
							end
							oi[j][k] = fill
						elseif wet > 0 then
							mi[j][k] = water
							oi[j][k] = wet
						else
							mi[j][k] = air
							oi[j][k] = 0
						end
					end
				end
			end
			local lo = Vector3.new(x0 + (ci - 1) * TERRAIN_VOXEL, bottom, z0 + (ck - 1) * TERRAIN_VOXEL)
			local hi = lo + Vector3.new(sx * TERRAIN_VOXEL, top - bottom, sz * TERRAIN_VOXEL)
			terrain:WriteVoxels(Region3.new(lo, hi), TERRAIN_VOXEL, mats, occs)
		end
	end
	-- Raycasts only see a Terrain edit a few frames later.
	for _ = 1, 4 do
		task.wait()
	end
end

-- Grading. A paved road or a building pad reshapes the Terrain under itself.
-- A paved road then stands on a foundation deeper than the voxel surface can
-- miss by, so neither a gap nor the ground shows through it. An unpaved path
-- is the graded Terrain itself, painted with its material. A pad levels the
-- ground a little above the building's base, so the building always touches
-- it, and builds nothing. Grading runs only
-- while the scene builds; a generator that regenerates later rebuilds from the
-- stored result and never edits the Terrain.
local GRADE_SINK = 1 -- graded surface under a paved deck
local GRADE_EDGE = 2 -- graded core past the edge of a deck or footprint
local GRADE_SHOULDER = 10 -- blend back to the natural ground over this width
local GRADE_MATERIAL = "Ground"
local GRADE_STORE = "Grades"
local ROAD_SPACING = 4
local ROAD_LIFT = 0.25 -- deck top above the smoothed natural ground
local ROAD_DECK = 0.4
local ROAD_DEPTH = 6
-- A road that crosses an earlier one sits this far under it, beyond the band
-- the face audit treats as coplanar.
local ROAD_CROSSING = 0.05
-- The voxel surface lands 0 to 0.13 studs under its target, so a pad aiming
-- this far above the base meets it flush to within about 0.15, never below.
local PAD_RISE = 0.13
-- How deep an unpaved path's material reaches, and the export proxy's
-- painted slab over a path column.
local PATH_PAINT_DEPTH = 2 * TERRAIN_VOXEL
local PATH_PROXY_THICKNESS = 0.2
local PATH_PROXY_LIFT = 0.05

local function gradeKey(x, z)
	return ("%d,%d"):format(math.floor(x / TERRAIN_VOXEL), math.floor(z / TERRAIN_VOXEL))
end

local function gradeStore(create)
	local ok, store = pcall(function()
		local shared = game:GetService("ReplicatedStorage"):FindFirstChild("SceneGeneration")
		if not shared then return nil end
		local found = shared:FindFirstChild(GRADE_STORE)
		if not found and create then
			found = Instance.new("Configuration")
			found.Name = GRADE_STORE
			found.Parent = shared
		end
		return found
	end)
	return ok and store or nil
end

local function grading()
	return S.gradePass or not S.generating
end

-- Reshape the Terrain columns of a rectangle. target(x, z) returns dist,
-- surface, deck, paint: dist <= 0 inside the core, the graded surface there,
-- the deck or floor height the core carries, and whether the column is part of
-- an unpaved path whose top takes the paint material. The shoulder blends back
-- to the natural ground. A column an earlier road or pad already graded keeps
-- that grade in a shoulder, and in a core takes the lower of the two surfaces.
local function gradeTerrain(api, x0, z0, x1, z1, shoulder, material, target, paint)
	x0, z0 = math.floor(x0 / TERRAIN_VOXEL) * TERRAIN_VOXEL, math.floor(z0 / TERRAIN_VOXEL) * TERRAIN_VOXEL
	x1, z1 = math.ceil(x1 / TERRAIN_VOXEL) * TERRAIN_VOXEL, math.ceil(z1 / TERRAIN_VOXEL) * TERRAIN_VOXEL
	local nx, nz = (x1 - x0) / TERRAIN_VOXEL, (z1 - z0) / TERRAIN_VOXEL
	local supports = { terrainSupport() }
	local plans, low, high = {}, math.huge, -math.huge
	for i = 1, nx do
		local x = x0 + (i - 0.5) * TERRAIN_VOXEL
		for k = 1, nz do
			local z = z0 + (k - 0.5) * TERRAIN_VOXEL
			local dist, surface, deck, painted = target(x, z)
			if dist and dist < shoulder then
				local key = gradeKey(x, z)
				local locked = S.gradeCols[key]
				local natural = raycastSupport(x, z, supports, true)
				local wanted
				if dist <= 0 then
					wanted = locked and math.min(surface, locked.surface) or surface
					S.gradeCols[key] = { surface = wanted, deck = locked and math.max(deck, locked.deck) or deck }
				elseif not locked and natural then
					local u = dist / shoulder
					u = u * u * (3 - 2 * u)
					wanted = surface + (natural - surface) * u
				end
				if wanted and natural then
					plans[(i - 1) * nz + k] = {
						target = wanted, core = dist <= 0, paint = paint ~= nil and painted and dist <= 0,
					}
					low = math.min(low, wanted, natural)
					high = math.max(high, wanted, natural)
				end
			end
		end
	end
	if low == math.huge then return end

	-- In RCC the Terrain is the export proxy's parts. Cut the blocks a core
	-- passes through down to its surface so the export matches Studio.
	local terrain = workspace.Terrain
	if typeof(terrain) ~= "Instance" then
		local folder = workspace:FindFirstChild("I2LFakedTerrain")
		for _, part in ipairs(folder and folder:GetChildren() or {}) do
			if part:IsA("Part") and part.Shape == Enum.PartType.Block and part.Material ~= Enum.Material.Glass then
				local p = part.Position
				local i = math.floor((p.X - x0) / TERRAIN_VOXEL) + 1
				local k = math.floor((p.Z - z0) / TERRAIN_VOXEL) + 1
				local plan = i >= 1 and i <= nx and k >= 1 and k <= nz and plans[(i - 1) * nz + k]
				local bottom = p.Y - part.Size.Y / 2
				if plan and plan.core and p.Y + part.Size.Y / 2 > plan.target and plan.target - bottom > 0.05 then
					part.Size = Vector3.new(part.Size.X, plan.target - bottom, part.Size.Z)
					part.CFrame = CFrame.new(p.X, (bottom + plan.target) / 2, p.Z)
				end
			end
		end
		-- A proxy block can span many columns, so a path is shown as a thin slab
		-- of its material over each painted column rather than by recolouring.
		if paint and terrain and type(terrain.FillBlock) == "function" then
			for i = 1, nx do
				for k = 1, nz do
					local plan = plans[(i - 1) * nz + k]
					if plan and plan.paint then
						local top = plan.target + PATH_PROXY_LIFT
						pcall(terrain.FillBlock, terrain,
							CFrame.new(x0 + (i - 0.5) * TERRAIN_VOXEL, top - PATH_PROXY_THICKNESS / 2, z0 + (k - 0.5) * TERRAIN_VOXEL),
							Vector3.new(TERRAIN_VOXEL, PATH_PROXY_THICKNESS, TERRAIN_VOXEL), paint)
					end
				end
			end
		end
		return
	end

	local bottom = math.floor((low - 12) / TERRAIN_VOXEL) * TERRAIN_VOXEL
	local top = math.ceil((high + 8) / TERRAIN_VOXEL) * TERRAIN_VOXEL
	local ny = (top - bottom) / TERRAIN_VOXEL
	local air, water, grass = Enum.Material.Air, Enum.Material.Water, Enum.Material.Grass
	local bare = terrainMaterial(api, material, Enum.Material.Ground, {})
	if bare == grass then bare = Enum.Material.Ground end
	for ci = 1, nx, TERRAIN_CHUNK do
		local sx = math.min(TERRAIN_CHUNK, nx - ci + 1)
		for ck = 1, nz, TERRAIN_CHUNK do
			local sz = math.min(TERRAIN_CHUNK, nz - ck + 1)
			local touched = false
			for i = 1, sx do
				for k = 1, sz do
					if plans[(ci + i - 2) * nz + (ck + k - 1)] then touched = true end
				end
			end
			if touched then
				local lo = Vector3.new(x0 + (ci - 1) * TERRAIN_VOXEL, bottom, z0 + (ck - 1) * TERRAIN_VOXEL)
				local hi = lo + Vector3.new(sx * TERRAIN_VOXEL, top - bottom, sz * TERRAIN_VOXEL)
				local region = Region3.new(lo, hi)
				local mats, occs = terrain:ReadVoxels(region, TERRAIN_VOXEL)
				for i = 1, sx do
					for k = 1, sz do
						local plan = plans[(ci + i - 2) * nz + (ck + k - 1)]
						if plan then
							local surfaceMaterial = bare
							for j = ny, 1, -1 do
								local m = mats[i][j][k]
								if m ~= air and m ~= water then
									surfaceMaterial = m
									break
								end
							end
							-- Grass blades poke through whatever covers them.
							if plan.core and surfaceMaterial == grass then surfaceMaterial = bare end
							local h = plan.target - TERRAIN_BLEED
							for j = 1, ny do
								local fill = math.clamp((h - (bottom + (j - 1) * TERRAIN_VOXEL)) / TERRAIN_VOXEL, 0, 1)
								local m = mats[i][j][k]
								if fill > 0 then
									local solid = (m ~= air and m ~= water) and m or surfaceMaterial
									if plan.core and solid == grass then solid = bare end
									if plan.paint and h - (bottom + (j - 1) * TERRAIN_VOXEL) <= PATH_PAINT_DEPTH then
										solid = paint
									end
									mats[i][j][k], occs[i][j][k] = solid, fill
								elseif m ~= water then
									mats[i][j][k], occs[i][j][k] = air, 0
								end
							end
						end
					end
				end
				terrain:WriteVoxels(region, TERRAIN_VOXEL, mats, occs)
			end
		end
	end
	for _ = 1, 4 do
		task.wait()
	end
end

local function markGraded(list, into)
	local trace = tracing()
	for _, part in ipairs(list) do
		if typeof(part) == "Instance" then
			if trace then pcall(part.SetAttribute, part, GRADED_ATTRIBUTE, true) end
			into[#into + 1] = part
		end
	end
end

-- The natural ground at a column: the Terrain, or the water surface over it.
local function naturalHeight(x, z)
	local supports = { terrainSupport() }
	local ground = raycastSupport(x, z, supports, true)
	local wet = raycastSupport(x, z, supports, false)
	if ground and wet and wet > ground then return wet + ROAD_LIFT end
	return ground
end

-- The centre line every ROAD_SPACING studs, keeping each given vertex.
local function roadSamples(pts)
	local out = { pts[1] }
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local run = Vector3.new(b.X - a.X, 0, b.Z - a.Z).Magnitude
		if run > EPS then
			local n = math.max(1, math.ceil(run / ROAD_SPACING))
			for s = 1, n do
				out[#out + 1] = a:Lerp(b, s / n)
			end
		end
	end
	return out
end

-- Deck heights along the centre line: the natural ground across the road's
-- width, smoothed along it. Where an earlier road's graded core lies under a
-- sample, the height is pinned just under that road's deck, so a crossing meets
-- the road it crosses instead of stepping up or down to it.
local function roadProfile(api, pts, width, opts)
	local samples = roadSamples(pts)
	local n = #samples
	local hw = width / 2
	local heights, pinned = {}, {}
	for i, s in ipairs(samples) do
		local a, b = samples[math.max(1, i - 1)], samples[math.min(n, i + 1)]
		local along = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
		local side = along.Magnitude > EPS and Vector3.yAxis:Cross(along.Unit) * hw * 0.8 or Vector3.zero
		local total, count = 0, 0
		for _, offset in ipairs({ Vector3.zero, side, -side }) do
			local y = naturalHeight(s.X + offset.X, s.Z + offset.Z)
			if y then
				total += y
				count += 1
			end
		end
		heights[i] = count > 0 and total / count + (opts.foundation == false and 0 or ROAD_LIFT) or s.Y
		local locked = S.gradeCols[gradeKey(s.X, s.Z)]
		if locked then pinned[i] = locked.deck - ROAD_CROSSING end
	end
	local reach = opts.smooth ~= nil and math.max(0, num(api, opts.smooth, "smooth")) or math.max(16, width * 2)
	local radius = math.ceil(reach / ROAD_SPACING)
	for _ = 1, radius > 0 and 3 or 0 do
		local prefix = { 0 }
		for i = 1, n do prefix[i + 1] = prefix[i] + heights[i] end
		local smoothed = {}
		for i = 1, n do
			local a, b = math.max(1, i - radius), math.min(n, i + radius)
			smoothed[i] = pinned[i] or (prefix[b + 1] - prefix[a]) / (b - a + 1)
		end
		heights = smoothed
	end
	local profile = {}
	for i, s in ipairs(samples) do profile[i] = Vector3.new(s.X, pinned[i] or heights[i], s.Z) end
	return profile
end

local function gradeRoad(api, profile, width, opts)
	local hw = width / 2
	local shoulder = opts.shoulder ~= nil and math.max(0, num(api, opts.shoulder, "shoulder")) or GRADE_SHOULDER
	local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
	for _, p in ipairs(profile) do
		x0, z0 = math.min(x0, p.X), math.min(z0, p.Z)
		x1, z1 = math.max(x1, p.X), math.max(z1, p.Z)
	end
	local margin = hw + GRADE_EDGE + shoulder + TERRAIN_VOXEL
	-- An unpaved path is the ground itself: graded to its profile and painted
	-- with its material at least one voxel column wide.
	local unpaved = opts.foundation == false
	local paint = unpaved and terrainMaterial(api, opts.material or GRADE_MATERIAL, Enum.Material.Ground, {}) or nil
	if paint == Enum.Material.Water or paint == Enum.Material.Air then paint = Enum.Material.Ground end
	local painted = math.max(hw, TERRAIN_VOXEL / 2)
	gradeTerrain(api, x0 - margin, z0 - margin, x1 + margin, z1 + margin, shoulder, opts.material or GRADE_MATERIAL,
		function(x, z)
			local best, deck = math.huge, profile[1].Y
			for i = 1, #profile - 1 do
				local a, b = profile[i], profile[i + 1]
				local dx, dz = b.X - a.X, b.Z - a.Z
				local length2 = dx * dx + dz * dz
				local t = length2 > 0 and math.clamp(((x - a.X) * dx + (z - a.Z) * dz) / length2, 0, 1) or 0
				local d = (x - a.X - dx * t) ^ 2 + (z - a.Z - dz * t) ^ 2
				if d < best then best, deck = d, a.Y + (b.Y - a.Y) * t end
			end
			local distance = math.sqrt(best)
			return distance - hw - GRADE_EDGE, unpaved and deck or deck - GRADE_SINK, deck,
				unpaved and distance <= painted
		end, paint)
end

-- Keep only the profile points that bend the line by more than tolerance.
local function simplifyLine(line, tolerance)
	local keep = { [1] = true, [#line] = true }
	local function walk(first, last)
		local a, b = line[first], line[last]
		local ab = b - a
		local length2 = ab:Dot(ab)
		local worst, index = tolerance, nil
		for i = first + 1, last - 1 do
			local t = length2 > 0 and math.clamp((line[i] - a):Dot(ab) / length2, 0, 1) or 0
			local d = (line[i] - (a + ab * t)).Magnitude
			if d > worst then worst, index = d, i end
		end
		if index then
			keep[index] = true
			walk(first, index)
			walk(index, last)
		end
	end
	walk(1, #line)
	local out = {}
	for i, p in ipairs(line) do
		if keep[i] then out[#out + 1] = p end
	end
	return out
end

-- A deck ROAD_DECK thick whose top follows the profile, mitred at each bend,
-- over a foundation down to depth below it: the same triangles in the base
-- key, offset along each face's normal so the two meet without overlapping.
local function buildDeck(api, profile, width, key, opts)
	local line = simplifyLine(profile, 0.05)
	local hw = width / 2
	local depth = math.max(ROAD_DECK + 0.5, opts.depth ~= nil and pos(api, opts.depth, "depth") or ROAD_DEPTH)
	local baseKey = opts.base or key
	local function flat(v)
		local f = Vector3.new(v.X, 0, v.Z)
		return f.Magnitude > EPS and f.Unit or nil
	end
	local left, right, made = {}, {}, {}
	for i, p in ipairs(line) do
		local incoming = flat(p - line[math.max(1, i - 1)]) or flat(line[math.min(#line, i + 1)] - p) or Vector3.xAxis
		local outgoing = flat(line[math.min(#line, i + 1)] - p) or incoming
		local tangent = flat(incoming + outgoing) or outgoing
		local side = Vector3.yAxis:Cross(tangent).Unit
		local mitre = 1 / math.max(0.5, side:Dot(Vector3.yAxis:Cross(outgoing).Unit))
		left[i], right[i] = p - side * hw * mitre, p + side * hw * mitre
	end
	local drop = Vector3.new(0, ROAD_DECK / 2, 0)
	local function deck(list)
		if not tracing() then return list end
		for _, part in ipairs(list) do
			if typeof(part) == "Instance" then pcall(part.SetAttribute, part, ROAD_ATTRIBUTE, true) end
		end
		return list
	end
	local height = depth - ROAD_DECK
	local function slab(a, b, c)
		markGraded(deck(triangle(api, a - drop, b - drop, c - drop, ROAD_DECK, key)), made)
		local normal = (b - a):Cross(c - a)
		if normal.Magnitude <= EPS then return end
		normal = normal.Unit * (normal.Y < 0 and -1 or 1)
		local below = normal * ((ROAD_DECK + height) / 2)
		markGraded(triangle(api, a - drop - below, b - drop - below, c - drop - below, height, baseKey), made)
	end
	for i = 1, #line - 1 do
		local j = i + 1
		slab(left[i], right[i], right[j])
		slab(left[i], right[j], left[j])
	end
	return made
end

local function encodeProfile(profile)
	local out = {}
	for _, p in ipairs(profile) do
		out[#out + 1] = ("%.3f,%.3f,%.3f"):format(p.X, p.Y, p.Z)
	end
	return table.concat(out, ";")
end

local function decodeProfile(text)
	if type(text) ~= "string" then return nil end
	local out = {}
	for x, y, z in text:gmatch("([^,;]+),([^,;]+),([^,;]+)") do
		local px, py, pz = tonumber(x), tonumber(y), tonumber(z)
		if not (px and py and pz) then return nil end
		out[#out + 1] = Vector3.new(px, py, pz)
	end
	return #out >= 2 and out or nil
end

-- A road's identity is its centre line in plan and its width, not its heights,
-- which may have been read from the ground before or after grading.
local function roadKey(pts, width)
	local hash = 5381
	local function feed(value)
		for i = 1, #value do hash = (hash * 33 + string.byte(value, i)) % 4294967296 end
	end
	for _, p in ipairs(pts) do feed(("%.2f,%.2f;"):format(p.X, p.Z)) end
	feed(("%.2f"):format(width))
	return ("road_%08x"):format(hash)
end

-- A road, street, plaza strip or path along points ({x,y,z, ...}, as SG.curve
-- returns). The Terrain under it is graded to its profile, and an earlier road
-- it crosses keeps its height at the crossing. A paved road's deck stands on a
-- foundation; with opts.foundation = false the path is the graded Terrain
-- itself, painted with opts.material, and no part is built. y is used only
-- where there is no Terrain. Returns the top line as {x,y,z, ...}. opts: depth
-- (foundation below the deck top, default 6), shoulder (blend width, default
-- 10), smooth (studs of smoothing along the road), material (graded Terrain
-- under the core, and an unpaved path's surface; default Ground), base (key
-- for the foundation; default key), name (the deck's Model, default Road).
function SG.road(data, width, key, opts)
	local api = "road"
	local pts = points(api, data)
	if #pts < 2 then return nil end
	width = pos(api, width, "width")
	opts = type(opts) == "table" and opts or {}
	-- Profiles live in world space, which is what an element's build and its
	-- Generator both author in; the deck is built back in the caller's frame.
	local base = S.xforms[1]:Inverse() * S.xforms[#S.xforms]
	for i, p in ipairs(pts) do pts[i] = base * p end
	local id = roadKey(pts, width)
	local profile
	if grading() then
		profile = roadProfile(api, pts, width, opts)
		gradeRoad(api, profile, width, opts)
		S.gradeProfiles[id] = profile
		local store = gradeStore(true)
		if store then pcall(store.SetAttribute, store, id, encodeProfile(profile)) end
	else
		profile = S.gradeProfiles[id]
		if not profile then
			local store = gradeStore(false)
			profile = store and decodeProfile(store:GetAttribute(id)) or nil
		end
		if not profile then
			issue(api, "this road was not graded when the scene built; following the ground as it is")
			profile = roadProfile(api, pts, width, opts)
		end
	end
	local line = {}
	for i, p in ipairs(profile) do line[i] = base:PointToObjectSpace(p) end
	if not S.gradePass and opts.foundation ~= false then
		local name = type(opts.name) == "string" and opts.name ~= "" and opts.name or "Road"
		scoped(api, name, nil, function()
			buildDeck(api, line, width, key, opts)
		end)
	end
	local out = {}
	for _, p in ipairs(line) do
		out[#out + 1], out[#out + 2], out[#out + 3] = p.X, p.Y, p.Z
	end
	return out
end

-- Level the Terrain up to a seated object's base across its whole footprint,
-- carving a slope or filling a hollow. No part is built. The footprint is what
-- reaches down to the base, so a roof overhang does not widen it. opts.pad is
-- true or {shoulder, material}.
padUnder = function(api, model, cf, opts)
	if typeof(model) ~= "Instance" then return end
	local settings = type(opts.pad) == "table" and opts.pad or {}
	-- frame is the seat in world space; parts are measured from their place in
	-- the container's root frame.
	local root = S.xforms[1]
	local frame = root:Inverse() * S.xforms[#S.xforms] * cf
	local near = { math.huge, -math.huge, math.huge, -math.huge }
	local all = { math.huge, -math.huge, math.huge, -math.huge }
	local function grow(box, p)
		box[1], box[2] = math.min(box[1], p.X), math.max(box[2], p.X)
		box[3], box[4] = math.min(box[3], p.Z), math.max(box[4], p.Z)
	end
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("BasePart") then
			local half, corners, lowest = item.Size / 2, {}, math.huge
			for _, sx in ipairs({ -1, 1 }) do
				for _, sy in ipairs({ -1, 1 }) do
					for _, sz in ipairs({ -1, 1 }) do
						local corner = frame:PointToObjectSpace(root:PointToObjectSpace(
							item.CFrame:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))))
						corners[#corners + 1] = corner
						lowest = math.min(lowest, corner.Y)
					end
				end
			end
			for _, corner in ipairs(corners) do
				grow(all, corner)
				if lowest <= 1 then grow(near, corner) end
			end
		end
	end
	local box = near[1] < math.huge and near or all
	if box[1] == math.huge then return end
	local cx, cz = (box[1] + box[2]) / 2, (box[3] + box[4]) / 2
	local hx, hz = (box[2] - box[1]) / 2, (box[4] - box[3]) / 2
	if grading() then
		local shoulder = settings.shoulder ~= nil and math.max(0, num(api, settings.shoulder, "pad shoulder"))
			or GRADE_SHOULDER
		local floor = frame.Position.Y
		local reach = math.max(hx, hz) + GRADE_EDGE + shoulder + TERRAIN_VOXEL
		local centre = frame:PointToWorldSpace(Vector3.new(cx, 0, cz))
		gradeTerrain(api, centre.X - reach * 1.5, centre.Z - reach * 1.5, centre.X + reach * 1.5,
			centre.Z + reach * 1.5, shoulder, settings.material or GRADE_MATERIAL, function(x, z)
				local p = frame:PointToObjectSpace(Vector3.new(x, floor, z))
				local dx = math.abs(p.X - cx) - hx - GRADE_EDGE
				local dz = math.abs(p.Z - cz) - hz - GRADE_EDGE
				local outside = math.sqrt(math.max(dx, 0) ^ 2 + math.max(dz, 0) ^ 2)
				return outside > 0 and outside or math.max(dx, dz), floor + PAD_RISE, floor
			end)
	end
end

function SG.noise(x, z, scale, octaves, seed)
	local api = "noise"
	x, z = num(api, x, "x"), num(api, z, "z")
	scale = pos(api, scale or 64, "scale")
	octaves = math.min(8, octaves ~= nil and whole(api, octaves, "octaves") or 4)
	seed = seed ~= nil and num(api, seed, "seed") or 0
	local fx, fz = x / scale, z / scale
	-- Fractional offsets keep samples off the integer lattice, where math.noise is 0.
	local w = (seed % 4096) * 0.6180339 + 0.5
	local sum, amplitude, power = 0, 1, 0
	for o = 1, octaves do
		sum += amplitude * math.noise(fx + o * 13.37 + 0.31, fz - o * 7.91 + 0.73, w + o * 3.17)
		power += amplitude * amplitude
		amplitude *= 0.5
		fx *= 2
		fz *= 2
	end
	return math.clamp(sum / math.sqrt(power) / NOISE_PEAK, -1, 1)
end

function SG.pathDistance(data, x, z, stride)
	local api = "pathDistance"
	stride = stride == 3 and 3 or 2
	data = arr(api, data, stride)
	x, z = num(api, x, "x"), num(api, z, "z")
	local count = #data // stride
	if count == 0 then
		issue(api, "points must hold at least one point; returning math.huge")
		return math.huge, 0
	end
	local zOffset = stride - 1
	local ax, az = data[1], data[1 + zOffset]
	local best = math.sqrt((x - ax) ^ 2 + (z - az) ^ 2)
	local bestAlong, travelled = 0, 0
	for p = 2, count do
		local bx, bz = data[(p - 1) * stride + 1], data[(p - 1) * stride + 1 + zOffset]
		local dx, dz = bx - ax, bz - az
		local length2 = dx * dx + dz * dz
		local length = math.sqrt(length2)
		local t = length2 > 0 and math.clamp(((x - ax) * dx + (z - az) * dz) / length2, 0, 1) or 0
		local d = math.sqrt((x - ax - t * dx) ^ 2 + (z - az - t * dz) ^ 2)
		if d < best then
			best, bestAlong = d, travelled + t * length
		end
		travelled += length
		ax, az = bx, bz
	end
	return best, travelled > 0 and bestAlong / travelled or 0
end

function SG.blend(h, target, distance, inner, outer)
	local api = "blend"
	h, target = num(api, h, "h"), num(api, target, "target")
	distance = num(api, distance, "distance")
	inner, outer = num(api, inner, "inner"), num(api, outer, "outer")
	if outer < inner then inner, outer = outer, inner end
	if distance <= inner then return target end
	if distance >= outer then return h end
	local t = (outer - distance) / (outer - inner)
	t = t * t * (3 - 2 * t)
	return h + (target - h) * t
end

-- Edge noise is sampled on a circle of this radius in noise space, so the
-- outline wraps around without a seam.
local BLOB_NOISE_RADIUS = 1.6

function SG.ellipseDistance(x, z, cx, cz, rx, rz, roughness, seed)
	local api = "ellipseDistance"
	x, z = num(api, x, "x"), num(api, z, "z")
	cx, cz = num(api, cx, "cx"), num(api, cz, "cz")
	rx = pos(api, rx, "rx")
	rz = rz ~= nil and pos(api, rz, "rz") or rx
	roughness = roughness ~= nil and math.clamp(num(api, roughness, "roughness"), 0, 0.9) or 0
	local nx, nz = (x - cx) / rx, (z - cz) / rz
	local r = math.sqrt(nx * nx + nz * nz)
	if r == 0 or roughness == 0 then return r end
	local edge = 1 + roughness * SG.noise(nx / r * BLOB_NOISE_RADIUS, nz / r * BLOB_NOISE_RADIUS, 1, 3, seed)
	return r / edge
end

-- An SG function the model invented does not exist, and calling a nil field
-- would kill the whole scene on the spot. Every other SG mistake warns and
-- keeps building, so this one does too.
setmetatable(SG, {
	__index = function(_, key)
		return function()
			issue(tostring(key), "no such SG function; skipping call")
			return nil
		end
	end,
})

return SG
]=],
	objects = {
	},
	elements = {
		["routes/street-and-forecourt"] = [[
local SG = require(game:GetService("ReplicatedStorage").SceneGeneration.SG)
local Attributes = {SidewalkMaterial="Concrete",StreetWidth=12}
return {
	Attributes = Attributes,
	Schema = { SidewalkMaterial = { shape = false }, StreetWidth = { shape = false } },
	OnGenerate = function(parameters, container)
		SG.into(container, function()
					local A=SG.attributes{SidewalkMaterial="Concrete",StreetWidth=12}
					SG.group("Two Way Neighborhood Street",nil,function()
						local streetTop=SG.road({-35,0,-47,35,0,-47},A.StreetWidth,"road",{shoulder=0,depth=3})
						local h=streetTop[2]
						for x=-30,30,12 do
							SG.box(6,0.04,0.18,SG.pos(x,h+0.15,-47),"cream")
						end
					end)
					SG.group("Storefront Pedestrian Forecourt",nil,function()
						SG.style("concrete",A.SidewalkMaterial)
						SG.road({-35,0,-59,35,0,-59},10,"concrete",{shoulder=0,depth=3})
						SG.road({0,0,-59,0,0,-64},14,"concrete",{shoulder=0,depth=3})
						SG.road({27,0,-59,27,0,-72},12,"concrete",{shoulder=0,depth=3})
					end)

		end, parameters.Attributes, parameters.Size)
	end,
}
]],
		["structures/mixed-use-building"] = [[
local SG = require(game:GetService("ReplicatedStorage").SceneGeneration.SG)
local DP = require(game:GetService("ReplicatedStorage").SceneGeneration.DP)
local Attributes = {WallColor="white",BalconyColor="dark",Curtains=true}
return {
	Attributes = Attributes,
	Schema = { WallColor = { shape = false }, BalconyColor = { shape = false }, Curtains = { shape = false } },
	OnGenerate = function(parameters, container)
		SG.into(container, function()
					local A=SG.attributes{WallColor="white",BalconyColor="dark",Curtains=true}
					SG.seat("Mori Store and Apartments",0,-80,0,function()
						SG.group("Convenience Store Shell",nil,function()
							SG.box(42,0.5,30,SG.pos(0,0.25,0),"concrete")
							SG.boxes{
								42,10,0.6,0,5.5,-15,A.WallColor,
								0.6,10,30,-21,5.5,0,A.WallColor,
								0.6,10,30,21,5.5,0,A.WallColor,
								42,0.6,30,0,10.7,0,"white"
							}
							for _,x in ipairs({-20,-4.5,4.5,20}) do
								SG.box(0.4,8,0.4,SG.pos(x,4.5,15),"dark")
							end
							for _,x in ipairs({-12.2,12.2}) do
								SG.box(15,7.5,0.18,SG.pos(x,4.4,15),"glass")
								SG.box(15,0.35,0.5,SG.pos(x,0.7,15),"dark")
							end
							SG.box(42,1.5,0.65,SG.pos(0,9.4,15),"teal")
							SG.box(42,0.22,0.7,SG.pos(0,8.55,15),"lime")
							SG.box(42,0.22,0.7,SG.pos(0,10.25,15),"orange")
						end)
						SG.group("Open Sliding Double Entrance",nil,function()
							for _,x in ipairs({-5.4,5.4}) do
								SG.box(3.5,7.7,0.18,SG.pos(x,4.35,15.15),"glass")
								for _,dx in ipairs({-1.75,1.75}) do
									SG.box(0.12,7.7,0.25,SG.pos(x+dx,4.35,15.15),"metal")
								end
								SG.box(0.1,1.5,0.3,SG.pos(x,4,15.35),"metal")
							end
							SG.box(9,0.4,0.6,SG.pos(0,8.4,15),"dark")
							SG.box(8,0.06,0.2,SG.pos(0,0.56,15),"metal")
						end)
						SG.group("Illuminated Store Fascia",nil,function()
							SG.style("cream","Neon")
							local panel=SG.box(18,2.1,0.25,SG.cframe(0,9.55,15.5,0,180,0),"cream")
							local art=DP.decal("rbxassetid://105862367698424")
							DP.applyDecalOnFace(panel,panel.CFrame.LookVector,art)
							SG.light("surface",SG.cframe(0,9.5,15.8,0,180,0),"cream",12,1.4)
						end)
						SG.group("Bright Store Ceiling Lighting",nil,function()
							SG.style("cream","Neon")
							for _,x in ipairs({-12,0,12}) do
								SG.box(7,0.12,1,SG.pos(x,10.25,0),"cream")
								SG.light("point",SG.pos(x,9.7,0),"cream",18,1.2)
							end
						end)
						SG.group("Checkout Counter",SG.pos(12,0.5,10),function()
							SG.box(6,3,2.5,SG.pos(0,1.5,0),"teal")
							SG.box(6.3,0.2,2.8,SG.pos(0,3.1,0),"white")
							SG.box(1.4,0.2,1,SG.pos(0,3.3,0),"dark")
							SG.box(1.2,0.8,0.12,SG.cframe(0,3.8,0,0,180,0),"ink")
						end)
						SG.group("Rear Refrigerated Drinks Cases",nil,function()
							for _,x in ipairs({-13,-6,1,8}) do
								SG.group("Glass Refrigerator "..x,SG.pos(x,0.5,-12.8),function()
									SG.box(6,7.8,2.5,SG.pos(0,3.9,0),"dark")
									SG.box(5.5,7.1,0.12,SG.pos(0,3.9,1.3),"glass")
									for row=1,4 do
										SG.box(5.4,0.12,1.8,SG.pos(0,row*1.5,0.6),"white")
										for col=1,7 do
											SG.disc(0.22,0.8,SG.pos(-2.5+col*0.65,row*1.5+0.45,0.65),"blue")
										end
									end
									SG.box(0.1,1.4,0.2,SG.pos(2.4,4,1.4),"metal")
								end)
							end
						end)
						for floor=1,3 do
							local y=11+(floor-1)*10
							SG.group("Apartment Level "..floor,nil,function()
								SG.box(42,0.4,30,SG.pos(0,y+0.2,0),"concrete")
								SG.box(42,1.8,30,SG.pos(0,y+1.3,0),A.WallColor)
								SG.box(42,2.3,30,SG.pos(0,y+8.85,0),A.WallColor)
								for _,x in ipairs({-21,-7,7,21}) do
									SG.box(0.65,6.2,30,SG.pos(x,y+4.8,0),A.WallColor)
								end
								SG.box(42,6.2,0.4,SG.pos(0,y+4.8,-15),A.WallColor)
								for _,x in ipairs({-14,0,14}) do
									SG.group("Balcony Apartment "..x,nil,function()
										SG.box(11.6,5.6,0.18,SG.pos(x,y+4.7,15),"glass")
										if A.Curtains then
											for _,dx in ipairs({-4.1,4.1}) do
												SG.box(2.9,5.2,0.15,SG.pos(x+dx,y+4.6,14.5),"curtain")
												for p=-1,1 do
													SG.box(0.12,5.2,0.12,SG.pos(x+dx+p*0.65,y+4.6,14.65),"cream")
												end
											end
										end
										SG.box(0.2,5.6,0.25,SG.pos(x,y+4.7,15.2),"dark")
										SG.box(12.5,0.4,3.4,SG.pos(x,y+0.4,16.7),"concrete")
										for _,z in ipairs({15.2,18.3}) do
											SG.box(12.5,0.14,0.14,SG.pos(x,y+3.4,z),A.BalconyColor)
										end
										for p=0,10 do
											SG.box(0.1,2.9,0.1,SG.pos(x-6+p*1.2,y+1.9,18.3),A.BalconyColor)
										end
										for _,dx in ipairs({-6.1,6.1}) do
											SG.box(0.13,2.9,3.2,SG.pos(x+dx,y+1.9,16.7),A.BalconyColor)
										end
										SG.group("Balcony Air Conditioner",SG.pos(x+4.4,y+0.6,16.4),function()
											SG.box(2.2,1.6,1,SG.pos(0,0.8,0),"white")
											SG.disc(0.58,0.08,SG.cframe(0,0.8,0.55,90,0,0),"metal")
											for p=-2,2 do
												SG.box(1.1,0.07,0.08,SG.pos(0,0.8+p*0.2,0.64),"dark")
											end
										end)
									end)
								end
								SG.box(0.1,6.5,3.4,SG.pos(21.4,y+3.65,-10),"teal")
							end)
						end
						SG.group("Flat Roof and Safety Rail",nil,function()
							SG.box(42,0.5,30,SG.pos(0,41.25,0),"concrete")
							for _,z in ipairs({-14.8,14.8}) do
								SG.box(42,0.12,0.12,SG.pos(0,44,z),"dark")
								for x=-21,21,3 do SG.box(0.12,2.5,0.12,SG.pos(x,42.75,z),"dark") end
							end
							for _,x in ipairs({-20.8,20.8}) do
								SG.box(0.12,0.12,30,SG.pos(x,44,0),"dark")
								for z=-15,15,3 do
									if x<0 or z>-6 then
										SG.box(0.12,2.5,0.12,SG.pos(x,42.75,z),"dark")
									end
								end
							end
						end)
						SG.group("Roof Water Tank",SG.pos(-12,41.5,-8),function()
							SG.box(6,0.5,6,SG.pos(0,0.25,0),"dark")
							SG.disc(2.3,4.8,SG.pos(0,2.9,0),"metal")
							SG.frustum(2.3,0.8,0.7,12,SG.pos(0,5.65,0),"metal")
						end)
						SG.group("Solar Array",nil,function()
							for x=0,12,6 do
								SG.box(5,0.3,7,SG.cframe(x,42.4,-5,-12,0,0),"blue")
								SG.box(0.2,1,6,SG.pos(x,42,-5),"metal")
							end
						end)
						SG.group("Roof Antenna",nil,function()
							SG.segment(17,41.5,-11,17,49,-11,0.15,"metal")
							for y=46,48,1 do SG.segment(15,y,-11,19,y,-11,0.1,"metal") end
						end)
						SG.group("Window Promotion Poster",nil,function()
							local panel=SG.box(3.2,4.8,0.05,SG.cframe(-14,4.2,15.2,0,180,0),"cream")
							local art=DP.decal("rbxassetid://94794852545308")
							DP.applyDecalOnFace(panel,panel.CFrame.LookVector,art)
						end)
					end,{pad=true,footprint={42,30}})

		end, parameters.Attributes, parameters.Size)
	end,
}
]],
		["structures/exterior-stair"] = [[
local SG = require(game:GetService("ReplicatedStorage").SceneGeneration.SG)
local Attributes = {RailColor="dark",StepMaterial="Concrete"}
return {
	Attributes = Attributes,
	Schema = { RailColor = { shape = false }, StepMaterial = { shape = false } },
	OnGenerate = function(parameters, container)
		SG.into(container, function()
					local A=SG.attributes{RailColor="dark",StepMaterial="Concrete"}
					SG.style("concrete",A.StepMaterial)
					SG.group("Eastern Switchback Staircase",nil,function()
						local base=SG.ground(27,-88) or 0
						for level=0,3 do
							local bottom=base
							local rise=11
							if level>0 then bottom=base+11+(level-1)*10 rise=10 end
							for flight=1,2 do
								local x=24
								if flight==2 then x=30 end
								local startY=bottom+(flight-1)*rise/2
								SG.group("Stair Flight "..level.."-"..flight,nil,function()
									for step=1,20 do
										local z=-88+(step-0.5)*0.5
										if flight==2 then z=-78-(step-0.5)*0.5 end
										local top=startY+step*rise/40
										SG.box(5,0.28,0.55,SG.pos(x,top-0.14,z),"concrete")
										if step%4==0 then
											for _,dx in ipairs({-2.4,2.4}) do
												SG.box(0.1,3,0.1,SG.pos(x+dx,top+1.5,z),A.RailColor)
											end
										end
									end
									local za=-88 local zb=-78
									if flight==2 then za=-78 zb=-88 end
									for _,dx in ipairs({-2.4,2.4}) do
										SG.segment(x+dx,startY+3,za,x+dx,startY+rise/2+3,zb,0.12,A.RailColor)
										SG.segment(x+dx,startY-0.35,za,x+dx,startY+rise/2-0.35,zb,0.25,"metal")
									end
								end)
							end
							SG.group("Stair Landings "..level,nil,function()
								SG.box(11,0.3,4,SG.pos(27,bottom+rise/2-0.15,-76),"concrete")
								SG.box(12,0.3,4,SG.pos(27,bottom+rise-0.15,-90),"concrete")
								SG.box(11,0.12,0.12,SG.pos(27,bottom+rise/2+3,-74),"dark")
								SG.box(12,0.12,0.12,SG.pos(27,bottom+rise+3,-92),"dark")
								for x=22,32,2 do
									SG.box(0.12,3,0.12,SG.pos(x,bottom+rise/2+1.5,-74),"dark")
									SG.box(0.12,3,0.12,SG.pos(x,bottom+rise+1.5,-92),"dark")
								end
							end)
						end
					end)

		end, parameters.Attributes, parameters.Size)
	end,
}
]],
	},
	prototypes = {
		["StockedConvenienceShelf"] = [[
local SG = require(game:GetService("ReplicatedStorage").SceneGeneration.SG)
local Attributes = {ShelfCount=4,StockColor="orange"}
return {
	Attributes = Attributes,
	Schema = { ShelfCount = { shape = false }, StockColor = { shape = false } },
	OnGenerate = function(parameters, container)
		SG.into(container, function()
					local A=SG.attributes{ShelfCount=4,StockColor="orange"}
					local s=SG.size(Vector3.new(4,6,2))
					SG.boxes{
						0.18,s.Y,s.Z,-s.X/2,s.Y/2,0,"white",
						0.18,s.Y,s.Z,s.X/2,s.Y/2,0,"white",
						s.X,0.2,s.Z,0,0.1,0,"white"
					}
					for level=1,A.ShelfCount do
						local y=0.4+(level-1)*(s.Y-1)/A.ShelfCount
						SG.box(s.X,0.13,s.Z,SG.pos(0,y,0),"white")
						for col=1,5 do
							local x=-s.X/2+col*s.X/6
							SG.box(0.5,0.8,0.45,SG.pos(x,y+0.47,-0.55),A.StockColor)
							SG.box(0.4,0.16,0.46,SG.pos(x,y+0.75,-0.56),"cream")
							SG.box(0.5,0.75,0.45,SG.pos(x,y+0.44,0.55),"teal")
						end
						SG.box(s.X,0.18,0.06,SG.pos(0,y+0.1,-s.Z/2-0.03),"lime")
					end

		end, parameters.Attributes, parameters.Size)
	end,
}
]],
	},
})

-- @sg:decal-runtime
local DecalPrimitives = {}
local function _dpDoc()
	return DecalPrimitives.dslModule
end
DecalPrimitives.dslModule = setmetatable({}, {
	__index = function()
		return _dpDoc
	end,
})
local NORMAL_ID_BY_NAME: { [string]: Enum.NormalId } = {
	Top = Enum.NormalId.Top,
	Bottom = Enum.NormalId.Bottom,
	Front = Enum.NormalId.Front,
	Back = Enum.NormalId.Back,
	Left = Enum.NormalId.Left,
	Right = Enum.NormalId.Right,
}

local function resolveNormalId(face: any): Enum.NormalId
	if face == nil then
		return Enum.NormalId.Front
	end
	if typeof(face) == "EnumItem" and (face :: EnumItem).EnumType == Enum.NormalId then
		return face :: Enum.NormalId
	end
	if type(face) == "string" and NORMAL_ID_BY_NAME[face] then
		return NORMAL_ID_BY_NAME[face]
	end
	error("addTexture: invalid 'face' (use Enum.NormalId.Top/Bottom/Front/Back/Left/Right)")
end

-- Marks an un-uploaded decal whose pixels travel in the decal manifest rather than
-- in a published asset. Generation rewrites DP.decal([[<svg>]]) to one of these
-- when it rasterizes without publishing; the host paints it from the manifest.
local DECAL_REF_PREFIX = "pgdecal:"

local function isDecalRef(textureId: any): boolean
	return type(textureId) == "string" and string.sub(textureId, 1, #DECAL_REF_PREFIX) == DECAL_REF_PREFIX
end

-- Accepts a numeric asset id, a content string, or a decal ref, and returns a
-- normalized identifier.
local function normalizeContentId(textureId: any): string
	if type(textureId) == "number" then
		return "rbxassetid://" .. tostring(math.floor(textureId))
	end
	if type(textureId) == "string" then
		if #textureId == 0 then
			error("addTexture: 'textureId' is empty")
		end
		-- Refs are manifest keys, not content; never coerce them to an asset id.
		if isDecalRef(textureId) then
			return textureId
		end
		if string.find(textureId, "://", 1, true) then
			return textureId
		end
		if string.match(textureId, "^%d+$") then
			return "rbxassetid://" .. textureId
		end
		return textureId
	end
	error("addTexture: 'textureId' must be an asset id (number) or content string")
end

-- Point a Texture at its imagery. A published asset goes straight onto .Texture.
-- The host replaces a decal ref with that asset id before this script is saved.
local function assignDecalContent(texture: Texture, contentId: string)
	if isDecalRef(contentId) then
		texture:SetAttribute("DecalRef", contentId)
	else
		texture.Texture = contentId
	end
end

-- Width/height of a BasePart face in studs, expressed along the Texture's U/V axes.
local function faceStudSize(part: BasePart, face: Enum.NormalId): (number, number)
	local s = part.Size
	if face == Enum.NormalId.Top or face == Enum.NormalId.Bottom then
		return s.X, s.Z
	elseif face == Enum.NormalId.Left or face == Enum.NormalId.Right then
		return s.Z, s.Y
	end
	return s.X, s.Y
end

local function faceArea(part: BasePart, face: Enum.NormalId): number
	local u, v = faceStudSize(part, face)
	return u * v
end

-- Preference order is used to break area ties between opposite faces (which always
-- have equal area). Front first keeps a cube/box defaulting to its Front face, while
-- a flat plate/quad/prism (broad face on Top) resolves to Top, and a thin wall
-- (broad face on Front/Back) resolves to Front.
local LARGEST_FACE_PREFERENCE: { Enum.NormalId } = {
	Enum.NormalId.Front,
	Enum.NormalId.Top,
	Enum.NormalId.Right,
	Enum.NormalId.Back,
	Enum.NormalId.Bottom,
	Enum.NormalId.Left,
}

-- Returns the face with the greatest surface area (the "broad" face). Ties are broken
-- by LARGEST_FACE_PREFERENCE so the result is deterministic and intuitive.
local function largestFace(part: BasePart): Enum.NormalId
	local best = Enum.NormalId.Front
	local bestArea = -1
	for _, f in LARGEST_FACE_PREFERENCE do
		local a = faceArea(part, f)
		if a > bestArea + 1e-4 then
			bestArea = a
			best = f
		end
	end
	return best
end

-- Outward unit normal of each face in the PART'S LOCAL space (Roblox convention:
-- Front = -Z, Back = +Z, Right = +X, Left = -X, Top = +Y, Bottom = -Y).
local LOCAL_FACE_NORMAL: { [Enum.NormalId]: Vector3 } = {
	[Enum.NormalId.Front] = Vector3.new(0, 0, -1),
	[Enum.NormalId.Back] = Vector3.new(0, 0, 1),
	[Enum.NormalId.Right] = Vector3.new(1, 0, 0),
	[Enum.NormalId.Left] = Vector3.new(-1, 0, 0),
	[Enum.NormalId.Top] = Vector3.new(0, 1, 0),
	[Enum.NormalId.Bottom] = Vector3.new(0, -1, 0),
}

local ALL_FACES: { Enum.NormalId } = {
	Enum.NormalId.Front,
	Enum.NormalId.Back,
	Enum.NormalId.Right,
	Enum.NormalId.Left,
	Enum.NormalId.Top,
	Enum.NormalId.Bottom,
}

-- The LOCAL-space direction that a Texture's "up" (its +V axis) points when Texture.Rotation
-- is 0, per face -- the BLOCK frame. Measured by rendering an arrow marker on each face of an
-- axis-aligned block. The four side faces share +Y; the two horizontal caps point +Z. This
-- frame holds for blocks and ALL CSG PartOperations; native Ball/Cylinder Parts flip the
-- BOTTOM face (handled by faceDecalUp). Used to right an oriented decal without re-baking art.
local LOCAL_FACE_UP: { [Enum.NormalId]: Vector3 } = {
	[Enum.NormalId.Front] = Vector3.new(0, 1, 0),
	[Enum.NormalId.Back] = Vector3.new(0, 1, 0),
	[Enum.NormalId.Right] = Vector3.new(0, 1, 0),
	[Enum.NormalId.Left] = Vector3.new(0, 1, 0),
	[Enum.NormalId.Top] = Vector3.new(0, 0, 1),
	[Enum.NormalId.Bottom] = Vector3.new(0, 0, 1),
}

-- Chooses the face whose OUTWARD WORLD normal points most nearly along worldDir, using
-- the part's actual CFrame. This is the reliable way to texture "the surface facing the
-- camera / a given direction" regardless of how a primitive oriented its local axes
-- (quadFromFourPoints, prisms, wedges, rotated parts, CSG results, etc.).
--
-- World convention used across PrimitiveGen: the model's front faces the camera at -Z,
-- the viewer's left is +X, and up is +Y. So e.g. worldDir = Vector3.new(0,0,-1) selects
-- the front-facing surface; Vector3.new(0,1,0) selects the upward surface.
--
-- When two faces point nearly the same way (within DIR_TIE), the larger-area face wins,
-- which prevents picking a thin sliver edge that happens to share the direction.
local function faceForWorldDirection(part: BasePart, worldDir: Vector3): Enum.NormalId
	local mag = worldDir.Magnitude
	if mag < 1e-6 then
		return largestFace(part)
	end
	local dir = worldDir / mag
	local cf = part.CFrame
	local DIR_TIE = 0.02
	local best = Enum.NormalId.Front
	local bestDot = -math.huge
	local bestArea = -1
	for _, f in ALL_FACES do
		local worldNormal = cf:VectorToWorldSpace(LOCAL_FACE_NORMAL[f])
		local dot = worldNormal:Dot(dir)
		local area = faceArea(part, f)
		if dot > bestDot + DIR_TIE or (dot > bestDot - DIR_TIE and area > bestArea + 1e-4) then
			bestDot = math.max(dot, bestDot)
			bestArea = area
			best = f
		end
	end
	return best
end

-- ===========================================================================
-- Shape-driven texture orientation
-- ---------------------------------------------------------------------------
-- Which faces are flat vs curved, which way a decal's "up" points, and which axis
-- a pattern wraps around are all fixed properties of the part's SHAPE. Native Parts
-- expose it as part.Shape; our CSG builders record it in a "Shape" attribute (e.g.
-- "Capsule"). shapeOf() unifies the two, and the tables below are the single source
-- of truth -- no per-part world-space curve vectors are stored or trig-derived.
-- ===========================================================================

-- Plain shape name: a native Part's PartType (Block/Ball/Cylinder/Wedge/...), or the
-- "Shape" attribute set by the GP CSG constructors, or nil for an untagged/generic
-- solid (e.g. a user-made union of several parts).
local function shapeOf(part: BasePart): string?
	if part:IsA("Part") then
		return (part :: Part).Shape.Name
	end
	local attr = part:GetAttribute("Shape")
	if type(attr) == "string" then
		return attr
	end
	return nil
end

-- How a shape's faces curve, for applyDecalOnFace's flat-vs-curved decision:
--   "all"      every face curved (sphere, capsule, dome shell)
--   "axial"    flat only on the end caps (local normal parallel to the long axis)
--   "hemiflat" flat only on the single flat face (local normal = -long axis)
--   (absent)   flat-faced: block, prism, wedge, rounded box, pyramid, tube, generic CSG
local SHAPE_CURVATURE: { [string]: string } = {
	Ball = "all",
	Cylinder = "axial",
	Capsule = "all",
	Cone = "axial",
	TaperedCylinder = "axial",
	HollowCylinder = "axial",
	HollowTaperedCylinder = "axial",
	Hemisphere = "hemiflat",
	HollowHemisphere = "all",
}

-- The shape's long axis in its OWN LOCAL frame. Every GP round/axial shape is built with
-- its length along local +X (cylinder, cone, tapered/hollow cylinder, capsule, hemisphere
-- pole); regularPrism runs along local +Y. Used both to find the end caps (above) and as the
-- default axis for DP.wrapDecalAround. A multi-segment tube's union frame is NOT
-- length-aligned, so it is intentionally omitted -- the wrap estimates its axis from the bounding
-- box or takes an explicit wrapAxis.
local SHAPE_LOCAL_AXIS: { [string]: Vector3 } = {
	Cylinder = Vector3.new(1, 0, 0),
	Cone = Vector3.new(1, 0, 0),
	TaperedCylinder = Vector3.new(1, 0, 0),
	HollowCylinder = Vector3.new(1, 0, 0),
	HollowTaperedCylinder = Vector3.new(1, 0, 0),
	Capsule = Vector3.new(1, 0, 0),
	Hemisphere = Vector3.new(1, 0, 0),
	HollowHemisphere = Vector3.new(1, 0, 0),
	RegularPrism = Vector3.new(0, 1, 0),
}

-- LOCAL-space direction the Texture's +V ("up") points at Rotation 0, per face. The block
-- frame (LOCAL_FACE_UP) holds for blocks and ALL CSG PartOperations; native Ball and Cylinder
-- Parts are the lone exception -- their BOTTOM face is flipped 180 deg (its +V points to the
-- front, -Z, not the back). Measured by rendering arrow markers on every face of every shape.
local function faceDecalUp(part: BasePart, face: Enum.NormalId): Vector3
	if face == Enum.NormalId.Bottom and part:IsA("Part") then
		local shp = (part :: Part).Shape
		if shp == Enum.PartType.Ball or shp == Enum.PartType.Cylinder then
			return Vector3.new(0, 0, -1)
		end
	end
	return LOCAL_FACE_UP[face]
end

-- Determines whether a given face of a part is a CURVED surface (round barrel, sphere,
-- cone slope, dome) as opposed to a genuinely flat face (box face, prism side, cylinder/
-- cone flat cap, hemisphere flat face). A flat Texture cannot follow curvature, so painting
-- a curved face produces stretch/seam/abrupt-edge artifacts; applyDecalOnFace restricts those.
-- Driven entirely by the shape tables above, in the part's local frame.
local FLAT_ALIGN_DOT = 0.95
local function faceIsCurved(part: BasePart, normalId: Enum.NormalId): boolean
	local shape = shapeOf(part)
	local kind = shape and SHAPE_CURVATURE[shape]
	if kind == nil then
		return false
	end
	if kind == "all" then
		return true
	end
	local axis = shape and SHAPE_LOCAL_AXIS[shape]
	if axis == nil then
		return true
	end
	local nLocal = LOCAL_FACE_NORMAL[normalId]
	if kind == "axial" then
		-- end caps (local normal parallel to the long axis) are flat; the barrel is curved
		return math.abs(nLocal:Dot(axis)) < FLAT_ALIGN_DOT
	elseif kind == "hemiflat" then
		-- only the single flat face (local normal = -long axis) is flat
		return nLocal:Dot(-axis) < FLAT_ALIGN_DOT
	end
	return true
end

-- Texture.Rotation (degrees) so a decal's "up" (+V) on the chosen face points along
-- upDirWorld, projected into that face and then SNAPPED to the nearest 90 deg. The snap is
-- deliberate: upDirWorld is treated like a world faceDir, mapped into face space and quantized to
-- the FACE EDGE closest to it, so the image always stays axis-aligned to the face (never a
-- diagonal tilt) and upDirWorld merely picks WHICH of the four edges is "up" -- exactly the way a
-- world faceDir picks one of the six discrete faces. This rights an oriented image (logo, smiley,
-- eyes) on ANY surface: the default upDir of +Y keeps art upright in the world (a smiley reads
-- right-side-up on a cylinder whether it lies along X or stands along Y). On a face nearly
-- perpendicular to upDir (a pole/cap where the projection vanishes) it falls back to the +Z front
-- meridian, then +X, so the angle is always defined. Uses faceDecalUp so native Ball/Cylinder
-- bottom caps are handled. Same signed-angle form as aroundWrapRotation, including the same NEGATE
-- (Roblox winds Texture.Rotation opposite the right-handed angle). For an axis-aligned part the raw
-- angle is already a multiple of 90, so the snap is a no-op; it only matters when the part and/or
-- upDirWorld sit at an odd angle.
local function faceTextureRotation(part: BasePart, normalId: Enum.NormalId, upDirWorld: Vector3): number
	local cf = part.CFrame
	local n = cf:VectorToWorldSpace(LOCAL_FACE_NORMAL[normalId])
	local up0 = cf:VectorToWorldSpace(faceDecalUp(part, normalId))

	local function projectRef(ref: Vector3): Vector3?
		local t = ref - ref:Dot(n) * n
		if t.Magnitude < 1e-3 then
			return nil
		end
		return t.Unit
	end
	local t = projectRef(upDirWorld) or projectRef(Vector3.new(0, 0, 1)) or projectRef(Vector3.new(1, 0, 0))
	if t == nil then
		return 0
	end

	local s = up0:Cross(t):Dot(n)
	local c = up0:Dot(t)
	-- NEGATE: the signed angle above is measured about the outward normal (right-handed), but
	-- Roblox's Texture.Rotation winds the IMAGE the opposite way -- the same correction
	-- aroundWrapRotation applies. It is a no-op on the 0/180 faces (so flat box/panel art is
	-- unaffected) but flips 90 <-> 270, which is exactly the upside-down case on a decal whose
	-- face frame is rolled (e.g. a default-up emblem on a vertically-built cylinder/taperedCylinder).
	local deg = -math.deg(math.atan2(s, c))
	-- Snap to the nearest 90 deg (face edge): quantize the world up into face space.
	deg = math.floor(deg / 90 + 0.5) * 90
	return (deg % 360 + 360) % 360
end

-- Signed angle (degrees) to rotate a Texture on a PERIMETER face of a barrel so its +V axis
-- points AROUND the curve (along the circumferential tangent = axisUnit x outwardNormal). This
-- makes a wrapped pattern flow continuously around the body. The result is SNAPPED to the nearest
-- 90 deg so the wrap always aligns with the face's own up/left/right/down edges (never a diagonal
-- tilt) -- like textureUpDir, the wrapDir is quantized into face space. For a part whose curve axis
-- is one of its local axes (every GP barrel/capsule) the raw angle is already exactly 0 or 180,
-- matching the hand-derived recipe (e.g. a local-X capsule: Front 0, Top 0, Back 180, Bottom 180),
-- so the snap is a no-op there; it only matters when the axis sits at an odd angle to the part.
-- Uses faceDecalUp so a native Ball/Cylinder bottom cap is handled, and the live CFrame so it is
-- correct for ANY world orientation.
local function aroundWrapRotation(part: BasePart, normalId: Enum.NormalId, axisUnit: Vector3): number
	local cf = part.CFrame
	local n = cf:VectorToWorldSpace(LOCAL_FACE_NORMAL[normalId])
	local up0 = cf:VectorToWorldSpace(faceDecalUp(part, normalId))
	local t = axisUnit:Cross(n)
	if t.Magnitude < 1e-4 then
		return 0
	end
	t = t.Unit
	local s = up0:Cross(t):Dot(n)
	local c = up0:Dot(t)
	-- NEGATE: the signed angle above is measured about the outward normal (right-handed), but
	-- Roblox's Texture.Rotation winds the IMAGE the opposite way. This is invisible on the 0/180
	-- faces (negation is a no-op there) but flips 90 <-> 270, which is exactly the case that was
	-- wrong before -- e.g. a cube's Top/Bottom under a perpendicular wrap, where the bands must run
	-- the SAME way around as the un-rotated side faces to stay continuous at the shared edges.
	local deg = -math.deg(math.atan2(s, c))
	-- Snap to the nearest 90 deg (face edge): quantize the wrap direction into face space.
	deg = math.floor(deg / 90 + 0.5) * 90
	return (deg % 360 + 360) % 360
end

-- Resolve the WORLD-space axis to wrap a pattern around, in priority order:
--   1. an explicit wrapAxis (any nonzero world Vector3 the author passes), else
--   2. the shape's known long axis (local, from SHAPE_LOCAL_AXIS) taken to world, else
--   3. a best-effort estimate from the longest local bounding-box dimension, but only when the
--      part is CLEARLY elongated (tube, generic CSG union); ambiguous for near-cubic parts.
-- Returns nil when nothing is meaningful (a box/sphere/near-cube with no shape axis), so the
-- caller can fall back to a single-face decal or the square all-faces wrap.
local function resolveWrapAxisWorld(part: BasePart, wrapAxis: Vector3?): Vector3?
	if typeof(wrapAxis) == "Vector3" and (wrapAxis :: Vector3).Magnitude > 1e-6 then
		return (wrapAxis :: Vector3).Unit
	end
	local shape = shapeOf(part)
	local localAxis = shape and SHAPE_LOCAL_AXIS[shape]
	if localAxis ~= nil then
		return part.CFrame:VectorToWorldSpace(localAxis).Unit
	end
	local sz = part.Size
	local m = math.max(sz.X, sz.Y, sz.Z)
	local others = (sz.X + sz.Y + sz.Z - m) / 2
	if m > others * 1.15 then
		local axisLocal: Vector3
		if m == sz.X then
			axisLocal = Vector3.new(1, 0, 0)
		elseif m == sz.Y then
			axisLocal = Vector3.new(0, 1, 0)
		else
			axisLocal = Vector3.new(0, 0, 1)
		end
		return part.CFrame:VectorToWorldSpace(axisLocal).Unit
	end
	return nil
end

-- Paint a repeating image SEAMLESSLY AROUND THE PERIMETER of an elongated body, treating the four
-- faces around `axis` as one loop. ONE ring pitch is used for the WHOLE part so every face shows the
-- SAME stripe/motif width: it is derived from the length ALONG the wrap axis, snapped to a whole
-- number of repeats over that length, so the rings fit edge-to-edge along the axis (and therefore
-- line up face-to-face). Every face uses that pitch on BOTH axes (square cells, so Roblox's
-- Rotation -- which spins the image but leaves StudsPerTileU/V pinned to the face axes -- never
-- changes the width); perimeter faces are then rotated so the bands run around the axis. When
-- skipCaps is false the caps are tiled at the same pitch (a flat Texture can't make them concentric,
-- but the width matches the body); when true the caps are left bare for separate texturing. This is
-- the engine of DP.wrapDecalAround.
local function applyAroundWrap(part: BasePart, contentId: string, color: Color3?, studsAlong: number?, transparency: number?, axis: Vector3, skipCaps: boolean?)
	-- PartOperation/CSG grids are face-CENTER anchored; base Parts are face-CORNER anchored. See
	-- applyAllOverWrap for the offset reasoning (odd repeat count -> phase by half a tile).
	local centerAnchored = not part:IsA("Part")
	local PERP_DOT = 0.95 -- |faceNormal . axis|: above this the face is an end cap

	-- Single pitch for the whole part: length along the axis, snapped to a whole number of rings.
	local localAxis = part.CFrame:VectorToObjectSpace(axis)
	local sz = part.Size
	local ax, ay, az = math.abs(localAxis.X), math.abs(localAxis.Y), math.abs(localAxis.Z)
	local lengthDim
	if ax >= ay and ax >= az then
		lengthDim = sz.X
	elseif ay >= az then
		lengthDim = sz.Y
	else
		lengthDim = sz.Z
	end
	local pitch
	if studsAlong ~= nil and studsAlong > 0 then
		pitch = lengthDim / math.max(1, math.floor(lengthDim / studsAlong + 0.5))
	else
		pitch = math.max(lengthDim, 0.05) -- no spacing requested: one ring spans the length
	end

	for _, face in ALL_FACES do
		local nWorld = part.CFrame:VectorToWorldSpace(LOCAL_FACE_NORMAL[face])
		local isCap = math.abs(nWorld:Dot(axis)) >= PERP_DOT
		-- skipCaps: caller is handling the end caps with a separate texture, so leave them bare.
		if isCap and skipCaps then
			continue
		end
		local fu, fv = faceStudSize(part, face)

		local texture = Instance.new("Texture")
		texture.Name = part.Name .. "_WrapAround_" .. face.Name
		texture.Face = face
		assignDecalContent(texture, contentId)
		if color ~= nil then
			texture.Color3 = color
		end
		if transparency ~= nil then
			texture.Transparency = math.clamp(transparency, 0, 1)
		end

		texture.StudsPerTileU = pitch
		texture.StudsPerTileV = pitch
		if centerAnchored then
			-- Phase a CSG center-anchored grid by half a tile when a face spans an odd count, so a
			-- band sits centred rather than straddling the center line.
			local nU = math.max(1, math.floor(fu / pitch + 0.5))
			local nV = math.max(1, math.floor(fv / pitch + 0.5))
			texture.OffsetStudsU = (nU % 2 == 1) and (pitch / 2) or 0
			texture.OffsetStudsV = (nV % 2 == 1) and (pitch / 2) or 0
		end

		-- Perimeter faces rotate so the bands run AROUND the axis; caps keep the flat projection.
		if not isCap then
			local rot = aroundWrapRotation(part, face, axis)
			if rot ~= 0 then
				(texture :: any).Rotation = rot
			end
		end

		texture.Parent = part
	end
end

-- Paint a repeating image ALL OVER the part: the SAME tile on all six faces with edge-aligned,
-- near-square tiling, so a curved/boxy body is fully covered (spots, scales, camo, textile). Each
-- face axis snaps the target tile to a whole number of repeats so a tile boundary lands on every
-- edge (no motif sliced at a seam). This is the engine of DP.wrapDecal.
local function applyAllOverWrap(part: BasePart, contentId: string, color: Color3?, studsPerTile: number?, transparency: number?)
	local sz = part.Size
	local minDim = math.min(sz.X, sz.Y, sz.Z)
	local target: number = studsPerTile or 0
	if target <= 0 then
		target = math.max(minDim / 3, 0.05)
	end

	local function fitAxis(L: number): (number, number)
		if L <= 0 then
			return target, 1
		end
		local n = math.max(1, math.floor(L / target + 0.5))
		return L / n, n
	end

	-- base Part grids anchor at the face CORNER (offset 0); PartOperation/CSG grids anchor at the
	-- face CENTER, so an ODD repeat count needs a half-tile phase to land a boundary on each edge.
	local centerAnchored = not part:IsA("Part")

	for _, face in ALL_FACES do
		local fu, fv = faceStudSize(part, face)
		local sptU, nU = fitAxis(fu)
		local sptV, nV = fitAxis(fv)

		local texture = Instance.new("Texture")
		texture.Name = part.Name .. "_AllOver_" .. face.Name
		texture.Face = face
		assignDecalContent(texture, contentId)
		if color ~= nil then
			texture.Color3 = color
		end
		if transparency ~= nil then
			texture.Transparency = math.clamp(transparency, 0, 1)
		end
		texture.StudsPerTileU = sptU
		texture.StudsPerTileV = sptV
		if centerAnchored then
			texture.OffsetStudsU = (nU % 2 == 1) and (sptU / 2) or 0
			texture.OffsetStudsV = (nV % 2 == 1) and (sptV / 2) or 0
		end
		texture.Parent = part
	end
end

-- Apply a single planar decal to one already-resolved face. The engine of DP.applyDecalOnFace.
-- On a FLAT face repeating tiles are seamless, so the requested tile size is honored (default = one
-- tile spanning the face) and the art sits SQUARE (no rotation), keeping ordinary panel/sign art
-- unaffected. On a CURVED face (sphere, round barrel, cone slope, dome) a flat image is planar-
-- projected and cannot wrap, so it is restricted to a SINGLE non-repeating decal (tile clamped to at
-- least the full face span) and AUTO-RIGHTED to world up (+Y) so a logo/face/eyes read upright no
-- matter how the part is turned. Keep curved art centered with transparent margins so it never seams
-- at the silhouette.
local function applyFaceDecal(part: BasePart, normalId: Enum.NormalId, contentId: string, color: Color3?, studsPerTileU: number?, studsPerTileV: number?, transparency: number?): Instance
	local curved = faceIsCurved(part, normalId)

	local texture = Instance.new("Texture")
	texture.Name = part.Name .. "_Texture"
	texture.Face = normalId
	assignDecalContent(texture, contentId)
	if color ~= nil then
		texture.Color3 = color
	end
	if transparency ~= nil then
		texture.Transparency = math.clamp(transparency, 0, 1)
	end

	local defaultU, defaultV = faceStudSize(part, normalId)
	if curved then
		if (studsPerTileU ~= nil and studsPerTileU < defaultU) or (studsPerTileV ~= nil and studsPerTileV < defaultV) then
			warn(string.format(
				"applyDecalOnFace: '%s' (face %s) is a curved surface; repeating tiles would seam where they wrap, "
					.. "so a single non-repeating decal is used. Keep the art centered with transparent margins.",
				part.Name, tostring(normalId)
			))
		end
		texture.StudsPerTileU = math.max(studsPerTileU or defaultU, defaultU)
		texture.StudsPerTileV = math.max(studsPerTileV or defaultV, defaultV)
	else
		texture.StudsPerTileU = math.max(studsPerTileU or defaultU, 0.001)
		texture.StudsPerTileV = math.max(studsPerTileV or defaultV, 0.001)
	end

	-- base Part grids anchor at the face CORNER (offset 0 fills it exactly); PartOperation/CSG grids
	-- anchor at the face CENTER, so phase a face-spanning tile by half a tile to re-center the art.
	local centerAnchored = not part:IsA("Part")
	if centerAnchored then
		texture.OffsetStudsU = texture.StudsPerTileU / 2
		texture.OffsetStudsV = texture.StudsPerTileV / 2
	end

	if curved then
		local rot = faceTextureRotation(part, normalId, Vector3.new(0, 1, 0))
		if rot ~= 0 then
			(texture :: any).Rotation = rot
		end
	end

	texture.Parent = part
	return texture
end

DecalPrimitives.dslModule:addFunction("decal", {
	description = [==[
	Declares a custom image to paint on a surface, specified inline as an SVG
	vector-graphics document, and returns a texture id to pass to DP.applyDecalOnFace /
	DP.wrapDecal / DP.wrapDecalAround.

	Use this whenever a surface needs arbitrary imagery that a solid Color3 +
	Material cannot express: signs, labels, text, faces/eyes, flags, emblems,
	playing-card pips, dartboards, packaging art, decals, repeating patterns, etc.
	You do NOT supply a Roblox asset id — the SVG is rasterized and published to an
	image asset automatically during generation, and this call is replaced with the
	resulting "rbxassetid://..." string.

	Provide a complete, self-contained SVG document inside a Lua long-bracket
	string ([[ ... ]]):

	    local label = DP.decal([[
	        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
	          <rect width="100" height="100" fill="#c0392b"/>
	          <circle cx="50" cy="50" r="34" fill="#ffffff"/>
	        </svg>
	    ]])
	    -- Target the surface by the WORLD direction it faces (front = toward camera, -Z):
	    DP.applyDecalOnFace(part, Vector3.new(0, 0, -1), label)

	Guidelines:
	- Always set a viewBox; match the aspect ratio to the face you are texturing.
	- Use flat shapes, paths, gradients, and <text>; do NOT reference external
	  files or embed raster images.
	- Make the background opaque to cover the whole face, or leave regions
	  transparent to let the part's own Color3 show through.
	- Author artwork in its normal, readable orientation — do NOT pre-mirror or
	  reverse it; the texture is applied as-drawn.
	- For an all-over pattern (spots/stripes/scales) keep the motif centered with a
	  transparent margin (or make a seamless tile) and apply it with DP.wrapDecal (all-over) or
	  DP.wrapDecalAround (rings). For stripes/bands, author vertical bands in a <pattern> that
	  are straight (vertical) at the tile's top/bottom edges so they stay seamless across a round
	  body's projection seams; add only a gentle mid-height bulge for an organic look (see
	  DP.wrapDecalAround for a worked zebra example).
	- Define each distinct image once (reuse the returned value) instead of
	  repeating identical SVG.

	SEAMLESS TILING (wrapU / wrapV): pass wrapU=true and/or wrapV=true to force the
	finished texture to tile perfectly on that axis. The rasterized image is MIRRORED
	across the chosen edge (a reflected copy is appended) so opposite edges become
	pixel-identical and the repeat seam disappears — no matter how the SVG's own edges
	were drawn. Use this as a safety net for stripes/patterns whose top and bottom (or
	left and right) edges may not line up:
	    -- mirror top<->bottom so vertical stripes wrap continuously at the seam:
	    local stripes = DP.decal([[ <svg> ...vertical bands... </svg> ]], false, true)
	    DP.wrapDecalAround(body, stripes, nil, 1.2)
	Note the result becomes mirror-symmetric on the wrapped axis (usually fine for
	stripes/spots/organic patterns); wrap only the axis that needs it (e.g. wrapU for
	vertical bands around a body), and do NOT wrap an axis carrying readable text or a
	directional logo, which would appear reflected.
	]==],
	parameters = {
		{ name = "svg", type = "string", description = "A complete SVG document inside a [[ ]] long string." },
		{ name = "wrapU", type = "boolean", description = "Optional. When true, mirror the image left<->right so its vertical (U) edges tile seamlessly. Default false." },
		{ name = "wrapV", type = "boolean", description = "Optional. When true, mirror the image top<->bottom so its horizontal (V) edges tile seamlessly. Default false." },
	},
	returnType = "string",
})
function DecalPrimitives.decal(svg: string, wrapU: boolean?, wrapV: boolean?): string
	if type(svg) ~= "string" or #svg == 0 then
		error("texture: 'svg' must be a non-empty SVG document string")
	end
	-- At generation time this call is replaced out-of-band with the published
	-- rbxassetid:// of the rasterized SVG. If it survives to runtime (no
	-- substitution happened), return the string unchanged so addTexture degrades
	-- gracefully instead of erroring.
	return svg
end

DecalPrimitives.dslModule:addFunction("applyDecalOnFace", {
	description = [=[
	Put a single image/decal on ONE face of a part (or CSG result) — signs, labels, a face/eyes, an
	emblem, a TV screen, a book cover, a logo. The image is a Roblox asset id (numeric or
	"rbxassetid://..."), usually a DP.decal(...) result.

	Pick the face by the WORLD direction it points (a Vector3): the decal lands on whichever face
	actually faces that way in the finished model, robust to however a primitive/CSG oriented its
	local axes. Convention: model faces the camera at -Z, viewer-left is +X, up is +Y. (An
	Enum.NormalId also works; a thin sliver face auto-redirects to the broad face.)

	    DP.applyDecalOnFace(panel, Vector3.new(0, 0, -1), art)   -- front, camera-facing
	    DP.applyDecalOnFace(tabletop, Vector3.new(0, 1, 0), art) -- top surface

	FLAT faces allow repeating tiles and edge-to-edge art. A CURVED face (sphere, barrel, cone slope,
	dome) is restricted to a SINGLE non-repeating decal and auto-righted to world up — make the SVG a
	centered emblem with TRANSPARENT margins so it never seams at the silhouette. Texture the visible
	outer surface; do NOT decal a part that is recessed behind or hidden by other geometry.

	Apply textures AFTER any CSG operation (CSG consumes its input parts and any textures on them).
	]=],
	parameters = {
		{ name = "part", type = "Instance", description = "The part (BasePart or CSG result) to texture." },
		{ name = "face", type = "Enum.NormalId | Vector3", description = "WORLD-space direction (preferred) or Enum.NormalId of the face to texture. Convention: camera at -Z, viewer-left +X, up +Y." },
		{ name = "textureId", type = "string", description = "Image asset id, e.g. \"rbxassetid://123\" or a numeric id." },
		{ name = "color", type = "Color3", description = "Optional RGB tint multiplied with the image. Default is white (no tint)." },
		{ name = "studsPerTileU", type = "number", description = "Optional horizontal tile size in studs (default = face width). On a curved face it is clamped to a single non-repeating decal." },
		{ name = "studsPerTileV", type = "number", description = "Optional vertical tile size in studs (default = face height). On a curved face it is clamped to a single non-repeating decal." },
		{ name = "transparency", type = "number", description = "Optional texture transparency, 0 (opaque) to 1 (invisible). Default 0." },
	},
	returnType = "Instance",
})

DecalPrimitives.dslModule:addFunction("wrapDecal", {
	description = [=[
	Tile the SAME image ALL OVER a part (every face) so a whole curved or boxy body is covered —
	spots, scales, camo, textile, polka dots, a repeating motif. The image is a Roblox asset id
	(numeric or "rbxassetid://..."), usually a DP.decal(...) result.

	    local spots = DP.decal([[ <svg> ...a dot with a transparent margin... </svg> ]])
	    DP.wrapDecal(body, spots, nil, 0.6)   -- 0.6-stud square tiles on every face

	The image MUST be a genuinely TILEABLE motif whose opposite edges match. Roblox tiles the WHOLE
	SVG CANVAS (viewBox + background <rect>), NOT the inner <pattern>, so the canvas must equal the
	pattern WxH (or an exact integer multiple). Keep a motif fully inside the tile with a transparent
	margin, or use DP.decal(svg, wrapU, wrapV) to force seamless tiling by mirroring an edge.

	For continuous stripes/rings around an elongated body use DP.wrapDecalAround instead.
	Apply textures AFTER any CSG operation.
	]=],
	parameters = {
		{ name = "part", type = "Instance", description = "The part (BasePart or CSG result) to cover." },
		{ name = "textureId", type = "string", description = "Image asset id, e.g. \"rbxassetid://123\" or a numeric id." },
		{ name = "color", type = "Color3", description = "Optional RGB tint multiplied with the image. Default is white (no tint)." },
		{ name = "studsPerTile", type = "number", description = "Optional square tile size in studs used on every face. Default ~1/3 of the smallest dimension; smaller = denser." },
		{ name = "transparency", type = "number", description = "Optional texture transparency, 0 (opaque) to 1 (invisible). Default 0." },
	},
	returnType = "Instance",
})

DecalPrimitives.dslModule:addFunction("wrapDecalAround", {
	description = [=[
	Wrap an image as CONTINUOUS RINGS/BANDS AROUND an elongated body's long axis — tiger/zebra/snake
	stripes, barber poles, barrel hoops. The four faces around the axis are treated as ONE loop (each
	shows one tile across the cross-section, rotated so the bands flow the same way around) and the
	image repeats along the length (spacing = studsAlong). The image is a Roblox asset id, usually a
	DP.decal(...) result.

	    -- continuous stripes around a torso capsule that lies along X:
	    DP.wrapDecalAround(torso, stripes, nil, 1.0)

	The axis defaults to the shape's known long axis; pass `axis` (a world Vector3) for a generic
	union or to override. By default the end caps are tiled too; pass coverCaps=false to leave them
	bare for a separate DP.applyDecalOnFace. For seamless rings the image must be SEAMLESS TOP-TO-
	BOTTOM: vertical bands the full tile height that start and end at the same x with VERTICAL end
	tangents (e.g. "M 25,0 C 25,14 42,26 38,38 S 28,62 32,70 S 25,88 25,100"); avoid big sine waves.

	Apply textures AFTER any CSG operation.
	]=],
	parameters = {
		{ name = "part", type = "Instance", description = "The elongated part (BasePart or CSG result) to wrap." },
		{ name = "textureId", type = "string", description = "Image asset id, e.g. \"rbxassetid://123\" or a numeric id." },
		{ name = "color", type = "Color3", description = "Optional RGB tint multiplied with the image. Default is white (no tint)." },
		{ name = "studsAlong", type = "number", description = "Optional ring/band spacing ALONG THE LENGTH in studs (snapped to a whole number of rings). Default: one ring spans the length." },
		{ name = "transparency", type = "number", description = "Optional texture transparency, 0 (opaque) to 1 (invisible). Default 0." },
		{ name = "axis", type = "Vector3", description = "Optional WORLD direction of the long axis to wrap around. Defaults to the shape's known long axis (or the longest bounding-box dimension for an elongated union)." },
		{ name = "coverCaps", type = "boolean", description = "Optional. When true (default) the end caps are tiled too; pass false to leave the caps bare for a separate face texture." },
	},
	returnType = "Instance",
})
function DecalPrimitives.applyDecalOnFace(part: BasePart, face: Enum.NormalId | Vector3 | nil, textureId: string | number, color: Color3?, studsPerTileU: number?, studsPerTileV: number?, transparency: number?): Instance
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		error("applyDecalOnFace: 'part' must be a BasePart created by a GP/CSG function")
	end
	local contentId = normalizeContentId(textureId)

	-- Resolve which face to paint. 'face' may be:
	--   * a Vector3  -> a WORLD-SPACE direction; we texture the face that actually points that way
	--                   in the finished model (most reliable; immune to how a primitive oriented its
	--                   local axes). e.g. Vector3.new(0,0,-1) = the camera-facing front surface.
	--   * Enum.NormalId / string -> that explicit LOCAL face, except a thin-sliver face (the
	--                   paper-thin edge of a plate/quad/prism) is auto-redirected to the broad face.
	--   * nil -> the broad face (a sensible default, though the prompt always passes a direction).
	local normalId: Enum.NormalId
	if typeof(face) == "Vector3" then
		normalId = faceForWorldDirection(part, face :: Vector3)
	elseif face == nil then
		normalId = largestFace(part)
	else
		normalId = resolveNormalId(face)
		local broad = largestFace(part)
		local broadArea = faceArea(part, broad)
		if broadArea > 0 and faceArea(part, normalId) < 0.5 * broadArea then
			normalId = broad
		end
	end

	return applyFaceDecal(part, normalId, contentId, color, studsPerTileU, studsPerTileV, transparency)
end

function DecalPrimitives.wrapDecal(part: BasePart, textureId: string | number, color: Color3?, studsPerTile: number?, transparency: number?): Instance
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		error("wrapDecal: 'part' must be a BasePart created by a GP/CSG function")
	end
	local contentId = normalizeContentId(textureId)
	applyAllOverWrap(part, contentId, color, studsPerTile, transparency)
	return part
end

function DecalPrimitives.wrapDecalAround(part: BasePart, textureId: string | number, color: Color3?, studsAlong: number?, transparency: number?, axis: Vector3?, coverCaps: boolean?): Instance
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		error("wrapDecalAround: 'part' must be a BasePart created by a GP/CSG function")
	end
	local contentId = normalizeContentId(textureId)
	local resolved = resolveWrapAxisWorld(part, axis)
	if resolved == nil then
		-- No usable long axis (a box/sphere/near-cube with no shape axis and no explicit one):
		-- fall back to all-over tiling so the pattern still appears instead of silently doing nothing.
		warn(string.format(
			"wrapDecalAround: '%s' has no clear long axis; falling back to all-over tiling. "
				.. "Pass an explicit 'axis' if you intended concentric rings.",
			part.Name
		))
		applyAllOverWrap(part, contentId, color, studsAlong, transparency)
		return part
	end
	-- coverCaps defaults to true (caps tiled too); pass false to leave the caps bare so they can be
	-- textured separately with DP.applyDecalOnFace.
	local skipCaps = coverCaps == false
	applyAroundWrap(part, contentId, color, studsAlong, transparency, resolved, skipCaps)
	return part
end
DP = DecalPrimitives

-- @sg:end decal-runtime

SG.scene("Mori Corner Mixed Use")
-- Plot: centre (0,0,-70), 70x60; city ground connects every entrance to the street.
-- Street: (-35,0,-47) to (35,0,-47), width 12; sidewalk at z=-58.
-- Building: centre (0,0,-80), 42x30; store below three apartment levels at y=11,21,31.
-- Store: entrance (0,0,-65), glass frontage, stocked aisles and checkout inside.
-- Apartments: balconies face +Z; rear rooms connect to eastern exterior stair landings.
-- Stair: x=24 and 30, z=-88 to -78; switchback flights connect ground to roof y=41.
-- Roof: 42x30 at y=41, perimeter rails, utility tank, solar panels and antenna to y=50.
-- Forecourt: x=-21 to 21, z=-64 to -54; vending alcove west, street sign east.
-- Decal: store fascia, name sign, "MORI MART / OPEN ALL DAY", one entrance.
-- Decal: corner panel, vertical neon sign, "CITY / LIVING", one west corner.
-- Decal: vending machine, product artwork and price card, "COOL DRINKS / 150", west machine.
-- Decal: storefront poster, promotion, "MIDNIGHT BITES / FRESH DAILY", one window.
-- Decal: street sign, wayfinding, "SAKURA LANE / STATION", east forecourt.

-- @sg:block id=setup/palette kind=palette
do
	SG.palette{
		"concrete",207,211,213, "white",240,242,232, "ink",29,42,54,
		"teal",20,157,150, "lime",182,220,70, "orange",244,140,52,
		"metal",100,111,119, "dark",48,59,67, "glass",162,216,225,
		"cream",255,238,195, "wood",189,149,103, "road",58,64,70,
		"curtain",216,205,189, "pink",252,125,180, "blue",55,132,208
	}
	for _, key in ipairs({"concrete","white"}) do SG.style(key,"Concrete") end
	for _, key in ipairs({"ink","metal","dark"}) do SG.style(key,"Metal") end
	SG.style("glass","Glass",0.65,false)
	SG.style("wood","Wood")
	SG.style("road","Asphalt")
	SG.style("curtain","Fabric")
	for _, key in ipairs({"teal","lime","orange","cream","pink","blue"}) do
		SG.style(key,"SmoothPlastic")
	end
	SG.lighting{time=18.2,brightness=2,ambient={105,112,132},outdoor={140,148,170}}
end
-- @sg:end

-- @sg:block id=landscape/city-ground kind=terrain
do
	workspace.Terrain:FillBlock(CFrame.new(0,-4,-70),Vector3.new(72,8,64),Enum.Material.Ground)
	for _=1,4 do task.wait() end
end
-- @sg:end

-- @sg:block id=routes/street-and-forecourt kind=element
do
	SG.element("routes/street-and-forecourt",function()
		local A=SG.attributes{SidewalkMaterial="Concrete",StreetWidth=12}
		SG.group("Two Way Neighborhood Street",nil,function()
			local streetTop=SG.road({-35,0,-47,35,0,-47},A.StreetWidth,"road",{shoulder=0,depth=3})
			local h=streetTop[2]
			for x=-30,30,12 do
				SG.box(6,0.04,0.18,SG.pos(x,h+0.15,-47),"cream")
			end
		end)
		SG.group("Storefront Pedestrian Forecourt",nil,function()
			SG.style("concrete",A.SidewalkMaterial)
			SG.road({-35,0,-59,35,0,-59},10,"concrete",{shoulder=0,depth=3})
			SG.road({0,0,-59,0,0,-64},14,"concrete",{shoulder=0,depth=3})
			SG.road({27,0,-59,27,0,-72},12,"concrete",{shoulder=0,depth=3})
		end)
	end)
end
-- @sg:end

-- @sg:block id=prototypes/stocked-shelf kind=prototype
do
	SG.define("StockedConvenienceShelf",function()
		local A=SG.attributes{ShelfCount=4,StockColor="orange"}
		local s=SG.size(Vector3.new(4,6,2))
		SG.boxes{
			0.18,s.Y,s.Z,-s.X/2,s.Y/2,0,"white",
			0.18,s.Y,s.Z,s.X/2,s.Y/2,0,"white",
			s.X,0.2,s.Z,0,0.1,0,"white"
		}
		for level=1,A.ShelfCount do
			local y=0.4+(level-1)*(s.Y-1)/A.ShelfCount
			SG.box(s.X,0.13,s.Z,SG.pos(0,y,0),"white")
			for col=1,5 do
				local x=-s.X/2+col*s.X/6
				SG.box(0.5,0.8,0.45,SG.pos(x,y+0.47,-0.55),A.StockColor)
				SG.box(0.4,0.16,0.46,SG.pos(x,y+0.75,-0.56),"cream")
				SG.box(0.5,0.75,0.45,SG.pos(x,y+0.44,0.55),"teal")
			end
			SG.box(s.X,0.18,0.06,SG.pos(0,y+0.1,-s.Z/2-0.03),"lime")
		end
	end)
end
-- @sg:end

-- @sg:block id=structures/mixed-use-building kind=element
do
	SG.element("structures/mixed-use-building",function()
		local A=SG.attributes{WallColor="white",BalconyColor="dark",Curtains=true}
		SG.seat("Mori Store and Apartments",0,-80,0,function()
			SG.group("Convenience Store Shell",nil,function()
				SG.box(42,0.5,30,SG.pos(0,0.25,0),"concrete")
				SG.boxes{
					42,10,0.6,0,5.5,-15,A.WallColor,
					0.6,10,30,-21,5.5,0,A.WallColor,
					0.6,10,30,21,5.5,0,A.WallColor,
					42,0.6,30,0,10.7,0,"white"
				}
				for _,x in ipairs({-20,-4.5,4.5,20}) do
					SG.box(0.4,8,0.4,SG.pos(x,4.5,15),"dark")
				end
				for _,x in ipairs({-12.2,12.2}) do
					SG.box(15,7.5,0.18,SG.pos(x,4.4,15),"glass")
					SG.box(15,0.35,0.5,SG.pos(x,0.7,15),"dark")
				end
				SG.box(42,1.5,0.65,SG.pos(0,9.4,15),"teal")
				SG.box(42,0.22,0.7,SG.pos(0,8.55,15),"lime")
				SG.box(42,0.22,0.7,SG.pos(0,10.25,15),"orange")
			end)
			SG.group("Open Sliding Double Entrance",nil,function()
				for _,x in ipairs({-5.4,5.4}) do
					SG.box(3.5,7.7,0.18,SG.pos(x,4.35,15.15),"glass")
					for _,dx in ipairs({-1.75,1.75}) do
						SG.box(0.12,7.7,0.25,SG.pos(x+dx,4.35,15.15),"metal")
					end
					SG.box(0.1,1.5,0.3,SG.pos(x,4,15.35),"metal")
				end
				SG.box(9,0.4,0.6,SG.pos(0,8.4,15),"dark")
				SG.box(8,0.06,0.2,SG.pos(0,0.56,15),"metal")
			end)
			SG.group("Illuminated Store Fascia",nil,function()
				SG.style("cream","Neon")
				local panel=SG.box(18,2.1,0.25,SG.cframe(0,9.55,15.5,0,180,0),"cream")
				local art=DP.decal("rbxassetid://105862367698424")
				DP.applyDecalOnFace(panel,panel.CFrame.LookVector,art)
				SG.light("surface",SG.cframe(0,9.5,15.8,0,180,0),"cream",12,1.4)
			end)
			SG.group("Bright Store Ceiling Lighting",nil,function()
				SG.style("cream","Neon")
				for _,x in ipairs({-12,0,12}) do
					SG.box(7,0.12,1,SG.pos(x,10.25,0),"cream")
					SG.light("point",SG.pos(x,9.7,0),"cream",18,1.2)
				end
			end)
			SG.group("Checkout Counter",SG.pos(12,0.5,10),function()
				SG.box(6,3,2.5,SG.pos(0,1.5,0),"teal")
				SG.box(6.3,0.2,2.8,SG.pos(0,3.1,0),"white")
				SG.box(1.4,0.2,1,SG.pos(0,3.3,0),"dark")
				SG.box(1.2,0.8,0.12,SG.cframe(0,3.8,0,0,180,0),"ink")
			end)
			SG.group("Rear Refrigerated Drinks Cases",nil,function()
				for _,x in ipairs({-13,-6,1,8}) do
					SG.group("Glass Refrigerator "..x,SG.pos(x,0.5,-12.8),function()
						SG.box(6,7.8,2.5,SG.pos(0,3.9,0),"dark")
						SG.box(5.5,7.1,0.12,SG.pos(0,3.9,1.3),"glass")
						for row=1,4 do
							SG.box(5.4,0.12,1.8,SG.pos(0,row*1.5,0.6),"white")
							for col=1,7 do
								SG.disc(0.22,0.8,SG.pos(-2.5+col*0.65,row*1.5+0.45,0.65),"blue")
							end
						end
						SG.box(0.1,1.4,0.2,SG.pos(2.4,4,1.4),"metal")
					end)
				end
			end)
			for floor=1,3 do
				local y=11+(floor-1)*10
				SG.group("Apartment Level "..floor,nil,function()
					SG.box(42,0.4,30,SG.pos(0,y+0.2,0),"concrete")
					SG.box(42,1.8,30,SG.pos(0,y+1.3,0),A.WallColor)
					SG.box(42,2.3,30,SG.pos(0,y+8.85,0),A.WallColor)
					for _,x in ipairs({-21,-7,7,21}) do
						SG.box(0.65,6.2,30,SG.pos(x,y+4.8,0),A.WallColor)
					end
					SG.box(42,6.2,0.4,SG.pos(0,y+4.8,-15),A.WallColor)
					for _,x in ipairs({-14,0,14}) do
						SG.group("Balcony Apartment "..x,nil,function()
							SG.box(11.6,5.6,0.18,SG.pos(x,y+4.7,15),"glass")
							if A.Curtains then
								for _,dx in ipairs({-4.1,4.1}) do
									SG.box(2.9,5.2,0.15,SG.pos(x+dx,y+4.6,14.5),"curtain")
									for p=-1,1 do
										SG.box(0.12,5.2,0.12,SG.pos(x+dx+p*0.65,y+4.6,14.65),"cream")
									end
								end
							end
							SG.box(0.2,5.6,0.25,SG.pos(x,y+4.7,15.2),"dark")
							SG.box(12.5,0.4,3.4,SG.pos(x,y+0.4,16.7),"concrete")
							for _,z in ipairs({15.2,18.3}) do
								SG.box(12.5,0.14,0.14,SG.pos(x,y+3.4,z),A.BalconyColor)
							end
							for p=0,10 do
								SG.box(0.1,2.9,0.1,SG.pos(x-6+p*1.2,y+1.9,18.3),A.BalconyColor)
							end
							for _,dx in ipairs({-6.1,6.1}) do
								SG.box(0.13,2.9,3.2,SG.pos(x+dx,y+1.9,16.7),A.BalconyColor)
							end
							SG.group("Balcony Air Conditioner",SG.pos(x+4.4,y+0.6,16.4),function()
								SG.box(2.2,1.6,1,SG.pos(0,0.8,0),"white")
								SG.disc(0.58,0.08,SG.cframe(0,0.8,0.55,90,0,0),"metal")
								for p=-2,2 do
									SG.box(1.1,0.07,0.08,SG.pos(0,0.8+p*0.2,0.64),"dark")
								end
							end)
						end)
					end
					SG.box(0.1,6.5,3.4,SG.pos(21.4,y+3.65,-10),"teal")
				end)
			end
			SG.group("Flat Roof and Safety Rail",nil,function()
				SG.box(42,0.5,30,SG.pos(0,41.25,0),"concrete")
				for _,z in ipairs({-14.8,14.8}) do
					SG.box(42,0.12,0.12,SG.pos(0,44,z),"dark")
					for x=-21,21,3 do SG.box(0.12,2.5,0.12,SG.pos(x,42.75,z),"dark") end
				end
				for _,x in ipairs({-20.8,20.8}) do
					SG.box(0.12,0.12,30,SG.pos(x,44,0),"dark")
					for z=-15,15,3 do
						if x<0 or z>-6 then
							SG.box(0.12,2.5,0.12,SG.pos(x,42.75,z),"dark")
						end
					end
				end
			end)
			SG.group("Roof Water Tank",SG.pos(-12,41.5,-8),function()
				SG.box(6,0.5,6,SG.pos(0,0.25,0),"dark")
				SG.disc(2.3,4.8,SG.pos(0,2.9,0),"metal")
				SG.frustum(2.3,0.8,0.7,12,SG.pos(0,5.65,0),"metal")
			end)
			SG.group("Solar Array",nil,function()
				for x=0,12,6 do
					SG.box(5,0.3,7,SG.cframe(x,42.4,-5,-12,0,0),"blue")
					SG.box(0.2,1,6,SG.pos(x,42,-5),"metal")
				end
			end)
			SG.group("Roof Antenna",nil,function()
				SG.segment(17,41.5,-11,17,49,-11,0.15,"metal")
				for y=46,48,1 do SG.segment(15,y,-11,19,y,-11,0.1,"metal") end
			end)
			SG.group("Window Promotion Poster",nil,function()
				local panel=SG.box(3.2,4.8,0.05,SG.cframe(-14,4.2,15.2,0,180,0),"cream")
				local art=DP.decal("rbxassetid://94794852545308")
				DP.applyDecalOnFace(panel,panel.CFrame.LookVector,art)
			end)
		end,{pad=true,footprint={42,30}})
	end)
end
-- @sg:end

-- @sg:block id=systems/store-aisles kind=system
do
	SG.place("StockedConvenienceShelf","Snack Aisle",{
		-11,0.5,-80,0,0,0, -11,0.5,-74,0,0,0,
		-3,0.5,-80,0,0,0, -3,0.5,-74,0,0,0,
		5,0.5,-80,0,0,0
	})
end
-- @sg:end

-- @sg:block id=structures/exterior-stair kind=element
do
	SG.element("structures/exterior-stair",function()
		local A=SG.attributes{RailColor="dark",StepMaterial="Concrete"}
		SG.style("concrete",A.StepMaterial)
		SG.group("Eastern Switchback Staircase",nil,function()
			local base=SG.ground(27,-88) or 0
			for level=0,3 do
				local bottom=base
				local rise=11
				if level>0 then bottom=base+11+(level-1)*10 rise=10 end
				for flight=1,2 do
					local x=24
					if flight==2 then x=30 end
					local startY=bottom+(flight-1)*rise/2
					SG.group("Stair Flight "..level.."-"..flight,nil,function()
						for step=1,20 do
							local z=-88+(step-0.5)*0.5
							if flight==2 then z=-78-(step-0.5)*0.5 end
							local top=startY+step*rise/40
							SG.box(5,0.28,0.55,SG.pos(x,top-0.14,z),"concrete")
							if step%4==0 then
								for _,dx in ipairs({-2.4,2.4}) do
									SG.box(0.1,3,0.1,SG.pos(x+dx,top+1.5,z),A.RailColor)
								end
							end
						end
						local za=-88 local zb=-78
						if flight==2 then za=-78 zb=-88 end
						for _,dx in ipairs({-2.4,2.4}) do
							SG.segment(x+dx,startY+3,za,x+dx,startY+rise/2+3,zb,0.12,A.RailColor)
							SG.segment(x+dx,startY-0.35,za,x+dx,startY+rise/2-0.35,zb,0.25,"metal")
						end
					end)
				end
				SG.group("Stair Landings "..level,nil,function()
					SG.box(11,0.3,4,SG.pos(27,bottom+rise/2-0.15,-76),"concrete")
					SG.box(12,0.3,4,SG.pos(27,bottom+rise-0.15,-90),"concrete")
					SG.box(11,0.12,0.12,SG.pos(27,bottom+rise/2+3,-74),"dark")
					SG.box(12,0.12,0.12,SG.pos(27,bottom+rise+3,-92),"dark")
					for x=22,32,2 do
						SG.box(0.12,3,0.12,SG.pos(x,bottom+rise/2+1.5,-74),"dark")
						SG.box(0.12,3,0.12,SG.pos(x,bottom+rise+1.5,-92),"dark")
					end
				end)
			end
		end)
	end)
end
-- @sg:end

-- @sg:block id=props/vending-and-signage kind=element
do
	SG.element("props/vending-and-signage",function()
		local A=SG.attributes{MachineColor="white",NeonColor="pink"}
		local ground=SG.ground(-26,-61) or 0
		SG.seat("Outdoor Drinks Vending Machine",-26,-62,180,function()
			SG.box(4.4,7,3,SG.pos(0,3.5,0),A.MachineColor)
			SG.box(3.5,4.6,0.1,SG.pos(-0.2,4.4,-1.55),"glass")
			for row=1,3 do
				SG.box(3.3,0.15,0.8,SG.pos(-0.2,2.1+row*1.2,-1.1),"metal")
				for col=1,4 do
					SG.disc(0.23,0.75,SG.pos(-1.8+col*0.66,2.6+row*1.2,-1.25),"orange")
				end
			end
			SG.box(2.8,0.8,0.15,SG.pos(-0.2,0.9,-1.6),"ink")
			SG.box(0.3,0.8,0.1,SG.pos(1.9,3,-1.6),"dark")
			SG.style("cream","Neon")
			local panel=SG.box(4,1,0.15,SG.pos(0,6.4,-1.6),"cream")
			local art=DP.decal("rbxassetid://140140041243205")
			DP.applyDecalOnFace(panel,panel.CFrame.LookVector,art)
			SG.light("point",SG.pos(0,6,-1.8),"cream",8,0.7)
		end,{supports=workspace.Terrain})
		SG.seat("Station Direction Street Sign",19,-55,180,function()
			SG.box(0.25,9,0.25,SG.pos(0,4.5,0),"metal")
			local panel=SG.box(7,2.8,0.18,SG.pos(0,8,0),"teal")
			local art=DP.decal("rbxassetid://123436595105471")
			DP.applyDecalOnFace(panel,panel.CFrame.LookVector,art)
		end)
		SG.group("West Corner Neon Residential Panel",nil,function()
			SG.style(A.NeonColor,"Neon")
			local panel=SG.box(3,12,0.4,SG.cframe(-22,29+ground,-64.5,0,180,0),A.NeonColor)
			local art=DP.decal("rbxassetid://105341628904452")
			DP.applyDecalOnFace(panel,panel.CFrame.LookVector,art)
			SG.light("point",SG.pos(-22,29+ground,-63.8),A.NeonColor,10,1)
			SG.box(1.2,0.2,0.7,SG.pos(-21.5,34+ground,-64.5),"dark")
			SG.box(1.2,0.2,0.7,SG.pos(-21.5,24+ground,-64.5),"dark")
		end)
		SG.seat("Sidewalk Recycling Bins",-18,-58,180,function()
			for _,x in ipairs({-1.3,1.3}) do
				SG.box(2,3,2,SG.pos(x,1.5,0),"metal")
				SG.box(2.1,0.25,2.1,SG.pos(x,3.1,0),"teal")
				SG.box(1.3,0.5,0.05,SG.pos(x,2.65,-1.02),"ink")
			end
		end)
	end)
end
-- @sg:end
