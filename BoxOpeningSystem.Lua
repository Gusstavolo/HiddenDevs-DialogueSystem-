-- Full box-opening system in a single server script.
-- A box is dragged onto the workbench, a countdown starts,
-- bubbles float up and can be clicked to speed up the timer,
-- and when it hits zero the box pops open and drops a reward.
--
-- Concepts used: metatables, CFrame math, RunService.Heartbeat,
-- TweenService, DataStoreService, CollectionService, DragDetector,
-- OverlapParams, polar coordinate spawning, state machine pattern.

-- ─────────────────────────────────────────────────────────────
-- SERVICES
-- ─────────────────────────────────────────────────────────────

local Players           = game:GetService("Players")              -- player join/leave and character access
local RunService        = game:GetService("RunService")           -- Heartbeat for frame-by-frame updates
local TweenService      = game:GetService("TweenService")         -- smooth animations on parts and GUIs
local Debris            = game:GetService("Debris")               -- auto-destroys instances after a delay
local CollectionService = game:GetService("CollectionService")    -- tags models so any script can identify them
local DataStoreService  = game:GetService("DataStoreService")     -- persistent storage across sessions

-- ─────────────────────────────────────────────────────────────
-- ASSETS
-- ─────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets         = ReplicatedStorage:WaitForChild("Assets")               -- root assets folder
local boxTemplate    = Assets:WaitForChild("Box"):WaitForChild("Box")         -- Model cloned for each box spawn
local popTemplate    = Assets:WaitForChild("Pops"):WaitForChild("PopTime")    -- Model cloned for each bubble
local rewardFolder   = Assets:WaitForChild("Rewards")


-- This avoids a repeated engine call and keeps the table stable.
local rewardPool = rewardFolder:GetChildren()

local WorkbenchFolder = workspace:WaitForChild("Workbench")   -- folder that holds all workbench models
local BoxSpawnModel   = workspace:WaitForChild("BoxSpawn")    -- where the draggable box first appears
local spawnAnchor     = BoxSpawnModel:WaitForChild("Pos")     -- Part whose CFrame is the box spawn point

-- ─────────────────────────────────────────────────────────────
-- CONFIG
-- Every number that affects gameplay is here so tuning is easy.
-- ─────────────────────────────────────────────────────────────

local Config = {}

-- Box spawn / drag
Config.DragMaxForce        = 50000   -- max force the DragDetector applies while the player drags
Config.DragMaxTorque       = 50000   -- max torque so the box can spin while being carried
Config.DragActivationDist  = 15      -- studs the player must be within to start a drag
Config.DragDistanceLimit   = 20      -- studs; drag is cut if the player goes further than this
Config.DragYOffset         = 5       -- extra Y lift applied to the box while it is being dragged

-- Workbench opening timer
Config.OpenDuration        = 18.0    -- full countdown length in seconds
Config.TimerFloor          = 4.0     -- timer can never drop below this value no matter how many bubbles are popped
Config.TimerUpdateRate     = 0.05    -- how often the label refreshes (seconds); lower = smoother but more overhead

-- Bubbles
Config.BubbleInterval      = 1.8     -- seconds between each new bubble spawn
Config.BubbleMinLife       = 3.0     -- minimum seconds a bubble lives before auto-popping
Config.BubbleMaxLife       = 6.5     -- maximum seconds before it pops on its own
Config.BubbleFloatSpeed    = 2.2     -- studs per second the bubble rises
Config.BubbleSpawnRadius   = 5.0     -- horizontal radius around the workbench slot where bubbles appear
Config.BubbleSpawnYMin     = 2.0     -- minimum height offset above the slot
Config.BubbleSpawnYMax     = 3.5     -- maximum height offset above the slot
Config.BubbleWobbleAmp     = 0.18    -- how far left/right the wobble sways each cycle
Config.BubbleWobbleSpeed   = 2.5     -- how fast the wobble cycles (radians per second)
Config.BubbleClickReduction = 2.5    -- seconds removed from the timer when a player clicks a bubble
Config.BubblePopScale      = 2.8     -- how large the bubble grows in the pop animation
Config.BubblePopDuration   = 0.18    -- seconds the pop tween takes

-- Reward
Config.RewardDragForce     = 40000   -- MaxForce on the reward item's DragDetector
Config.RewardLifetime      = 30      -- seconds before an unclaimed reward despawns automatically
Config.BoxOpenAnimTime     = 0.55    -- seconds the box scale/fade animation takes

-- DataStore
Config.DataStoreName       = "WorkbenchBoxCount_v1"

-- ─────────────────────────────────────────────────────────────
-- STATE ENUM
-- Using a plain table of strings instead of numbers makes
-- print/warn output readable without a reverse-lookup table.
-- ─────────────────────────────────────────────────────────────

local State = {
	Idle    = "Idle",      -- workbench is empty and waiting for a box
	Opening = "Opening",   -- countdown is running and bubbles are active
	Opened  = "Opened",    -- box has opened; reward is sitting on the bench
}

-- ─────────────────────────────────────────────────────────────
-- DATA  (session registry + DataStore wrapper)
-- ─────────────────────────────────────────────────────────────

local BoxStore = DataStoreService:GetDataStore(Config.DataStoreName)   -- the actual persistent store

local sessions = {}   -- [userId] = { boxesOpened = number, dirty = boolean }

-- Loads saved data for a player when they join; creates a fresh session if none exists.
local function loadSession(player: Player)
	local key = "player_" .. tostring(player.UserId)

	local ok, stored = pcall(function()
		return BoxStore:GetAsync(key)
	end)

	local count = 0
	if ok and stored and stored.boxesOpened then
		count = stored.boxesOpened
	end

	sessions[player.UserId] = {
		key         = key,
		boxesOpened = count,
		dirty       = false,
	}

	-- Create the leaderstats folder that Roblox uses to display stats on the leaderboard.
	
	local leaderstats = Instance.new("Folder")
	leaderstats.Name   = "leaderstats"
	leaderstats.Parent = player


	local boxesValue = Instance.new("IntValue")
	boxesValue.Name   = "Boxes Opened"   -- this is what players see in the leaderboard tab
	boxesValue.Value  = count            -- pre-fill with the saved value so it's correct on join
	boxesValue.Parent = leaderstats
end

local function recordBoxOpened(player: Player)
	local session = sessions[player.UserId]
	if not session then return end

	session.boxesOpened += 1
	session.dirty        = true

	
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		local boxesValue = leaderstats:FindFirstChild("Boxes Opened")
		if boxesValue then
			boxesValue.Value = session.boxesOpened   -- update the visible number immediately
		end
	end

	pcall(function()
		BoxStore:UpdateAsync(session.key, function()
			return { boxesOpened = session.boxesOpened }
		end)
	end)

	session.dirty = false
end

-- Saves a player's session to the DataStore, then removes it from memory.
local function saveSession(player: Player)
	local session = sessions[player.UserId]   -- look up their session
	if not session then return end             -- nothing to save if the session never loaded

	if session.dirty then   -- only hit the network if something actually changed
		pcall(function()
			BoxStore:UpdateAsync(session.key, function()
				return { boxesOpened = session.boxesOpened }   -- always write the full snapshot
			end)
		end)
	end

	sessions[player.UserId] = nil   -- free the memory regardless of whether the save succeeded
end


-- Hook DataStore lifecycle into player events.
Players.PlayerAdded:Connect(function(player)
	task.spawn(loadSession, player)   -- load in a separate thread so we don't block the event
end)

Players.PlayerRemoving:Connect(function(player)
	saveSession(player)   -- save synchronously on the way out before the player object is cleaned up
end)

for _, p in ipairs(Players:GetPlayers()) do   -- handle anyone already in the server at startup
	task.spawn(loadSession, p)
end

-- ─────────────────────────────────────────────────────────────
-- BOX SPAWN
-- ─────────────────────────────────────────────────────────────

-- Clones the box template, places it at the anchor, and wires up
-- a full DragDetector with distance limiting and a PlacedBy attribute.
local function spawnBox()
	local box = boxTemplate:Clone()            -- duplicate the template model
	box.Parent = BoxSpawnModel                 -- nest it in the spawn folder
	box:PivotTo(spawnAnchor.WorldCFrame)       -- snap to the anchor's world position and rotation

	CollectionService:AddTag(box, "Box")       -- tag it so workbench detection can identify it

	local dd = Instance.new("DragDetector")                             -- create the drag component
	dd.ResponseStyle         = Enum.DragDetectorResponseStyle.Physical  -- physics-driven movement
	dd.DragStyle             = Enum.DragDetectorDragStyle.BestForDevice -- adapts to mouse or touch
	dd.MaxForce              = Config.DragMaxForce                      -- cap the applied force
	dd.MaxTorque             = Config.DragMaxTorque                     -- cap the applied torque
	dd.MaxActivationDistance = Config.DragActivationDist                -- proximity requirement

	-- Constraint: lift the box above the cursor plane while dragging so it clears the floor.
	dd:AddConstraintFunction(1, function(proposed: CFrame): CFrame
		return proposed + Vector3.new(0, Config.DragYOffset, 0)   -- shift the proposed CFrame upward
	end)

	-- Every frame while dragging: cut the drag if the player strays too far.
	dd.DragContinue:Connect(function(player: Player)
		local char = player.Character                              -- the player's character model
		if not char then return end

		local hrp = char:FindFirstChild("HumanoidRootPart")       -- position reference
		if not hrp then return end

		local dist = (box.PrimaryPart.Position - hrp.Position).Magnitude   -- current separation
		
		
		
		if dist > Config.DragDistanceLimit then   -- player has gone too far
			dd.Enabled = false                    -- stop the drag immediately
			task.wait()                           -- yield one frame so the engine processes the change
			dd.Enabled = true                     -- re-enable for future drags
		end
	end)

	dd.DragStart:Connect(function(player: Player)
		box:SetAttribute("PlacedBy", player.Name)   -- write a string attribute onto the model
	end)
	dd.DragEnd:Once(function()
		box.Parent = workspace 
	end)

	dd.Parent = box   -- attach the detector to the box model

	return box   -- return the instance in case the caller needs a reference
end

do
	spawnBox()   -- spawn the first box when the script starts

	-- Whenever a child is removed from the spawn folder, check if any boxes remain
	
	BoxSpawnModel.ChildRemoved:Connect(function()
		local hasBox = false
		for _, child in ipairs(BoxSpawnModel:GetChildren()) do
			if CollectionService:HasTag(child, "Box") then
				hasBox = true
				break
			end
		end

		if not hasBox then   -- no boxes left
			spawnBox()       -- create a new one
		end
	end)
end

-- ─────────────────────────────────────────────────────────────
-- WORKBENCH CLASS
-- ─────────────────────────────────────────────────────────────

local Workbench   = {}
Workbench.__index = Workbench

function Workbench.new(model: Model)
	local self = setmetatable({}, Workbench)   -- new instance backed by the Workbench prototype

	-- ── Model references ──────────────────────────────────────
	self.Model    = model
	self.PosBox   = model:WaitForChild("PosBox")    -- Attachment: the slot where the box snaps
	self.ZoneBox  = model:WaitForChild("ZoneBox")   -- BasePart: the invisible trigger zone

	self.gui          = model:WaitForChild("Gui")
	self.timerGui     = self.gui:WaitForChild("Timer")
	self.TimerLabel   = self.timerGui:WaitForChild("Text")   -- TextLabel that shows the countdown
	self.FinishGui    = self.gui:WaitForChild("Finish")      -- Frame/Label shown when the box opens

	self.ParticlesOpen = model:WaitForChild("Particles"):WaitForChild("Open")  -- particle folder

	-- ── Runtime state ─────────────────────────────────────────
	self._state         = State.Idle   -- always starts waiting for a box
	self._box           = nil          -- the Model currently on the bench (nil when idle)
	self._placer        = nil          -- Player who dragged the box here
	self._timer         = 0            -- seconds left on the countdown
	self._timerAcc      = 0            -- accumulator for the label refresh throttle
	self._spawnAcc      = 0            -- accumulator for bubble spawn timing
	self._bubbles       = {}           -- list of active bubble data tables
	self._hbConn        = nil          -- the single Heartbeat connection (reconnected per Opening)
	self._conns         = {}           -- all other RBXScriptConnections for this bench

	-- Initial GUI state
	self.FinishGui.Visible = false
	self.TimerLabel.Text   = ""        -- nothing to show while idle

	self:_listenForBox()   -- begin watching the zone for an incoming box

	return self
end

-- ─────────────────────────────────────────────────────────────
-- STATE: Idle helpers
-- ─────────────────────────────────────────────────────────────

-- Connects ZoneBox.Touched so we know when a box enters the trigger area.
function Workbench:_listenForBox()

	
	local debounce = {}

	local conn = self.ZoneBox.Touched:Connect(function(hit)
		if self._state ~= State.Idle then return end   -- only accept boxes when idle

		local parent = hit.Parent
		if not parent or not CollectionService:HasTag(parent, "Box") then return end   -- ignore non-boxes

		if debounce[parent] then return end   -- this model is already queued for processing
		debounce[parent] = true               -- lock it immediately, before any yield

		task.defer(function()           -- defer one frame so the physics position settles
			self:_enterOpening(parent)  -- hand off to the Opening state
			debounce[parent] = nil      -- release the lock after the state has been entered
		end)
	end)

	table.insert(self._conns, conn)   -- track so Destroy() can clean up
end

-- ─────────────────────────────────────────────────────────────
-- STATE: Opening
-- ─────────────────────────────────────────────────────────────

function Workbench:_enterOpening(box: Model)
	if self._state ~= State.Idle then return end   -- double-entry guard

	self._state    = State.Opening          -- flip the state flag
	self._box      = box                    -- store which box we're working on
	self._timer    = Config.OpenDuration    -- reset countdown to full length
	self._timerAcc = 0
	self._spawnAcc = 0
	table.clear(self._bubbles)              -- clear leftover bubble data from a previous round

	-- Disable the DragDetector so the player can't pull the box back mid-countdown.
	local dd = box:FindFirstChildOfClass("DragDetector")
	if dd then dd.Enabled = false end

	-- Stop all physics on the box so it doesn't slide off the workbench.
	local primary = box.PrimaryPart
	primary.AssemblyLinearVelocity  = Vector3.zero   -- kill linear velocity
	primary.AssemblyAngularVelocity = Vector3.zero   -- kill angular velocity
	box:PivotTo(self.PosBox.WorldCFrame)             -- snap exactly to the slot CFrame
	
	task.delay(.2,function()
		if primary and primary.Parent then
			primary.Anchored = true
		end
	end)

	-- Read the PlacedBy attribute the DragDetector stamped when the player grabbed the box.
	local placerName = box:GetAttribute("PlacedBy")
	self._placer = if placerName then Players:FindFirstChild(placerName) else nil

	-- Make the timer visible.
	self.timerGui.Visible = true
	self:_burstParticles(true)
	self.TimerLabel.Text = tostring(math.ceil(self._timer))

	
	-- the countdown, the label refresh and the bubble spawn/update loop.
	self._hbConn = RunService.Heartbeat:Connect(function(dt)
		if self._state ~= State.Opening then return end   -- exit as soon as the state changes

		self:_tickTimer(dt)     -- advance and display the countdown
		self:_tickBubbles(dt)   -- move existing bubbles and maybe spawn a new one
	end)
end

-- Advances the countdown each frame and triggers the Opened state at zero.
function Workbench:_tickTimer(dt: number)
	self._timer    -= dt     -- subtract elapsed time
	self._timerAcc += dt     -- accumulate for throttled label update

	if self._timerAcc >= Config.TimerUpdateRate then   -- only touch the GUI every TimerUpdateRate seconds
		self._timerAcc = 0
		local display = math.max(0, math.ceil(self._timer))   -- round up so we never flash a premature zero
		self.TimerLabel.Text = tostring(display)              -- push the number to the screen
	end

	if self._timer <= 0 then    -- countdown finished
		self:_enterOpened()     -- move to the next state
	end
end

-- ─────────────────────────────────────────────────────────────
-- BUBBLES
-- All bubble logic lives on the Workbench instance so it can
-- read self.PosBox and call self:_reduceTimer() directly
-- ────────────────────────────────────────────────────────────

-- Called every frame while Opening. Moves existing bubbles and handles spawning
function Workbench:_tickBubbles(dt: number)
	self._spawnAcc += dt   -- track time since the last bubble was spawned

	if self._spawnAcc >= Config.BubbleInterval then   -- enough time has passed for a new bubble
		self._spawnAcc = 0                             -- reset the spawn accumulator
		self:_spawnBubble()                            -- create one
	end


	
	if #self._bubbles == 0 then return end

	-- Update every live bubble this frame (backwards loop so removal is safe).
	for i = #self._bubbles, 1, -1 do
		local b = self._bubbles[i]

		if not b.alive then                    -- already popped this frame
			table.remove(self._bubbles, i)     -- clean up the dead entry
			continue
		end

		b.age     += dt                               -- accumulate lifetime
		b.wobbleT += dt * Config.BubbleWobbleSpeed   -- advance the wobble phase

		if b.age >= b.lifespan then          -- exceeded its natural lifespan
			self:_popBubble(b, false)        -- auto-pop without crediting a player
			table.remove(self._bubbles, i)
			continue
		end

		-- Float upward with a sinusoidal side-to-side wobble using CFrame arithmetic.
		-- Splitting into X/Z wobble components gives a gentle figure-eight drift.
		local cf      = b.model:GetPivot()                             -- current world CFrame

		local wobbleX = math.sin(b.wobbleT) * Config.BubbleWobbleAmp  -- left-right sway
		local wobbleZ = math.cos(b.wobbleT) * Config.BubbleWobbleAmp  -- forward-back sway

		local delta = Vector3.new(                      -- displacement vector for this frame
			wobbleX,                                    -- horizontal drift X
			Config.BubbleFloatSpeed * dt,               -- upward movement scaled by delta time
			wobbleZ                                     -- horizontal drift Z
		)

		b.model:PivotTo(cf + delta)   -- apply the movement; CFrame + Vector3 shifts the position
	end
end

-- Spawns one bubble at a random position around the workbench slot.
function Workbench:_spawnBubble()
	-- Convert a random angle and distance into a world position using polar coordinates.
	-- This guarantees even distribution in a circle rather than a square region.
	local angle  = math.random() * math.pi * 2                                                     -- full 360° in radians
	local radius = math.sqrt(math.random()) * Config.BubbleSpawnRadius                             -- sqrt gives uniform disk distribution
	local height = Config.BubbleSpawnYMin + math.random() * (Config.BubbleSpawnYMax - Config.BubbleSpawnYMin)  -- random height in range

	local origin   = self.PosBox.WorldPosition   -- center of the spawn disk
	local spawnPos = origin + Vector3.new(        -- offset from the center using polar → Cartesian
		math.cos(angle) * radius,                 -- X component
		height,                                   -- Y component (height above the slot)
		math.sin(angle) * radius                  -- Z component
	)

	local model = popTemplate:Clone()            -- clone the bubble template
	model:PivotTo(CFrame.new(spawnPos))          -- place it at the calculated position
	model.Parent = workspace                     -- add to the world so it renders and is clickable

	-- Give each bubble a random lifespan so they don't all disappear at once.
	local lifespan = Config.BubbleMinLife + math.random() * (Config.BubbleMaxLife - Config.BubbleMinLife)

	local bubble = {
		model    = model,                          -- the cloned Model instance
		age      = 0,                              -- seconds this bubble has been alive
		lifespan = lifespan,                       -- when it auto-pops
		wobbleT  = math.random() * math.pi * 2,   -- random phase so bubbles don't all sway together
		alive    = true,                           -- set to false once popped to skip future updates
	}

	-- Wire the ClickDetector inside the model so players can pop bubbles manually.
	local cd = model:FindFirstChildOfClass("ClickDetector")
	if cd then
		cd.MouseClick:Connect(function(_player: Player)   -- fires on the server when a player clicks
			if not bubble.alive then return end           -- ignore clicks on already-popping bubbles
			self:_popBubble(bubble, true)                 -- true = player triggered the pop
		end)
	end

	table.insert(self._bubbles, bubble)   -- add to the active list so _tickBubbles updates it
end

-- Plays the pop animation and notifies the timer if it was a player click.
function Workbench:_popBubble(bubble, byPlayer: boolean)
	if not bubble.alive then return end   -- guard: prevent double-pops on the same bubble
	bubble.alive = false                  -- mark dead immediately before any yields

	local part = bubble.model.PrimaryPart or bubble.model:FindFirstChildOfClass("BasePart")

	if part then
		-- Scale up and fade out using TweenService.
		-- EasingStyle.Back makes the scale overshoot slightly before snapping — feels like a real pop.
		local info = TweenInfo.new(
			Config.BubblePopDuration,
			Enum.EasingStyle.Back,
			Enum.EasingDirection.Out
		)

		local tween = TweenService:Create(part, info, {
			Size         = part.Size * Config.BubblePopScale,   -- grow to the pop size
			Transparency = 1,                                   -- fade to fully transparent
		})

		tween:Play()   -- start the animation

		-- Schedule the model's destruction just after the tween ends.
		Debris:AddItem(bubble.model, Config.BubblePopDuration + 0.05)
	else
		bubble.model:Destroy()   -- no animatable part found; destroy immediately
	end

	if byPlayer then
		self:_reduceTimer()   -- player earned a speed boost
	end
end

-- Subtracts BubbleClickReduction from the timer, clamped to the floor.
function Workbench:_reduceTimer()
	self._timer = math.max(
		Config.TimerFloor,                             -- never go below the floor
		self._timer - Config.BubbleClickReduction      -- subtract the bonus
	)
end

-- Force-pops every remaining bubble without triggering the player callback.
-- Called during cleanup so nothing keeps floating after the state changes.
function Workbench:_clearBubbles()
	for i = #self._bubbles, 1, -1 do
		self:_popBubble(self._bubbles[i], false)   -- pop without granting timer reduction
		table.remove(self._bubbles, i)
	end
end

-- ─────────────────────────────────────────────────────────────
-- STATE: Opened
-- ─────────────────────────────────────────────────────────────

function Workbench:_enterOpened()
	if self._state ~= State.Opening then return end   -- guard against re-entry

	self._state = State.Opened   -- flip state before anything async happens

	if self._hbConn then          -- disconnect the Heartbeat so nothing keeps ticking
		self._hbConn:Disconnect()
		self._hbConn = nil
	end

	self:_clearBubbles()                              -- pop all remaining bubbles
	self:_burstParticles(false)
	self.timerGui.Visible  = false                    -- hide the timer BillboardGui
	self.FinishGui.Visible = true                     -- show the "opened!" banner

	self:_animateBoxOpen(self._box, function()        -- play the box-open animation
		self:_spawnReward()                           -- drop the reward after the animation
		if self._box then
			self._box:Destroy()                       -- remove the opened box from the world
			self._box = nil
		end
	end)

	if self._placer then
		recordBoxOpened(self._placer)   -- write to the DataStore for the player who placed the box
	end

	-- After RewardLifetime, return to Idle whether or not the reward was collected.
	task.delay(Config.RewardLifetime, function()
		if self._state == State.Opened then
			self.FinishGui.Visible = false
			self._state = State.Idle
		end
	end)
end

-- Scales the box up and fades it out, then calls onDone when the tween finishes.
function Workbench:_animateBoxOpen(box: Model, onDone: () -> ())
	if not box then onDone() return end   -- box already gone, skip straight to the callback

	local part = box.PrimaryPart
	if not part then onDone() return end  -- no primary part to animate

	local info = TweenInfo.new(
		Config.BoxOpenAnimTime,
		Enum.EasingStyle.Back,            -- overshoot makes it feel like the box is bursting open
		Enum.EasingDirection.Out
	)

	local tween = TweenService:Create(part, info, {
		Size         = part.Size * 1.6,   -- grow to 160% of the original size
		Transparency = 1,                 -- fade out completely
	})

	tween:Play()

	tween.Completed:Once(function()   -- Once fires exactly one time and auto-disconnects
		onDone()
	end)
end

-- Picks a random reward from the pre-cached pool, places it above the slot, and adds a DragDetector
function Workbench:_spawnReward()
	
	if #rewardPool == 0 then return end   -- nothing to give

	local chosen = rewardPool[math.random(1, #rewardPool)]   -- pick one at random
	local reward = chosen:Clone()                             -- clone it so the original stays intact

	-- Place the reward slightly above the slot so it doesn't clip into the workbench surface
	local spawnCF = self.PosBox.WorldCFrame * CFrame.new(0, 2, 0)   -- 2 studs above the slot
	reward:PivotTo(spawnCF)
	reward.Parent = workspace

	CollectionService:AddTag(reward, "Reward")   -- tag it so any script can identify reward items

	-- Give the reward its own DragDetector so the player can pick it up and carry it away
	local dd = Instance.new("DragDetector")
	dd.ResponseStyle         = Enum.DragDetectorResponseStyle.Physical
	dd.DragStyle             = Enum.DragDetectorDragStyle.BestForDevice
	dd.MaxForce              = Config.RewardDragForce
	dd.MaxTorque             = Config.RewardDragForce
	dd.MaxActivationDistance = 20           -- player must be within 20 studs to start dragging
	dd.Parent                = reward       -- attach to the reward model

	-- When the player drops the reward (drag ends), free the bench for the next box.
	dd.DragEnd:Connect(function()
		if self._state == State.Opened then
			self.FinishGui.Visible = false
			self._state = State.Idle         -- bench is free again
		end
	end)

	-- Auto-despawn if no one picks it up within the lifetime window.
	task.delay(Config.RewardLifetime, function()
		if reward and reward.Parent then
			reward:Destroy()   -- remove it from the world
		end
	end)
end

-- Enables or disables all ParticleEmitters in the Open folder.
function Workbench:_burstParticles(visible)
	for _, desc in ipairs(self.ParticlesOpen:GetDescendants()) do
		if desc:IsA("ParticleEmitter") then
			desc.Enabled = visible
		end
	end
end

-- Disconnects all connections owned by this workbench instance.
-- Call this if you ever remove a workbench from the world at runtime.
function Workbench:Destroy()
	if self._hbConn then
		self._hbConn:Disconnect()
	end

	for _, conn in ipairs(self._conns) do
		conn:Disconnect()
	end

	table.clear(self._conns)
	self:_clearBubbles()
end

-- ─────────────────────────────────────────────────────────────
-- BOOT  —  create one Workbench instance per model in the folder
-- ─────────────────────────────────────────────────────────────

local benches = {}   -- keep strong references so the instances are never garbage-collected

for _, model in ipairs(WorkbenchFolder:GetChildren()) do   -- iterate every child in the folder
	if model:IsA("Model") then                             -- skip any non-Model children
		local bench = Workbench.new(model)                 -- build the state machine for this bench
		table.insert(benches, bench)                       -- store the reference
	end
end

-- If workbenches are added to the folder after the script starts, handle them automatically.
WorkbenchFolder.ChildAdded:Connect(function(child)
	if child:IsA("Model") then
		local bench = Workbench.new(child)
		table.insert(benches, bench)
	end
end)
