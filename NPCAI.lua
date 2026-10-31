--// Services
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--// Constants
local NPC_TAG = "Npc"
local TICK_INTERVAL = 1 / 8 -- Each NPC makes decisions 8 times a second; the Humanoid handles the walking between ticks.
local ARRIVE_DISTANCE = 3 -- How close (in studs) counts as having reached a point.
local REPATH_DISTANCE = 4 -- A new path is only computed if the goal has moved further than this from the current path's goal.
local REPATH_COOLDOWN = 0.5 -- Minimum time between path requests, since ComputeAsync is expensive.

-- Tuning for each enemy type. Distances are in studs, times in seconds.
-- Suspicion is a 0 to 1 meter: the NPC investigates once it passes InvestigateAt and chases once it reaches ChaseAt.
local ARCHETYPES = {
	Grunt = {
		WalkSpeed = 9,
		RunSpeed = 18,

		SightRange = 70,
		FieldOfView = math.rad(110),
		CloseRange = 8, -- Within this distance the NPC notices a player even if they are behind it.

		SuspicionGain = 1.1, -- Gain per second at point-blank range; it scales down with distance.
		SuspicionDecay = 0.2, -- Loss per second while no player is visible.
		InvestigateAt = 0.35,
		ChaseAt = 1,

		LoseSightTime = 4, -- If the target stays out of sight this long during a chase, the NPC goes to investigate instead.
		SearchTime = 5, -- How long the NPC searches the last known position before returning to patrol.
		PatrolPause = 2, -- How long the NPC waits at each patrol point.
		AlertRadius = 45, -- NPCs within this radius are alerted when a chase begins.

		AttackRange = 4.5,
		AttackDamage = 15,
		AttackCooldown = 1.2,

		PathCosts = { Water = 20, Danger = math.huge }, -- "Danger" is a PathfindingModifier label; math.huge makes it impassable.
	},

	Brute = {
		WalkSpeed = 7,
		RunSpeed = 13,

		SightRange = 50,
		FieldOfView = math.rad(90),
		CloseRange = 6,

		SuspicionGain = 0.7,
		SuspicionDecay = 0.15,
		InvestigateAt = 0.4,
		ChaseAt = 1,

		LoseSightTime = 6,
		SearchTime = 8,
		PatrolPause = 4,
		AlertRadius = 30,

		AttackRange = 6,
		AttackDamage = 35,
		AttackCooldown = 2.2,

		PathCosts = { Water = math.huge, Danger = math.huge }, -- Brutes never path through water.
	},
}

--// Variables
local npcs = {} -- Every active NPC object, iterated each Heartbeat.

--// Functions
-- Horizontal distance only, so slopes and jumps don't stop an NPC from counting as "arrived".
local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- Returns the player's HumanoidRootPart only if they are still in the game and alive.
local function getAliveRoot(player: Player?): BasePart?
	local character = player and player.Parent and player.Character -- player.Parent is nil once the player has left.
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if humanoid and humanoid.Health > 0 then
		return character:FindFirstChild("HumanoidRootPart") :: BasePart?
	end

	return nil
end

-- Reads the NPC's patrol route once and caches the point positions.
local function loadRoute(model: Model): { Vector3 }
	local routes = Workspace:FindFirstChild("PatrolRoutes")
	local folder = routes and routes:FindFirstChild(model:GetAttribute("PatrolRoute") or "")
	local points = {}

	for _, child in if folder then folder:GetChildren() else {} do -- For every part in the route folder...
		if child:IsA("BasePart") then
			-- Positions are stored instead of parts, since routes are static and don't need re-reading every tick.
			points[tonumber(child.Name) or #points + 1] = child.Position
		end
	end

	return points -- An empty route means the NPC simply guards its spawn position.
end

--// Npc class
local Npc = {}
Npc.__index = Npc

local States = {}

function Npc.new(model: Model, archetype)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local rootPart = model:FindFirstChild("HumanoidRootPart") :: BasePart?

	if not (humanoid and rootPart and rootPart:CanSetNetworkOwnership()) then
		return nil
	end

	rootPart:SetNetworkOwner(nil) -- The server owns the physics, so exploiters can't fling, freeze or teleport the NPC.

	local self = setmetatable({}, Npc)
	self.model, self.humanoid, self.rootPart = model, humanoid, rootPart
	self.head = model:FindFirstChild("Head") :: BasePart?
	self.archetype = archetype
	self.fovCos = math.cos(archetype.FieldOfView / 2) -- Precomputed once so the sight check is a single dot-product comparison.
	self.route = loadRoute(model)
	self.routeIndex = 1
	self.home = rootPart.Position
	self.suspicion = 0
	self.lastSeenAt = -math.huge
	self.attackReadyAt = 0
	self.nextTickAt, self.lastTickAt = 0, os.clock()
	self.waypointIndex = 1
	self.lastPathAt = -math.huge
	self.connections = {}

	self.raycastParams = RaycastParams.new()
	self.raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	self.raycastParams.FilterDescendantsInstances = { model } -- Excludes the NPC's own body from its line-of-sight rays.

	-- A single Path object per NPC, reused for every ComputeAsync call rather than creating a new one each time.
	self.path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		WaypointSpacing = 4,
		Costs = archetype.PathCosts,
	})

	-- Advance to the next waypoint the moment one is reached, instead of waiting for the next tick.
	-- Without this, running NPCs visibly stutter at every waypoint.
	table.insert(
		self.connections,
		humanoid.MoveToFinished:Connect(function(reached)
			if reached and self.waypoints then
				self.waypointIndex += 1
				self:_issueMove()
			end
		end)
	)

	self:transition("Patrol")

	return self
end

function Npc.destroy(self)
	for _, connection in self.connections do -- For every connection this NPC made...
		connection:Disconnect()
	end

	-- If a path is still being computed, cancel it so it can't order a dead NPC to move once it finishes.
	if self.pathThread and coroutine.status(self.pathThread) == "suspended" then
		task.cancel(self.pathThread)
	end

	self.path:Destroy()
end

function Npc.transition(self, name: string)
	if name == self.state then
		return
	end

	self.state = name
	States[name].enter(self)
	self.model:SetAttribute("AiState", name) -- Attributes replicate, so clients can react to state changes without a remote.
end

--// Perception
-- Finds the closest player this NPC can currently see, using range, field of view and a line-of-sight raycast.
function Npc.sense(self): (Player?, BasePart?, number)
	local archetype = self.archetype
	local eye = if self.head then self.head.Position else self.rootPart.Position + Vector3.yAxis * 1.5
	local facing = self.rootPart.CFrame.LookVector
	local bestPlayer, bestRoot, bestDistance = nil, nil, math.huge

	for _, player in Players:GetPlayers() do -- For every player in the game...
		local root = getAliveRoot(player)
		local offset = root and root.Position - eye
		local distance = if offset then offset.Magnitude else math.huge

		-- The checks run cheapest first: distance, then field of view, then the raycast.
		-- Anyone out of range, or further away than a player already found, is skipped immediately.
		if distance > math.min(archetype.SightRange, bestDistance) then
			continue
		end

		local inView = distance <= archetype.CloseRange or facing:Dot(offset.Unit) >= self.fovCos
		local hit = inView and Workspace:Raycast(eye, offset, self.raycastParams) -- The raycast is the most expensive check, so it runs last.

		if inView and (not hit or hit.Instance:IsDescendantOf(player.Character)) then
			bestPlayer, bestRoot, bestDistance = player, root, distance
		end
	end

	return bestPlayer, bestRoot, bestDistance
end

-- Raises or lowers suspicion based on what the NPC can see, and records the target's last known position.
function Npc.updateAwareness(self, now: number, deltaTime: number): boolean
	local archetype = self.archetype
	local seen, seenRoot, distance = self:sense()

	if seen and seenRoot then
		-- Suspicion builds faster the closer the player is.
		local closeness = 1 - math.clamp(distance / archetype.SightRange, 0, 1)

		self.suspicion = math.min(1, self.suspicion + archetype.SuspicionGain * (0.25 + closeness) * deltaTime)
		self.target, self.lastKnownPosition, self.lastSeenAt = seen, seenRoot.Position, now
	else
		self.suspicion = math.max(0, self.suspicion - archetype.SuspicionDecay * deltaTime)
	end

	-- Rounded to one decimal place; SetAttribute doesn't replicate unchanged values, so this keeps network traffic low.
	self.model:SetAttribute("Suspicion", math.floor(self.suspicion * 10) / 10)

	return seen ~= nil
end

-- Sends nearby NPCs to investigate the position this NPC is chasing towards.
function Npc.alertAllies(self)
	for _, ally in npcs do -- For every other active NPC...
		local inRange = (ally.rootPart.Position - self.rootPart.Position).Magnitude <= self.archetype.AlertRadius

		if ally ~= self and inRange and ally.state ~= "Chase" then
			ally.lastKnownPosition = self.lastKnownPosition

			-- Suspicion is raised slightly above the investigate threshold so a single tick of decay doesn't cancel it.
			-- Alerted allies still have to see the player themselves before they start chasing.
			ally.suspicion = math.max(ally.suspicion, math.min(ally.archetype.InvestigateAt + 0.15, 1))
		end
	end
end

--// Movement
-- Sets where the NPC wants to go, only requesting a new path when the goal has moved meaningfully.
function Npc.setGoal(self, position: Vector3)
	self.goal = position

	if not self.pathGoal or flatDistance(position, self.pathGoal) > REPATH_DISTANCE then
		self:_requestPath()
	end
end

function Npc._requestPath(self)
	local now, goal = os.clock(), self.goal
	local isBusy = self.pathThread ~= nil and coroutine.status(self.pathThread) == "suspended"

	-- Only one path request runs at a time; if this one is skipped, setGoal retries on the next tick.
	if not goal or isBusy or now - self.lastPathAt < REPATH_COOLDOWN then
		return
	end

	self.lastPathAt = now

	-- ComputeAsync yields, so it runs in its own thread to avoid stalling every other NPC's update.
	self.pathThread = task.spawn(function()
		local ok = pcall(self.path.ComputeAsync, self.path, self.rootPart.Position, goal) -- ComputeAsync can throw, so it's wrapped in pcall.

		if ok and self.path.Status == Enum.PathStatus.Success then
			self.waypoints = self.path:GetWaypoints()
			self.waypointIndex = 2 -- Waypoint 1 is the NPC's current position, so movement starts from waypoint 2.
			self:_issueMove()
		else
			self.waypoints = nil
			self.humanoid:MoveTo(goal) -- Fallback when no path exists: walk straight towards the goal.
		end

		self.pathGoal = goal
	end)
end

function Npc._issueMove(self)
	local waypoint = self.waypoints and self.waypoints[self.waypointIndex]

	if not waypoint then
		self.waypoints = nil -- The end of the path has been reached.
		return
	end

	self.humanoid.Jump = waypoint.Action == Enum.PathWaypointAction.Jump
	self.humanoid:MoveTo(waypoint.Position)
end

-- Holds the NPC in place for a set duration (used for patrol pauses and searching).
-- Returns true once the wait has finished.
function Npc.waitThenAdvance(self, now: number, duration: number): boolean
	if not self.waitUntil then
		self.waitUntil = now + duration
		self.goal, self.pathGoal, self.waypoints = nil, nil, nil
		self.humanoid:MoveTo(self.rootPart.Position) -- Overrides the current MoveTo so the NPC actually stops.
	elseif now >= self.waitUntil then
		self.waitUntil = nil
		return true
	end

	return false
end

--// States
-- Each state's update returns the name of the state to switch to, or nil to stay in the current one.
States.Patrol = {
	enter = function(self)
		self.humanoid.WalkSpeed = self.archetype.WalkSpeed
		self.target, self.waitUntil = nil, nil
	end,

	update = function(self, now, deltaTime)
		local seen = self:updateAwareness(now, deltaTime)

		if seen and self.suspicion >= self.archetype.ChaseAt then
			return "Chase"
		elseif self.suspicion >= self.archetype.InvestigateAt then
			return "Investigate"
		end

		local point = self.route[self.routeIndex] or self.home

		if flatDistance(self.rootPart.Position, point) > ARRIVE_DISTANCE then
			self:setGoal(point)
		elseif #self.route > 0 and self:waitThenAdvance(now, self.archetype.PatrolPause) then
			self.routeIndex = self.routeIndex % #self.route + 1 -- Wraps back to the first point after the last one.
		end

		return nil
	end,
}

States.Investigate = {
	enter = function(self)
		self.humanoid.WalkSpeed = self.archetype.WalkSpeed
		self.waitUntil = nil
	end,

	update = function(self, now, deltaTime)
		local seen = self:updateAwareness(now, deltaTime)
		local spot = self.lastKnownPosition

		if seen and self.suspicion >= self.archetype.ChaseAt then
			return "Chase"
		elseif not spot then
			return "Patrol"
		end

		if flatDistance(self.rootPart.Position, spot) > ARRIVE_DISTANCE then
			self.waitUntil = nil -- New information moved the search spot, so the search timer restarts on arrival.
			self:setGoal(spot)
		elseif self:waitThenAdvance(now, self.archetype.SearchTime) then
			return "Patrol"
		end

		return nil
	end,
}

States.Chase = {
	enter = function(self)
		self.humanoid.WalkSpeed = self.archetype.RunSpeed
		self:alertAllies()
	end,

	update = function(self, now, deltaTime)
		local seen = self:updateAwareness(now, deltaTime)
		local targetRoot = getAliveRoot(self.target)

		-- The target died, left, or has been out of sight too long, so search where they were last seen.
		if not targetRoot or now - self.lastSeenAt > self.archetype.LoseSightTime then
			return "Investigate"
		end

		local distance = (targetRoot.Position - self.rootPart.Position).Magnitude

		if not seen or distance > self.archetype.AttackRange then
			-- While the target is visible, lastKnownPosition is their current position.
			self:setGoal(self.lastKnownPosition)
			return nil
		end

		-- In attack range: keep closing in so the NPC faces the target, and attack whenever the cooldown allows.
		self.humanoid:MoveTo(targetRoot.Position)

		local targetHumanoid = targetRoot.Parent and targetRoot.Parent:FindFirstChildOfClass("Humanoid")

		if targetHumanoid and now >= self.attackReadyAt then
			self.attackReadyAt = now + self.archetype.AttackCooldown
			targetHumanoid:TakeDamage(self.archetype.AttackDamage) -- TakeDamage respects ForceFields, unlike setting Health directly.
		end

		return nil
	end,
}

--// Registration
local function unregister(model: Instance)
	for index, npc in npcs do -- For every active NPC...
		if npc.model == model then
			table.remove(npcs, index)
			npc:destroy()
			return
		end
	end
end

local function register(model: Instance)
	-- Only models in Workspace are activated, so tagged templates stored in ServerStorage are ignored.
	if not model:IsA("Model") or not model:IsDescendantOf(Workspace) then
		return
	end

	local archetype = ARCHETYPES[model:GetAttribute("Archetype") or "Grunt"]
	local npc = archetype and Npc.new(model, archetype)

	if not npc then
		warn(`[NpcAI] {model:GetFullName()} skipped: unknown Archetype or not a server-ownable rig`)
		return
	end

	table.insert(npcs, npc)

	table.insert(
		npc.connections,
		npc.humanoid.Died:Connect(function()
			model:SetAttribute("AiState", "Dead")
			unregister(model) -- Stops the AI immediately but leaves the body in the world.
		end)
	)
end

-- Runs every frame, but each NPC only updates once its own tick interval has passed.
local function step()
	local now = os.clock()

	-- Iterates backwards so removing an NPC mid-loop doesn't cause the next one to be skipped.
	for index = #npcs, 1, -1 do
		local npc = npcs[index]

		if now >= npc.nextTickAt then
			local nextState = States[npc.state].update(npc, now, now - npc.lastTickAt)

			npc.nextTickAt, npc.lastTickAt = now + TICK_INTERVAL, now

			if nextState then
				npc:transition(nextState)
			end
		end
	end
end

--// Start
-- The removed signal also fires when a tagged model is destroyed, which covers cleanup as well.
CollectionService:GetInstanceAddedSignal(NPC_TAG):Connect(register)
CollectionService:GetInstanceRemovedSignal(NPC_TAG):Connect(unregister)
RunService.Heartbeat:Connect(step)

for _, model in CollectionService:GetTagged(NPC_TAG) do -- For every NPC that already existed before this script ran...
	register(model)
end

