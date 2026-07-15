--Discord : gusstavolo#488366741366243360 or Gusss#0715 / Roblox : @TheLogg or 451103818

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local CollectionService = game:GetService("CollectionService")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = ReplicatedStorage:WaitForChild("Assets")
local boxTemplate = Assets:WaitForChild("Box"):WaitForChild("Box") :: Model
local popTemplate = Assets:WaitForChild("Pops"):WaitForChild("PopTime") :: Model
local rewardFolder = Assets:WaitForChild("Rewards")
local rewardPool = rewardFolder:GetChildren()

local WorkbenchFolder = workspace:WaitForChild("Workbench")
local BoxSpawnModel = workspace:WaitForChild("BoxSpawn")
local spawnAnchor = BoxSpawnModel:WaitForChild("Pos") :: BasePart

type Session = {
	key: string,
	boxesOpened: number,
	dirty: boolean
}

type Bubble = {
	model: Model,
	alive: boolean
}

--[[
	Central tuning table for the whole system. Keeping every magic number
	here (instead of scattered through the code) means gameplay balance
	can be adjusted without touching logic, and makes it obvious which
	values are related (all Bubble* fields control the same mechanic).
]]
local Config = {
	DragMaxForce = 50000,
	DragMaxTorque = 50000,
	DragActivationDist = 15,
	DragDistanceLimit = 20,
	DragYOffset = 2,

	OpenDuration = 18.0,
	TimerFloor = 4.0,
	TimerUpdateRate = 0.05,

	BubbleInterval = 1.8,
	BubbleMinLife = 3.0,
	BubbleMaxLife = 6.5,
	BubbleFloatSpeed = 2.2,
	BubbleSpawnRadius = 5.0,
	BubbleSpawnYMin = 2.0,
	BubbleSpawnYMax = 3.5,
	BubbleWobbleAmp = 0.18,
	BubbleClickReduction = 2.5,
	BubblePopScale = 2.8,
	BubblePopDuration = 0.18,

	RewardDragForce = 40000,
	RewardLifetime = 30,
	BoxOpenAnimTime = 0.55,

	DataStoreName = "WorkbenchBoxCount_v1",
	DataStoreRetries = 3,
}

local State = {
	Idle = "Idle",
	Opening = "Opening",
	Opened = "Opened",
}

local BoxStore = DataStoreService:GetDataStore(Config.DataStoreName)
local sessions: { [number]: Session } = {}

--[[
	Loads a player's saved box count when they join.
	Runs inside a pcall because DataStore calls are external web requests and can fail 
	(throttling, service outage). A failure here should never crash the join flow; 
	worst case, the player starts at 0 and we just don't have last session's cloud value.
]]
local function loadSession(player: Player)
	local key = "player_" .. tostring(player.UserId)
	local ok, stored = pcall(function()
		return BoxStore:GetAsync(key)
	end)

	local count = 0
	if ok and type(stored) == "table" and stored.boxesOpened then
		count = stored.boxesOpened
	end

	sessions[player.UserId] = {
		key = key,
		boxesOpened = count,
		dirty = false,
	}

	-- Instance lifecycle optimization: we define and configure all properties 
	-- before setting the Parent. This avoids unnecessary replication updates and 
	-- UI recalculation events during initialization.
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local boxesValue = Instance.new("IntValue")
	boxesValue.Name = "Boxes Opened"
	boxesValue.Value = count
	boxesValue.Parent = leaderstats
end

local function recordBoxOpened(player: Player)
	local session = sessions[player.UserId]
	if not session then
		return
	end

	session.boxesOpened += 1
	session.dirty = true

	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		return
	end

	local boxesValue = leaderstats:FindFirstChild("Boxes Opened") :: IntValue?
	if boxesValue then
		boxesValue.Value = session.boxesOpened
	end
end

--[[
	Saves the player's session back to the DataStore on leave/server close.
	Uses UpdateAsync instead of SetAsync because two servers could theoretically
	hold data for the same player (rejoining fast, or a rare race condition on shutdown).
	Comparing oldValue against the local session stops an outdated session from 
	overwriting a higher value already saved by another server.
	
	Includes a progressive backoff retry strategy to prevent spamming the DataStore APIs
	if the service is temporarily rate-limiting or experiencing transient failures.
]]
local function saveSession(player: Player)
	local session = sessions[player.UserId]
	if not session or not session.dirty then
		return
	end

	local success = false
	local errorMessage

	for attempt = 1, Config.DataStoreRetries do
		success, errorMessage = pcall(function()
			return BoxStore:UpdateAsync(session.key, function(oldValue: any)
				if type(oldValue) == "table" and (oldValue.boxesOpened or 0) > session.boxesOpened then
					return nil
				end
				return { boxesOpened = session.boxesOpened }
			end)
		end)

		if success then
			break
		end

		-- Progressive backoff: waiting longer with each failed attempt 
		-- to allow internal service limits to cool down before retrying.
		task.wait(attempt * 1.5)
	end

	if not success then
		warn(`[DataStore] Failed to save data for {player.Name} after {Config.DataStoreRetries} attempts: {errorMessage}`)
	end

	sessions[player.UserId] = nil
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(loadSession, player)
end)

Players.PlayerRemoving:Connect(saveSession)

for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(loadSession, p)
end

--[[
	Creates a new draggable box at the spawn point and wires up its DragDetector.
	Using a tail-recursive call structure inside DragEnd ensures that there is
	always exactly one active box in the physical space without having to run
	an intensive game loop watching the box counts.
]]
local function spawnBox()
	local box = boxTemplate:Clone()
	box.Parent = BoxSpawnModel
	box:PivotTo(spawnAnchor.WorldCFrame)

	CollectionService:AddTag(box, "Box")

	local dd = Instance.new("DragDetector")
	dd.ResponseStyle = Enum.DragDetectorResponseStyle.Physical
	dd.DragStyle = Enum.DragDetectorDragStyle.BestForDevice
	dd.MaxForce = Config.DragMaxForce
	dd.MaxTorque = Config.DragMaxTorque
	dd.MaxActivationDistance = Config.DragActivationDist
	dd.ApplyAtCenterOfMass = true
	dd.Responsiveness = 10

	--[[
		Constrains the drag target so the box can never be pulled below the
		spawn floor or flung to extreme positions. Physical DragDetectors apply
		force toward the proposed CFrame every frame. Without this clamp, a
		player aiming their mouse under the floor or off the edge of the map
		would cause the physics solver to fling the box at high velocity, risking
		severe positional desync.
	]]
	dd:AddConstraintFunction(1, function(proposed: CFrame): CFrame
		local newPos = proposed.Position
		local floorY = spawnAnchor.Position.Y

		if newPos.Y < floorY then
			newPos = Vector3.new(newPos.X, floorY, newPos.Z)
		end

		return CFrame.new(newPos) * proposed.Rotation + Vector3.new(0, Config.DragYOffset, 0)
	end)

	--[[
		Force-stops the box if the dragging player walks too far away.
		Toggling Enabled off then back on next frame via task.defer (instead of 
		just zeroing velocity) fully resets the DragDetector's internal solver target,
		preventing it from immediately re-accelerating the box back toward the player 
		once they return into range.
	]]
	dd.DragContinue:Connect(function(player: Player)
		local char = player.Character
		if not char then
			return
		end

		local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local primary = box.PrimaryPart
		if not hrp or not primary then
			return
		end

		if (primary.Position - hrp.Position).Magnitude > Config.DragDistanceLimit then
			primary.AssemblyLinearVelocity = Vector3.zero
			primary.AssemblyAngularVelocity = Vector3.zero
			dd.Enabled = false
			task.defer(function()
				dd.Enabled = true
			end)
		end
	end)

	--[[
		Anchors the drag limits to the player's HumanoidRootPart instead of world space.
		This ensures that the box stays within a local bounding circle around whoever
		is holding it, preventing players from manipulating boxes across the map.
	]]
	dd.DragStart:Connect(function(player: Player)
		box:SetAttribute("PlacedBy", player.UserId)

		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?

		if hrp then
			dd.ReferenceInstance = hrp
			local limit = Config.DragDistanceLimit - 10

			dd.MinDragTranslation = Vector3.new(-limit, -40, -limit)
			dd.MaxDragTranslation = Vector3.new(limit, 40, limit)
		end
	end)

	dd.DragEnd:Once(function()
		box.Parent = workspace

		dd.ReferenceInstance = nil
		dd.MinDragTranslation = Vector3.new(-math.huge, -math.huge, -math.huge)
		dd.MaxDragTranslation = Vector3.new(math.huge, math.huge, math.huge)

		local primary = box.PrimaryPart
		if primary then
			primary.AssemblyLinearVelocity = Vector3.zero
			primary.AssemblyAngularVelocity = Vector3.zero
		end

		spawnBox()
	end)

	dd.Parent = box
	return box
end

spawnBox()

local Workbench = {}
Workbench.__index = Workbench

--[[
	Workbench represents a single opening station in the map.
	Each instance tracks its own state (Idle -> Opening -> Opened) using an OOP structure,
	guaranteeing that multiple players can open boxes at different tables simultaneously
	without shared-state conflicts. 
	
	The class encapsulates and tracks its own hardware events, heartbeat connections, 
	and physical entities, cleaning them up systematically inside :Destroy() to avoid 
	memory leaks in long-running server environments.
]]
function Workbench.new(model: Model)
	local self = setmetatable({}, Workbench)

	self.Model = model
	self.PosBox = model:WaitForChild("PosBox") :: BasePart
	self.ZoneBox = model:WaitForChild("ZoneBox") :: BasePart

	self.gui = model:WaitForChild("Gui")
	self.timerGui = self.gui:WaitForChild("Timer")
	self.TimerLabel = self.timerGui:WaitForChild("Text") :: TextLabel
	self.FinishGui = self.gui:WaitForChild("Finish")

	self.ParticlesOpen = model:WaitForChild("Particles"):WaitForChild("Open")

	model.Destroying:Connect(function()
		self:Destroy()
	end)

	self._state = State.Idle
	self._box = nil :: Model?
	self._placer = nil :: Player?
	self._timer = 0
	self._timerAcc = 0
	self._spawnAcc = 0
	self._bubbles = {} :: {Bubble}
	self._hbConn = nil :: RBXScriptConnection?
	self._conns = {} :: {RBXScriptConnection}

	self.FinishGui.Visible = false
	self.TimerLabel.Text = ""

	self:_listenForBox()

	return self
end

--[[
	Listens for a box touching this workbench's zone.
	The debounce table maps directly to the box Instance rather than a standard boolean.
	Since the Touched event can fire dozens of times per single physics collision,
	indexing by the instance guarantees that we trigger the transition logic exactly
	once per box, avoiding race conditions if multiple boxes hit the zone at once.
]]
function Workbench:_listenForBox()
	local debounce = {}

	local conn = self.ZoneBox.Touched:Connect(function(hit)
		if self._state ~= State.Idle then
			return
		end

		local parent = hit.Parent
		if not parent or not CollectionService:HasTag(parent, "Box") then
			return
		end

		if debounce[parent] then
			return
		end

		debounce[parent] = true

		task.defer(function()
			self:_enterOpening(parent :: Model)
			debounce[parent] = nil
		end)
	end)

	table.insert(self._conns, conn)
end

--[[
	Transitions the workbench into the Opening state.
	The box's anchoring is deferred by 0.2 seconds instead of anchoring immediately.
	This brief pause allows the physics solver a few frames to resolve any residual
	moments of inertia or angular velocity from being dropped, preventing the box
	from instantly snapping and clipping into the table model in a jarring way.
]]
function Workbench:_enterOpening(box: Model)
	if self._state ~= State.Idle then
		return
	end

	local primary = box.PrimaryPart
	if not primary then
		return
	end

	self._state = State.Opening
	self._box = box
	self._timer = Config.OpenDuration
	self._timerAcc = 0
	self._spawnAcc = 0
	table.clear(self._bubbles)

	local dd = box:FindFirstChildOfClass("DragDetector")
	if dd then
		dd.Enabled = false
	end

	primary.AssemblyLinearVelocity = Vector3.zero
	primary.AssemblyAngularVelocity = Vector3.zero
	box:PivotTo(self.PosBox.WorldCFrame)

	task.delay(0.2, function()
		if primary and primary.Parent then
			primary.Anchored = true
		end
	end)

	local placerId = box:GetAttribute("PlacedBy")
	if placerId then
		self._placer = Players:GetPlayerByUserId(placerId)
	else
		self._placer = nil
	end

	self.timerGui.Visible = true
	self:_burstParticles(true)
	self.TimerLabel.Text = tostring(math.ceil(self._timer))

	-- Binds the game tick logic directly to Heartbeat instead of a spawn loop.
	-- This coordinates mechanical ticks directly with Roblox's physical frame rate,
	-- leading to smoother visual timer decrements.
	self._hbConn = RunService.Heartbeat:Connect(function(dt)
		if self._state ~= State.Opening then
			return
		end
		self:_tickTimer(dt)
		self:_tickBubbles(dt)
	end)
end

function Workbench:_tickTimer(dt: number)
	self._timer -= dt
	self._timerAcc += dt

	if self._timerAcc >= Config.TimerUpdateRate then
		self._timerAcc = 0
		self.TimerLabel.Text = tostring(math.max(0, math.ceil(self._timer)))
	end

	if self._timer <= 0 then
		self:_enterOpened()
	end
end

function Workbench:_tickBubbles(dt: number)
	self._spawnAcc += dt
	if self._spawnAcc >= Config.BubbleInterval then
		self._spawnAcc = 0
		self:_spawnBubble()
	end
end

--[[
	Spawns a bubble that the player can click to speed up the opening process.
	Each bubble runs on a dual-path cleanup: it will automatically fade out and self-destruct 
	after its lifespan via task.delay, or pop instantly upon receiving a player's click.
	
	The click handler uses our standard _popBubble logic with the byPlayer flag set to true,
	which triggers the local state's speed-up formula, whereas a timeout does not.
]]
function Workbench:_spawnBubble()
	local angle = math.random() * math.pi * 2
	local radius = math.sqrt(math.random()) * Config.BubbleSpawnRadius
	local height = Config.BubbleSpawnYMin + math.random() * (Config.BubbleSpawnYMax - Config.BubbleSpawnYMin)

	local origin = self.PosBox.WorldPosition
	local spawnPos = origin + Vector3.new(
		math.cos(angle) * radius,
		height,
		math.sin(angle) * radius
	)

	local model = popTemplate:Clone()
	model:PivotTo(CFrame.new(spawnPos))
	model.Parent = workspace

	local lifespan = Config.BubbleMinLife + math.random() * (Config.BubbleMaxLife - Config.BubbleMinLife)
	local bubble: Bubble = { model = model, alive = true }

	local cd = model:FindFirstChildOfClass("ClickDetector")
	if cd then
		cd.MouseClick:Connect(function()
			if not bubble.alive then
				return
			end
			self:_popBubble(bubble, true)
		end)
	end

	table.insert(self._bubbles, bubble)

	local primaryPart = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not primaryPart then
		model:Destroy()
		return
	end

	local driftX = (math.random() - 0.5) * (Config.BubbleWobbleAmp * 15)
	local driftZ = (math.random() - 0.5) * (Config.BubbleWobbleAmp * 15)
	local endPos = spawnPos + Vector3.new(driftX, Config.BubbleFloatSpeed * lifespan, driftZ)

	local moveTween = TweenService:Create(primaryPart, TweenInfo.new(lifespan, Enum.EasingStyle.Linear), {
		CFrame = CFrame.new(endPos)
	})
	moveTween:Play()

	task.delay(lifespan, function()
		if bubble.alive then
			self:_popBubble(bubble, false)
		end
	end)
end

function Workbench:_popBubble(bubble: Bubble, byPlayer: boolean)
	if not bubble.alive then
		return
	end
	bubble.alive = false

	local idx = table.find(self._bubbles, bubble)
	if idx then
		table.remove(self._bubbles, idx)
	end

	local part = bubble.model.PrimaryPart or bubble.model:FindFirstChildWhichIsA("BasePart")

	if not part then
		bubble.model:Destroy()
		if byPlayer then
			self:_reduceTimer()
		end
		return
	end

	-- Simple tween animations for physical feedback (pop scale and transparency)
	-- paired with Debris' queue system ensures that pop visuals play smoothly
	-- without stalling the game thread with blocking waits.
	local tween = TweenService:Create(part, TweenInfo.new(Config.BubblePopDuration, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = part.Size * Config.BubblePopScale,
		Transparency = 1,
	})
	tween:Play()
	Debris:AddItem(bubble.model, Config.BubblePopDuration + 0.05)

	if byPlayer then
		self:_reduceTimer()
	end
end

--[[
	Reduces the opening countdown timer when a player successfully clicks a bubble.
	The Config.TimerFloor introduces a design boundary: players cannot skip the opening
	sequence completely through spamming clicks. Once the timer descends past this floor,
	click gains are applied directly to the final remaining time so it can finish naturally.
]]
function Workbench:_reduceTimer()
	if self._timer > Config.TimerFloor then
		self._timer = math.max(Config.TimerFloor, self._timer - Config.BubbleClickReduction)
	else
		self._timer = math.max(0, self._timer - Config.BubbleClickReduction)
	end
end

function Workbench:_clearBubbles()
	for i = #self._bubbles, 1, -1 do
		self:_popBubble(self._bubbles[i], false)
	end
end

--[[
	Transitions the workbench state to Opened, starting the reveal animations 
	and physical reward generation. 
	
	A fallback timer (Config.RewardLifetime) is scheduled here: if the player neglects 
	their reward, the workbench resets itself to Idle rather than remaining locked in 
	limbo, preventing griefing/stalling mechanics in the server.
]]
function Workbench:_enterOpened()
	if self._state ~= State.Opening then
		return
	end

	self._state = State.Opened

	if self._hbConn then
		self._hbConn:Disconnect()
		self._hbConn = nil
	end

	self:_clearBubbles()
	self:_burstParticles(false)
	self.timerGui.Visible = false
	self.FinishGui.Visible = true

	self:_animateBoxOpen(self._box, function()
		self:_spawnReward()
		if self._box then
			self._box:Destroy()
			self._box = nil
		end
	end)

	if self._placer then
		recordBoxOpened(self._placer)
	end

	task.delay(Config.RewardLifetime, function()
		if self._state == State.Opened then
			self.FinishGui.Visible = false
			self._state = State.Idle
		end
	end)
end

function Workbench:_animateBoxOpen(box: Model?, onDone: () -> ())
	if not box then
		return onDone()
	end

	local part = box.PrimaryPart
	if not part then
		return onDone()
	end

	local tween = TweenService:Create(part, TweenInfo.new(Config.BoxOpenAnimTime, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = part.Size * 1.6,
		Transparency = 1,
	})

	tween:Play()
	tween.Completed:Once(onDone)
end

--[[
	Spawns a random reward from the defined storage pool.
	The physical interaction properties (such as physical constraints, 
	limiting ranges, and client-drag responses) match the behavior of the boxes.
	This reuses core physics algorithms to keep UX consistency across drag objects.
]]
function Workbench:_spawnReward()
	if #rewardPool == 0 then
		return
	end

	local chosen = rewardPool[math.random(1, #rewardPool)]
	local reward = chosen:Clone()

	local spawnCF = self.PosBox.WorldCFrame * CFrame.new(0, 2, 0)
	reward:PivotTo(spawnCF)
	reward.Parent = workspace

	CollectionService:AddTag(reward, "Reward")

	-- Correct and non-deprecated property initialization pattern:
	-- Instantiating parent-less, setting properties, and then parenting.
	local dd = Instance.new("DragDetector")
	dd.ResponseStyle = Enum.DragDetectorResponseStyle.Physical
	dd.DragStyle = Enum.DragDetectorDragStyle.BestForDevice
	dd.MaxForce = Config.RewardDragForce
	dd.MaxTorque = Config.RewardDragForce
	dd.MaxActivationDistance = 20
	dd.ApplyAtCenterOfMass = true

	dd:AddConstraintFunction(1, function(proposed: CFrame): CFrame
		local newPos = proposed.Position
		local floorY = spawnAnchor.Position.Y

		if newPos.Y < floorY then
			newPos = Vector3.new(newPos.X, floorY, newPos.Z)
		end

		return CFrame.new(newPos) * proposed.Rotation + Vector3.new(0, Config.DragYOffset, 0)
	end)

	dd.DragContinue:Connect(function(player: Player)
		local char = player.Character
		if not char then
			return
		end

		local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local primary = reward.PrimaryPart
		if not hrp or not primary then
			return
		end

		if (primary.Position - hrp.Position).Magnitude > Config.DragDistanceLimit then
			primary.AssemblyLinearVelocity = Vector3.zero
			primary.AssemblyAngularVelocity = Vector3.zero
			dd.Enabled = false
			task.defer(function()
				dd.Enabled = true
			end)
		end
	end)

	dd.DragStart:Connect(function(player: Player)
		reward:SetAttribute("PlacedBy", player.UserId)

		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?

		if hrp then
			dd.ReferenceInstance = hrp
			local limit = Config.DragDistanceLimit - 10

			dd.MinDragTranslation = Vector3.new(-limit, -40, -limit)
			dd.MaxDragTranslation = Vector3.new(limit, 40, limit)
		end
	end)

	dd.DragEnd:Once(function()
		reward.Parent = workspace

		dd.ReferenceInstance = nil
		dd.MinDragTranslation = Vector3.new(-math.huge, -math.huge, -math.huge)
		dd.MaxDragTranslation = Vector3.new(math.huge, math.huge, math.huge)

		local primary = reward.PrimaryPart
		if primary then
			primary.AssemblyLinearVelocity = Vector3.zero
			primary.AssemblyAngularVelocity = Vector3.zero
		end

		if self._state == State.Opened then
			self.FinishGui.Visible = false
			self._state = State.Idle
		end
	end)

	dd.Parent = reward

	task.delay(Config.RewardLifetime, function()
		if reward and reward.Parent then
			reward:Destroy()
		end
	end)
end

function Workbench:_burstParticles(visible: boolean)
	for _, desc in ipairs(self.ParticlesOpen:GetDescendants()) do
		if desc:IsA("ParticleEmitter") then
			desc.Enabled = visible
		end
	end
end

--[[
	Systematically destroys the Workbench instance.
	Clears local frames, stops active RunService heartbeats, disconnects physical events, 
	and pops surviving bubble models. Crucial to ensure zero-dangling closure allocations
	and prevent garbage collector leaks across dynamically loading maps.
]]
function Workbench:Destroy()
	if self._hbConn then
		self._hbConn:Disconnect()
		self._hbConn = nil
	end
	for _, conn in ipairs(self._conns) do
		conn:Disconnect()
	end
	table.clear(self._conns)
	self:_clearBubbles()
end

local benches = {}

for _, model in ipairs(WorkbenchFolder:GetChildren()) do
	if model:IsA("Model") then
		table.insert(benches, Workbench.new(model))
	end
end

WorkbenchFolder.ChildAdded:Connect(function(child)
	if child:IsA("Model") then
		table.insert(benches, Workbench.new(child))
	end
end)

--[[
	Critical shutdown handling:
	We capture game closure to force-save dirty player states.
	We also systematically iterate through and clean up active Workbench states,
	disconnecting active bindings and safely releasing engine allocations before 
	the thread shuts down completely.
]]
game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(saveSession, player)
	end

	for _, bench in ipairs(benches) do
		bench:Destroy()
	end
	table.clear(benches)

	task.wait(3)
end)
