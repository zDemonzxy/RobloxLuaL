-- NpcAI


--// Services
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--// Constants
local NPC_TAG = "Npc"
local TICK_INTERVAL = 1 / 8 -- each npc thinks 8 times a second, the humanoid does the actual walking in between
local ARRIVE_DISTANCE = 3
local REPATH_DISTANCE = 4 -- if the goal moves more than this from the last path, make a new path
local REPATH_COOLDOWN = 0.5

-- settings for each enemy type. distances in studs, times in seconds
-- suspicion goes 0 -> 1, they investigate at InvestigateAt and start chasing at ChaseAt
local ARCHETYPES = {
	Grunt = {
		WalkSpeed = 9,
		RunSpeed = 18,

		SightRange = 70,
		FieldOfView = math.rad(110),
		CloseRange = 8, -- this close they notice you even if youre behind them

		SuspicionGain = 1.1, -- per second when ur right next to them, less the further away you are
		SuspicionDecay = 0.2,
		InvestigateAt = 0.35,
		ChaseAt = 1,

		LoseSightTime = 4, -- cant see you for this long in a chase -> go check where you were last
		SearchTime = 5,
		PatrolPause = 2,
		AlertRadius = 45, -- other npcs in this range come check it out when a chase starts

		AttackRange = 4.5,
		AttackDamage = 15,
		AttackCooldown = 1.2,

		PathCosts = { Water = 20, Danger = math.huge }, -- Danger is a PathfindingModifier label, never walk through those
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

		PathCosts = { Water = math.huge, Danger = math.huge }, -- brutes just dont do water
	},
}

--// Variables
local npcs = {}

--// Functions
local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude -- ignores height
end

local function getAliveRoot(player: Player?): BasePart?
	local character = player and player.Parent and player.Character -- player.Parent is nil if they left
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if humanoid and humanoid.Health > 0 then
		return character:FindFirstChild("HumanoidRootPart") :: BasePart?
	end

	return nil
end

local function loadRoute(model: Model): { Vector3 }
	local routes = Workspace:FindFirstChild("PatrolRoutes")
	local folder = routes and routes:FindFirstChild(model:GetAttribute("PatrolRoute") or "")
	local points = {}

	for _, child in if folder then folder:GetChildren() else {} do
		if child:IsA("BasePart") then
			-- store the position not the part, routes dont move so no point reading it every tick
			points[tonumber(child.Name) or #points + 1] = child.Position
		end
	end

	return points -- empty if theres no route, then the npc just guards where it spawned
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

	rootPart:SetNetworkOwner(nil) -- server owns the physics so exploiters cant fling or freeze the npc

	local self = setmetatable({}, Npc)
	self.model, self.humanoid, self.rootPart = model, humanoid, rootPart
	self.head = model:FindFirstChild("Head") :: BasePart?
	self.archetype = archetype
	self.fovCos = math.cos(archetype.FieldOfView / 2) -- worked out once, the sight check just compares a dot product to this
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
	self.raycastParams.FilterDescendantsInstances = { model } -- so the npc doesnt block its own line of sight

	-- one path object per npc, reused for every ComputeAsync call
	self.path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		WaypointSpacing = 4,
		Costs = archetype.PathCosts,
	})

	-- go to the next waypoint as soon as we reach one, instead of waiting for the next tick
	-- otherwise running npcs stop for a split second at every waypoint
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
	for _, connection in self.connections do
		connection:Disconnect()
	end

	-- if the npc dies while a path is still being computed, kill that thread
	-- otherwise it finishes and tells a dead body to walk somewhere
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
	self.model:SetAttribute("AiState", name) -- attributes replicate, so clients can show a ? or ! above the npc
end

--// Seeing players
function Npc.sense(self): (Player?, BasePart?, number)
	local archetype = self.archetype
	local eye = if self.head then self.head.Position else self.rootPart.Position + Vector3.yAxis * 1.5
	local facing = self.rootPart.CFrame.LookVector
	local bestPlayer, bestRoot, bestDistance = nil, nil, math.huge

	for _, player in Players:GetPlayers() do -- for every player in the game...
		local root = getAliveRoot(player)
		local offset = root and root.Position - eye
		local distance = if offset then offset.Magnitude else math.huge

		-- distance check first since its the cheapest, skips anyone too far or further than who we already see
		if distance > math.min(archetype.SightRange, bestDistance) then
			continue
		end

		local inView = distance <= archetype.CloseRange or facing:Dot(offset.Unit) >= self.fovCos
		local hit = inView and Workspace:Raycast(eye, offset, self.raycastParams) -- raycast last cause its the most expensive

		if inView and (not hit or hit.Instance:IsDescendantOf(player.Character)) then
			bestPlayer, bestRoot, bestDistance = player, root, distance
		end
	end

	return bestPlayer, bestRoot, bestDistance
end

function Npc.updateAwareness(self, now: number, deltaTime: number): boolean
	local archetype = self.archetype
	local seen, seenRoot, distance = self:sense()

	if seen and seenRoot then
		-- suspicion goes up faster the closer you are
		local closeness = 1 - math.clamp(distance / archetype.SightRange, 0, 1)

		self.suspicion = math.min(1, self.suspicion + archetype.SuspicionGain * (0.25 + closeness) * deltaTime)
		self.target, self.lastKnownPosition, self.lastSeenAt = seen, seenRoot.Position, now
	else
		self.suspicion = math.max(0, self.suspicion - archetype.SuspicionDecay * deltaTime)
	end

	-- rounded to 0.1 so the attribute barely changes, SetAttribute skips replicating when the value is the same
	self.model:SetAttribute("Suspicion", math.floor(self.suspicion * 10) / 10)

	return seen ~= nil
end

function Npc.alertAllies(self)
	for _, ally in npcs do
		local inRange = (ally.rootPart.Position - self.rootPart.Position).Magnitude <= self.archetype.AlertRadius

		if ally ~= self and inRange and ally.state ~= "Chase" then
			ally.lastKnownPosition = self.lastKnownPosition

			-- bump them a bit past the investigate threshold so one tick of decay doesnt cancel it
			-- they come check it out but still have to actually see you before chasing
			ally.suspicion = math.max(ally.suspicion, math.min(ally.archetype.InvestigateAt + 0.15, 1))
		end
	end
end

--// Moving
function Npc.setGoal(self, position: Vector3)
	self.goal = position

	if not self.pathGoal or flatDistance(position, self.pathGoal) > REPATH_DISTANCE then
		self:_requestPath()
	end
end

function Npc._requestPath(self)
	local now, goal = os.clock(), self.goal
	local isBusy = self.pathThread ~= nil and coroutine.status(self.pathThread) == "suspended"

	-- only one path request at a time, setGoal will just try again next tick
	if not goal or isBusy or now - self.lastPathAt < REPATH_COOLDOWN then
		return
	end

	self.lastPathAt = now

	self.pathThread = task.spawn(function()
		local ok = pcall(self.path.ComputeAsync, self.path, self.rootPart.Position, goal) -- can error so pcall it

		if ok and self.path.Status == Enum.PathStatus.Success then
			self.waypoints = self.path:GetWaypoints()
			self.waypointIndex = 2 -- waypoint 1 is where the npc is already standing
			self:_issueMove()
		else
			self.waypoints = nil
			self.humanoid:MoveTo(goal) -- couldnt find a path so just walk straight at it
		end

		self.pathGoal = goal
	end)
end

function Npc._issueMove(self)
	local waypoint = self.waypoints and self.waypoints[self.waypointIndex]

	if not waypoint then
		self.waypoints = nil -- reached the end of the path
		return
	end

	self.humanoid.Jump = waypoint.Action == Enum.PathWaypointAction.Jump
	self.humanoid:MoveTo(waypoint.Position)
end

-- used for the pause at each patrol point and for searching when investigating
-- returns true once the wait is over
function Npc.waitThenAdvance(self, now: number, duration: number): boolean
	if not self.waitUntil then
		self.waitUntil = now + duration
		self.goal, self.pathGoal, self.waypoints = nil, nil, nil
		self.humanoid:MoveTo(self.rootPart.Position) -- cancels the current MoveTo so it actually stands still
	elseif now >= self.waitUntil then
		self.waitUntil = nil
		return true
	end

	return false
end

--// States
-- each update returns the name of the next state, or nil to stay
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
			self.routeIndex = self.routeIndex % #self.route + 1 -- goes back to point 1 after the last one
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
			self.waitUntil = nil -- the spot moved (got new info), so restart the search once we get there
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

		-- lost them (dead, left, or out of sight too long), go check where we last saw them
		if not targetRoot or now - self.lastSeenAt > self.archetype.LoseSightTime then
			return "Investigate"
		end

		local distance = (targetRoot.Position - self.rootPart.Position).Magnitude

		if not seen or distance > self.archetype.AttackRange then
			-- while we can see them lastKnownPosition is just where they are now
			self:setGoal(self.lastKnownPosition)
			return nil
		end

		-- in range, keep facing them and hit them when the cooldown is up
		self.humanoid:MoveTo(targetRoot.Position)

		local targetHumanoid = targetRoot.Parent and targetRoot.Parent:FindFirstChildOfClass("Humanoid")

		if targetHumanoid and now >= self.attackReadyAt then
			self.attackReadyAt = now + self.archetype.AttackCooldown
			targetHumanoid:TakeDamage(self.archetype.AttackDamage) -- TakeDamage instead of Health -= so forcefields still work
		end

		return nil
	end,
}

--// Registering
local function unregister(model: Instance)
	for index, npc in npcs do
		if npc.model == model then
			table.remove(npcs, index)
			npc:destroy()
			return
		end
	end
end

local function register(model: Instance)
	-- only npcs actually in workspace, tagged templates sitting in ServerStorage get ignored
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
			unregister(model) -- stops the ai straight away, leaves the body there
		end)
	)
end

local function step()
	local now = os.clock()

	-- loop backwards so if an npc gets removed mid loop it doesnt skip the next one
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
-- the removed signal also fires when a tagged model gets destroyed, so that covers cleanup too
CollectionService:GetInstanceAddedSignal(NPC_TAG):Connect(register)
CollectionService:GetInstanceRemovedSignal(NPC_TAG):Connect(unregister)
RunService.Heartbeat:Connect(step)

for _, model in CollectionService:GetTagged(NPC_TAG) do
	register(model)
end
