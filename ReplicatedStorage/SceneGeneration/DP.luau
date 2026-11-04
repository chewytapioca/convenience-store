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
