-- Connected Discord-GitHub

--[[
	ProceduralIkWalker
	A six-legged walker that places its feet by raycasting the world and bends its
	knees with an analytic two-bone IK solve (law of cosines), then floats its body
	on the plane described by whichever feet are currently planted.

	Why this system runs on the client rather than the server:
	procedural animation is purely cosmetic. Solving six legs every frame on the
	server would replicate two CFrame writes per leg per observer and change no
	gameplay outcome, so each client builds and drives its own rig instead. The
	walker is therefore self-contained in this one LocalScript.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CONFIG = {
	LEG_COUNT = 6, -- keep even, legs build in mirrored pairs
	ROW_SPACING = 3.4, -- gap between leg rows on local Z
	HIP_INSET = 2.1, -- hip socket offset on local X
	FOOT_REACH = 7.0, -- wider than the hips so the legs splay out
	UPPER_LENGTH = 5.4, -- femur, one fixed side of the IK triangle
	LOWER_LENGTH = 7.0, -- tibia. Combined reach must clear the rest pose by more than
	-- the body travels between one leg's steps, or feet drag instead of stepping.
	LIMB_THICKNESS = 0.5,
	BODY_SIZE = Vector3.new(4.6, 1.5, 7.2),
	BODY_HEIGHT = 5.2, -- ride height above the planted feet
	STEP_THRESHOLD = 2.6, -- foot drift allowed before a step fires
	STRAIN_RATIO = 0.8, -- fraction of full reach at which a leg may steal a turn. Lower
	-- values make every leg claim to be strained, which just causes budget contention.
	STEP_DURATION = 0.13, -- two of these is one gait cycle, so it caps how far the body
	-- can travel before a given leg gets to reposition itself.
	STEP_HEIGHT = 1.7, -- peak of the sine arc
	RAY_ABOVE = 12, -- probe starts this far up to catch ledges
	RAY_BELOW = 512, -- long enough to still find ground after the player drops off a cliff
	MOVE_SPEED = 13,
	TURN_RATE = 6, -- exponential rate, not degrees per second
	BODY_SMOOTH = 9, -- same units, damps height and rotation
	FOLLOW_DISTANCE = 14,
	SPAWN_POSITION = Vector3.new(0, 6, -26),
}

local LIMB_COLOR = Color3.fromRGB(196, 202, 210)
local BODY_COLOR = Color3.fromRGB(58, 130, 148)

local function MakePart(name: string, size: Vector3, color: Color3, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size -- set once, limb lengths never change
	part.Color = color
	part.Material = Enum.Material.Metal
	part.Anchored = true -- CFrame driven, physics must not touch it
	part.CanCollide = false
	part.CanQuery = false -- keeps the rig out of its own ground raycasts
	part.CanTouch = false
	part.CastShadow = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent -- last, so it replicates fully built
	return part
end

-- Two-bone IK. Hip and foot are known, solve for the knee between them.
local function SolveKnee(hip: Vector3, foot: Vector3, upper: number, lower: number, poleHint: Vector3): Vector3
	local toFoot = foot - hip
	local reach = toFoot.Magnitude -- side c of the triangle
	local maxReach = upper + lower - 0.01 -- epsilon stops the limb locking dead straight
	local minReach = math.abs(upper - lower) + 0.01 -- below this the triangle inverts
	reach = math.clamp(reach, minReach, maxReach) -- keeps acos in domain
	local axis = toFoot.Unit

	local side = axis:Cross(poleHint) -- perpendicular to both, defines the bend plane
	if side.Magnitude < 1e-4 then -- pole hint parallel to the limb
		side = axis:Cross(Vector3.yAxis) -- world up always gives a usable perpendicular
	end
	local bendNormal = side.Unit:Cross(axis).Unit -- back into the plane, square to the axis
	if bendNormal:Dot(poleHint) < 0 then
		bendNormal = -bendNormal -- cross lands either side, force it toward the hint
	end

	local cosHip = (upper * upper + reach * reach - lower * lower) / (2 * upper * reach) -- law of cosines
	local hipAngle = math.acos(math.clamp(cosHip, -1, 1)) -- second clamp covers float drift
	return hip + (axis * math.cos(hipAngle) + bendNormal * math.sin(hipAngle)) * upper -- polar to cartesian in the bend plane
end

-- Framerate independent lerp alpha. Same settle time at 30fps and at 240.
local function SmoothAlpha(rate: number, deltaTime: number): number
	return 1 - math.exp(-rate * deltaTime)
end

local Leg = {}
Leg.__index = Leg -- shared method table, one copy for all six legs

-- Offsets are body space, so steering the chassis carries the targets with it.
function Leg.New(walker, hipOffset: Vector3, restOffset: Vector3, phaseGroup: number)
	local self = setmetatable({}, Leg)

	self.Walker = walker -- back reference, mainly for the shared RaycastParams
	self.HipOffset = hipOffset
	self.RestOffset = restOffset
	self.PhaseGroup = phaseGroup -- tripod index, 0 or 1

	self.Planted = Vector3.zero -- world foot position, resting or mid step
	self.StepFrom = Vector3.zero
	self.StepTo = Vector3.zero
	self.StepAlpha = 0
	self.Stepping = false

	self.Upper = MakePart("UpperSegment", Vector3.new(CONFIG.LIMB_THICKNESS, CONFIG.LIMB_THICKNESS, CONFIG.UPPER_LENGTH), LIMB_COLOR, walker.Model) -- sized on Z, lookAt aims down -Z
	self.Lower = MakePart("LowerSegment", Vector3.new(CONFIG.LIMB_THICKNESS, CONFIG.LIMB_THICKNESS, CONFIG.LOWER_LENGTH), LIMB_COLOR, walker.Model)
	self.Foot = MakePart("Foot", Vector3.new(0.8, 0.35, 0.8), BODY_COLOR, walker.Model)

	return self
end

function Leg:ProbeGround(bodyCFrame: CFrame): Vector3?
	local ideal = bodyCFrame * self.RestOffset -- body space to world in one multiply
	local origin = ideal + Vector3.new(0, CONFIG.RAY_ABOVE, 0)
	local result = Workspace:Raycast(origin, Vector3.new(0, -CONFIG.RAY_BELOW, 0), self.Walker.RayParams) -- reused params, nothing allocated per frame
	return result and result.Position -- nil on a miss, caller keeps the old foot
end

-- Returns true if a step actually started, so the caller can budget how many
-- legs are allowed off the ground at once.
function Leg:TryStep(bodyCFrame: CFrame, allowedGroup: number, mayStep: boolean): boolean
	if self.Stepping then -- already swinging, let the arc finish
		return false
	end
	if not mayStep then -- lift budget spent, half the legs are already up
		return false
	end
	local hip = bodyCFrame * self.HipOffset
	local maxReach = CONFIG.UPPER_LENGTH + CONFIG.LOWER_LENGTH - 0.05
	local target = self:ProbeGround(bodyCFrame)
	if not target then -- genuine void, nothing within the whole probe
		target = hip - Vector3.new(0, maxReach, 0) -- reach straight down so the body sinks instead of hovering
	end

	local offset = target - hip
	if offset.Magnitude > maxReach then -- ground past a ledge sits further than the limb stretches
		target = hip + offset.Unit * maxReach -- clamp onto the reach sphere or the shin visibly detaches
	end

	if (target - self.Planted).Magnitude < CONFIG.STEP_THRESHOLD then -- inside tolerance, stay put
		return false
	end

	local strained = (self.Planted - hip).Magnitude > maxReach * CONFIG.STRAIN_RATIO -- current foot is near the edge of what the limb can span
	if self.PhaseGroup ~= allowedGroup and not strained then -- normally wait your turn, but a stretched leg jumps the queue
		return false
	end

	self.StepFrom = self.Planted -- freeze both ends, a moving chassis must not warp the arc
	self.StepTo = target
	self.StepAlpha = 0
	self.Stepping = true
	return true
end

function Leg:Advance(deltaTime: number)
	if not self.Stepping then
		return
	end
	self.StepAlpha = math.min(self.StepAlpha + deltaTime / CONFIG.STEP_DURATION, 1) -- min lands exactly on 1
	local flat = self.StepFrom:Lerp(self.StepTo, self.StepAlpha)
	local lift = math.sin(self.StepAlpha * math.pi) * CONFIG.STEP_HEIGHT -- sin over 0..pi peaks mid step, back to zero at the end
	self.Planted = flat + Vector3.new(0, lift, 0) -- lift on world Y so slopes do not skew it
	if self.StepAlpha >= 1 then
		self.Stepping = false -- releases the gait lock
	end
end

function Leg:Render(bodyCFrame: CFrame)
	local hip = bodyCFrame * self.HipOffset
	local foot = self.Planted
	local offset = foot - hip
	local maxReach = CONFIG.UPPER_LENGTH + CONFIG.LOWER_LENGTH - 0.05
	if offset.Magnitude > maxReach then -- body outran this foot before its turn came round
		foot = hip + offset.Unit * maxReach -- drag it in rather than draw a detached limb
	end

	local outward = (hip - bodyCFrame.Position).Unit -- pushes the knee away from the body
	local poleHint = outward + bodyCFrame.UpVector * 0.55 -- blend in body up so knees stay raised on slopes
	local knee = SolveKnee(hip, foot, CONFIG.UPPER_LENGTH, CONFIG.LOWER_LENGTH, poleHint)

	self.Upper.CFrame = CFrame.lookAt(hip, knee) * CFrame.new(0, 0, -CONFIG.UPPER_LENGTH / 2) -- aim, then slide back to the segment midpoint
	self.Lower.CFrame = CFrame.lookAt(knee, foot) * CFrame.new(0, 0, -CONFIG.LOWER_LENGTH / 2)
	self.Foot.CFrame = CFrame.new(foot) -- bare Vector3 gives no rotation
end

local Walker = {}
Walker.__index = Walker

function Walker.New(spawnPosition: Vector3)
	local self = setmetatable({}, Walker)

	self.Model = Instance.new("Model") -- one Destroy call tears the whole rig down
	self.Model.Name = "ProceduralWalker"
	self.Model.Parent = Workspace

	self.Body = MakePart("Chassis", CONFIG.BODY_SIZE, BODY_COLOR, self.Model)
	self.Model.PrimaryPart = self.Body

	self.RayParams = RaycastParams.new() -- built once, six raycasts a frame reuse it
	self.RayParams.FilterType = Enum.RaycastFilterType.Exclude
	self.RayParams.FilterDescendantsInstances = {} -- filled in once the character exists
	self.RayParams.IgnoreWater = true

	self.BodyCFrame = CFrame.new(spawnPosition)
	self.Facing = Vector3.zAxis -- held while idle so the body does not snap back
	self.GaitGroup = 0
	self.Legs = {}

	self:BuildLegs(spawnPosition)
	return self
end

-- Generated from LEG_COUNT instead of six hardcoded offsets.
function Walker:BuildLegs(spawnPosition: Vector3)
	local rowCount = CONFIG.LEG_COUNT / 2
	for index = 1, CONFIG.LEG_COUNT do
		local side = (index % 2 == 0) and 1 or -1 -- parity alternates flanks
		local row = math.floor((index - 1) / 2) -- pairs 1-2, 3-4, 5-6 into front, middle, rear
		local z = CONFIG.ROW_SPACING * (row - (rowCount - 1) / 2) -- centres the rows on the body

		local hipOffset = Vector3.new(side * CONFIG.HIP_INSET, -0.2, z)
		local restOffset = Vector3.new(side * CONFIG.FOOT_REACH, -CONFIG.BODY_HEIGHT, z)
		local phaseGroup = (row + (side == 1 and 0 or 1)) % 2 -- offsetting by side gives the alternating tripod

		local leg = Leg.New(self, hipOffset, restOffset, phaseGroup)
		leg.Planted = spawnPosition + Vector3.new(side * CONFIG.FOOT_REACH, -CONFIG.BODY_HEIGHT, z) -- seed near rest, avoids a first frame snap
		table.insert(self.Legs, leg)
	end
end

-- Rebuilt on respawn, otherwise the filter holds a destroyed model.
function Walker:RefreshFilter(character: Model?)
	self.RayParams.FilterDescendantsInstances = character and { character } or {}
end

function Walker:Steer(targetPosition: Vector3?, deltaTime: number): Vector3
	local position = self.BodyCFrame.Position
	if not targetPosition then
		return position -- no character, hold station
	end

	local delta = targetPosition - position
	local flat = Vector3.new(delta.X, 0, delta.Z) -- drop Y or it tries to climb toward an airborne player
	local distance = flat.Magnitude
	if distance <= CONFIG.FOLLOW_DISTANCE then
		return position -- inside the standoff radius, stop
	end

	local direction = flat.Unit
	local blended = self.Facing:Lerp(direction, SmoothAlpha(CONFIG.TURN_RATE, deltaTime)) -- ease the heading instead of snapping it
	self.Facing = if blended.Magnitude > 1e-4 then blended.Unit else direction -- opposed vectors can lerp to zero
	local travel = math.min(CONFIG.MOVE_SPEED * deltaTime, distance - CONFIG.FOLLOW_DISTANCE) -- min stops it overshooting the radius
	return position + direction * travel
end

-- Feet describe a plane. Average height sets ride height, the spread sets tilt.
function Walker:SolveBodyPlane(): (Vector3, Vector3)
	local sum = Vector3.zero
	local front, back, left, right = Vector3.zero, Vector3.zero, Vector3.zero, Vector3.zero
	local frontCount, backCount, leftCount, rightCount = 0, 0, 0, 0

	for _, leg in ipairs(self.Legs) do -- ipairs, Legs is a dense array
		sum += leg.Planted
		if leg.RestOffset.Z > 0.1 then -- front row
			front += leg.Planted
			frontCount += 1
		elseif leg.RestOffset.Z < -0.1 then -- rear row, middle row deliberately skipped
			back += leg.Planted
			backCount += 1
		end
		if leg.RestOffset.X > 0 then
			right += leg.Planted
			rightCount += 1
		else
			left += leg.Planted
			leftCount += 1
		end
	end

	local centre = sum / #self.Legs
	local up = Vector3.yAxis -- fallback when a row is missing
	if frontCount > 0 and backCount > 0 and leftCount > 0 and rightCount > 0 then
		local forwardSpan = (front / frontCount) - (back / backCount)
		local rightSpan = (right / rightCount) - (left / leftCount)
		local normal = rightSpan:Cross(forwardSpan) -- two in-plane vectors give the normal
		if normal.Magnitude > 1e-4 then -- guards collinear feet
			up = normal.Unit
			if up.Y < 0 then
				up = -up -- handedness can invert, keep it upright
			end
		end
	end
	return centre, up
end

function Walker:Step(deltaTime: number, targetPosition: Vector3?)
	local airborne = 0
	local activeGroup = self.GaitGroup
	for _, leg in ipairs(self.Legs) do
		if leg.Stepping then
			airborne += 1
			activeGroup = leg.PhaseGroup -- whichever group is already swinging keeps the lock
		end
	end
	if airborne == 0 then
		self.GaitGroup = 1 - self.GaitGroup -- flip, which alternates the tripods
		activeGroup = self.GaitGroup
	end

	local liftBudget = math.floor(CONFIG.LEG_COUNT / 2) - airborne -- half the legs may be off the ground, never more

	for _, leg in ipairs(self.Legs) do
		if leg:TryStep(self.BodyCFrame, activeGroup, liftBudget > 0) then
			liftBudget -= 1 -- spend the allowance so a strained leg cannot empty the tripod
		end
		leg:Advance(deltaTime)
	end

	local centre, up = self:SolveBodyPlane()
	local steered = self:Steer(targetPosition, deltaTime)
	local smooth = SmoothAlpha(CONFIG.BODY_SMOOTH, deltaTime)
	local heightNow = self.BodyCFrame.Position.Y
	local heightTarget = centre.Y + CONFIG.BODY_HEIGHT
	local desired = Vector3.new(steered.X, heightNow + (heightTarget - heightNow) * smooth, steered.Z) -- XZ exact, Steer already rate limits it. Damping twice halved top speed.
	local targetRotation = CFrame.lookAt(desired, desired + self.Facing, up).Rotation -- .Rotation drops the translation
	self.BodyCFrame = CFrame.new(desired) * self.BodyCFrame.Rotation:Lerp(targetRotation, smooth)
	self.Body.CFrame = self.BodyCFrame

	for _, leg in ipairs(self.Legs) do
		leg:Render(self.BodyCFrame) -- after the body settles, or the limbs lag a frame
	end
end

function Walker:Destroy()
	self.Model:Destroy() -- takes the chassis and all eighteen limb parts
	table.clear(self.Legs)
end

local localPlayer = Players.LocalPlayer
local walker = Walker.New(CONFIG.SPAWN_POSITION)

local function OnCharacterAdded(character: Model)
	walker:RefreshFilter(character)
end

if localPlayer.Character then -- script may have loaded after the character
	OnCharacterAdded(localPlayer.Character)
end
localPlayer.CharacterAdded:Connect(OnCharacterAdded)

local connection -- declared first so the closure below can disconnect it
connection = RunService.RenderStepped:Connect(function(deltaTime: number)
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") -- FindFirstChild, WaitForChild would yield mid frame
	walker:Step(deltaTime, root and root.Position or nil)
end)

script.Destroying:Connect(function()
	connection:Disconnect() -- drop the signal before the parts go
	walker:Destroy()
end)
