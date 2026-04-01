

local Players = game:GetService("Players") -- gets the Players service to manage player objects
local RunService = game:GetService("RunService") -- gets the RunService to check game loops and ticks
local TweenService = game:GetService("TweenService") -- gets the TweenService for smooth animations
local Debris = game:GetService("Debris") -- gets the Debris service to automatically remove objects after a delay
local CollectionService = game:GetService("CollectionService") -- gets the CollectionService to group similar objects together
local DataStoreService = game:GetService("DataStoreService") -- gets the DataStoreService for saving player data
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- gets the ReplicatedStorage service for shared game data

local Assets = ReplicatedStorage:WaitForChild("Assets") -- waits for and gets the Assets folder
local boxTemplate = Assets:WaitForChild("Box"):WaitForChild("Box") :: Model -- gets the main box model we copy every time it spawns
local popTemplate = Assets:WaitForChild("Pops"):WaitForChild("PopTime") :: Model -- gets the bubble effect we copy
local rewardFolder = Assets:WaitForChild("Rewards") -- waits for and gets the Rewards folder
local rewardPool = rewardFolder:GetChildren() -- creates a list of all the rewards inside the folder

local WorkbenchFolder = workspace:WaitForChild("Workbench") -- finds the folder holding all workbench models in the map
local BoxSpawnModel = workspace:WaitForChild("BoxSpawn") -- finds the area where the box first appears
local spawnAnchor = BoxSpawnModel:WaitForChild("Pos") :: BasePart -- gets the exact starting spot for the new box

type Session = { -- creates a custom type for player sessions
	key: string,
	boxesOpened: number,
	dirty: boolean
}

type Bubble = { -- creates a custom type for bubbles
	model: Model,
	alive: boolean
}

local Config = { -- creates a table to hold all the game settings
	DragMaxForce = 50000, -- sets how strong the dragging is
	DragMaxTorque = 50000, -- sets how much it can spin while dragging
	DragActivationDist = 15, -- sets how close the player needs to be to grab it
	DragDistanceLimit = 20, -- sets distance limit to drop the box if walked too far away
	DragYOffset = 5, -- sets how high the box lifts off the floor while dragging

	OpenDuration = 18.0, -- sets the normal time it takes to open a box
	TimerFloor = 4.0, -- sets the minimum time limit (can't open instantly)
	TimerUpdateRate = 0.05, -- sets how fast the text timer updates on screen

	BubbleInterval = 1.8, -- sets the time before a new bubble spawns
	BubbleMinLife = 3.0, -- sets the minimum time before a bubble pops itself
	BubbleMaxLife = 6.5, -- sets the maximum time before a bubble pops itself
	BubbleFloatSpeed = 2.2, -- sets how fast the bubble floats upward
	BubbleSpawnRadius = 5.0, -- sets how far from the center bubbles can spawn
	BubbleSpawnYMin = 2.0, -- sets the lowest spawn point for a bubble
	BubbleSpawnYMax = 3.5, -- sets the highest spawn point for a bubble
	BubbleWobbleAmp = 0.18, -- sets how much the bubble shakes side to side
	BubbleClickReduction = 2.5, -- sets how much time is shaved off when clicking a bubble
	BubblePopScale = 2.8, -- sets how big the bubble gets right before popping
	BubblePopDuration = 0.18, -- sets how fast the pop animation plays

	RewardDragForce = 40000, -- sets the strength needed to grab the reward item
	RewardLifetime = 30, -- sets how long the reward stays before deleting itself
	BoxOpenAnimTime = 0.55, -- sets the time it takes for the box to disappear when opened

	DataStoreName = "WorkbenchBoxCount_v1", -- sets the name of the datastore save file
	DataStoreRetries = 3, -- sets the maximum number of attempts to save data
}

local State = { -- creates a table for workbench states
	Idle = "Idle", -- waiting for someone to put a box here
	Opening = "Opening", -- counting down and popping bubbles
	Opened = "Opened", -- box is open and reward is ready
}

local BoxStore = DataStoreService:GetDataStore(Config.DataStoreName) -- gets the datastore using the config name
local sessions: { [number]: Session } = {} -- creates an empty table to hold active player sessions

local function loadSession(player: Player) -- function to load player data when they join
	local key = "player_" .. tostring(player.UserId) -- creates a unique save key for this player
	local ok, stored = pcall(function() -- tries to get saved data without breaking the game
		return BoxStore:GetAsync(key) -- fetches data from the datastore
	end)

	local count = 0 -- sets default box count to 0
	if ok and type(stored) == "table" and stored.boxesOpened then -- checks if data was successfully loaded
		count = stored.boxesOpened -- sets count to the loaded value
	end

	sessions[player.UserId] = { -- stores the player session in the local table
		key = key,
		boxesOpened = count,
		dirty = false, -- flags as false since nothing changed yet
	}

	local leaderstats = Instance.new("Folder") -- creates a new folder for leaderstats
	leaderstats.Name = "leaderstats" -- names the folder leaderstats
	leaderstats.Parent = player -- parents the folder to the player

	local boxesValue = Instance.new("IntValue") -- creates an IntValue to show the score
	boxesValue.Name = "Boxes Opened" -- names the value
	boxesValue.Value = count -- sets the value to the loaded count
	boxesValue.Parent = leaderstats -- parents it to the leaderstats folder
end

local function recordBoxOpened(player: Player) -- function to update score when a box is opened
	local session = sessions[player.UserId] -- gets the player's session
	if not session then return end -- exits if no session is found

	session.boxesOpened += 1 -- adds 1 to the opened boxes count
	session.dirty = true -- flags as true so it saves later

	local leaderstats = player:FindFirstChild("leaderstats") -- finds the leaderstats folder
	if not leaderstats then return end -- exits if folder not found

	local boxesValue = leaderstats:FindFirstChild("Boxes Opened") :: IntValue? -- finds the score value
	if boxesValue then -- checks if value exists
		boxesValue.Value = session.boxesOpened -- updates the screen with the new score
	end
end

local function saveSession(player: Player) -- function to save player data
	local session = sessions[player.UserId] -- gets the player's session
	if not session or not session.dirty then return end -- exits if no session or if data didn't change

	local success = false -- flag to track if saving worked
	local errorMessage -- variable to hold potential errors

	for attempt = 1, Config.DataStoreRetries do -- tries to save multiple times in case of failure
		success, errorMessage = pcall(function() -- runs the save safely
			return BoxStore:UpdateAsync(session.key, function(oldValue: any) -- updates data in the datastore
				if type(oldValue) == "table" and (oldValue.boxesOpened or 0) > session.boxesOpened then -- checks if cloud data is better
					return nil -- cancels the save to prevent data loss
				end
				return { boxesOpened = session.boxesOpened } -- saves the new score
			end)
		end)

		if success then break end -- exits the loop if save was successful
		task.wait(2) -- waits 2 seconds before trying again
	end

	if not success then -- checks if it failed all attempts
		warn(`[DataStore] Failed to save data for {player.Name} after {Config.DataStoreRetries} attempts: {errorMessage}`) -- prints error warning
	end

	sessions[player.UserId] = nil -- clears the session from memory after saving
end

Players.PlayerAdded:Connect(function(player) task.spawn(loadSession, player) end) -- connects to when a player joins
Players.PlayerRemoving:Connect(saveSession) -- connects to when a player leaves
for _, p in ipairs(Players:GetPlayers()) do task.spawn(loadSession, p) end -- loads data for players already in game (Studio testing)

local function spawnBox() -- function to create a new draggable box
	local box = boxTemplate:Clone() -- clones the box template
	box.Parent = BoxSpawnModel -- parents the new box to the spawn area
	box:PivotTo(spawnAnchor.WorldCFrame) -- moves the box to the exact starting spot

	CollectionService:AddTag(box, "Box") -- tags the box so the game knows it's real

	local dd = Instance.new("DragDetector") -- creates a new DragDetector
	dd.ResponseStyle = Enum.DragDetectorResponseStyle.Physical -- sets response style to physical
	dd.DragStyle = Enum.DragDetectorDragStyle.BestForDevice -- sets drag style to best for device
	dd.MaxForce = Config.DragMaxForce -- applies the config max force
	dd.MaxTorque = Config.DragMaxTorque -- applies the config max torque
	dd.MaxActivationDistance = Config.DragActivationDist -- applies the config activation distance

	dd:AddConstraintFunction(1, function(proposed: CFrame): CFrame -- adds a constraint to lift the box while dragging
		return proposed + Vector3.new(0, Config.DragYOffset, 0) -- pushes the box up slightly
	end)

	dd.DragContinue:Connect(function(player: Player) -- connects to while the player is dragging
		local char = player.Character -- gets the player's character
		if not char then return end -- exits if player has no character

		local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart? -- finds the HumanoidRootPart
		local primary = box.PrimaryPart -- gets the primary part of the box
		if not hrp or not primary then return end -- exits if missing parts

		if (primary.Position - hrp.Position).Magnitude > Config.DragDistanceLimit then -- checks if player walked too far
			dd.Enabled = false -- disables the drag detector
			task.defer(function() dd.Enabled = true end) -- enables it again safely on the next frame
		end
	end)

	dd.DragStart:Connect(function(player: Player) -- connects to when the drag starts
		box:SetAttribute("PlacedBy", player.UserId) -- remembers the user ID of who grabbed it
	end)

	dd.DragEnd:Once(function() -- connects once to when the player lets go of the box
		box.Parent = workspace -- moves the box to the main workspace
		spawnBox() -- spawns a new box right away
	end)

	dd.Parent = box -- parents the drag detector to the box
	return box -- returns the created box
end

spawnBox() -- spawns the very first box when the game starts

local Workbench = {} -- creates an empty table to hold the Workbench class
Workbench.__index = Workbench -- sets the metatable index to enable object-oriented programming

function Workbench.new(model: Model) -- constructor function to create a new Workbench object
	local self = setmetatable({}, Workbench) -- creates a new instance with Workbench as metatable

	self.Model = model -- stores the workbench model reference
	self.PosBox = model:WaitForChild("PosBox") :: BasePart -- gets the exact center spot of the table
	self.ZoneBox = model:WaitForChild("ZoneBox") :: BasePart -- gets the hit zone for the box

	self.gui = model:WaitForChild("Gui") -- gets the UI folder
	self.timerGui = self.gui:WaitForChild("Timer") -- gets the timer UI
	self.TimerLabel = self.timerGui:WaitForChild("Text") :: TextLabel -- gets the text label inside the timer
	self.FinishGui = self.gui:WaitForChild("Finish") -- gets the finish UI

	self.ParticlesOpen = model:WaitForChild("Particles"):WaitForChild("Open") -- gets the open particles

	model.Destroying:Connect(function() -- connects to when the workbench is destroyed
		self:Destroy() -- calls destroy function to clean up memory
	end)

	self._state = State.Idle -- initializes state as Idle
	self._box = nil :: Model? -- sets initial box reference to nil
	self._placer = nil :: Player? -- sets initial placer reference to nil
	self._timer = 0 -- initializes timer to 0
	self._timerAcc = 0 -- initializes timer accumulator to 0
	self._spawnAcc = 0 -- initializes spawn accumulator to 0
	self._bubbles = {} :: {Bubble} -- initializes empty list for bubbles
	self._hbConn = nil :: RBXScriptConnection? -- sets heartbeat connection to nil
	self._conns = {} :: {RBXScriptConnection} -- initializes empty list for connections

	self.FinishGui.Visible = false -- hides the finish UI
	self.TimerLabel.Text = "" -- clears the timer text

	self:_listenForBox() -- starts listening for a box to be dropped

	return self -- returns the newly created Workbench instance
end

function Workbench:_listenForBox() -- function to detect when a box hits the table
	local debounce = {} -- table to prevent firing multiple times at once

	local conn = self.ZoneBox.Touched:Connect(function(hit) -- connects to the touched event
		if self._state ~= State.Idle then return end -- exits if the workbench is already busy

		local parent = hit.Parent -- gets the parent of the hit part
		if not parent or not CollectionService:HasTag(parent, "Box") then return end -- exits if it's not a box
		if debounce[parent] then return end -- exits if we already registered this box

		debounce[parent] = true -- marks this box as processed

		task.defer(function() -- delays safely to the next frame
			self:_enterOpening(parent :: Model) -- starts the opening process
			debounce[parent] = nil -- clears the debounce
		end)
	end)

	table.insert(self._conns, conn) -- adds connection to the list for cleanup later
end

function Workbench:_enterOpening(box: Model) -- function to start opening the box
	if self._state ~= State.Idle then return end -- exits if not idle

	local primary = box.PrimaryPart -- gets the box's primary part
	if not primary then return end -- exits if no primary part

	self._state = State.Opening -- sets state to Opening
	self._box = box -- stores the box reference
	self._timer = Config.OpenDuration -- sets the timer to the config duration
	self._timerAcc = 0 -- resets timer accumulator
	self._spawnAcc = 0 -- resets spawn accumulator
	table.clear(self._bubbles) -- clears any leftover bubbles

	local dd = box:FindFirstChildOfClass("DragDetector") -- finds the drag detector
	if dd then dd.Enabled = false end -- disables grabbing while opening

	primary.AssemblyLinearVelocity = Vector3.zero -- stops box movement
	primary.AssemblyAngularVelocity = Vector3.zero -- stops box spinning
	box:PivotTo(self.PosBox.WorldCFrame) -- snaps box to the center of the table

	task.delay(0.2, function() -- waits a split second for physics to settle
		if primary and primary.Parent then -- checks if part still exists
			primary.Anchored = true -- glues the box to the table
		end
	end)

	local placerId = box:GetAttribute("PlacedBy") -- gets the ID of the player who placed it
	self._placer = if placerId then Players:GetPlayerByUserId(placerId) else nil -- finds the actual player object

	self.timerGui.Visible = true -- shows the timer UI
	self:_burstParticles(true) -- turns on the shiny particles
	self.TimerLabel.Text = tostring(math.ceil(self._timer)) -- updates the timer text

	self._hbConn = RunService.Heartbeat:Connect(function(dt) -- starts the heartbeat loop
		if self._state ~= State.Opening then return end -- exits if not opening anymore
		self:_tickTimer(dt) -- runs the timer logic
		self:_tickBubbles(dt) -- runs the bubble spawning logic
	end)
end

function Workbench:_tickTimer(dt: number) -- function to update the countdown timer
	self._timer -= dt -- subtracts the time passed from the timer
	self._timerAcc += dt -- adds time passed to the accumulator

	if self._timerAcc >= Config.TimerUpdateRate then -- checks if it's time to update the screen text
		self._timerAcc = 0 -- resets the accumulator
		self.TimerLabel.Text = tostring(math.max(0, math.ceil(self._timer))) -- updates the text label safely
	end

	if self._timer <= 0 then -- checks if the timer has hit zero
		self:_enterOpened() -- calls function to open the box
	end
end

function Workbench:_tickBubbles(dt: number) -- function to handle bubble spawning times
	self._spawnAcc += dt -- adds time passed to the spawn accumulator
	if self._spawnAcc >= Config.BubbleInterval then -- checks if it's time to spawn a bubble
		self._spawnAcc = 0 -- resets the accumulator
		self:_spawnBubble() -- calls function to spawn a new bubble
	end
end

function Workbench:_spawnBubble() -- function to create a new bubble
	local angle = math.random() * math.pi * 2 -- picks a random angle around the box
	local radius = math.sqrt(math.random()) * Config.BubbleSpawnRadius -- picks a random distance
	local height = Config.BubbleSpawnYMin + math.random() * (Config.BubbleSpawnYMax - Config.BubbleSpawnYMin) -- picks a random height

	local origin = self.PosBox.WorldPosition -- gets the center position
	local spawnPos = origin + Vector3.new( -- calculates the final spawn position
		math.cos(angle) * radius,
		height,
		math.sin(angle) * radius
	)

	local model = popTemplate:Clone() -- clones the bubble model
	model:PivotTo(CFrame.new(spawnPos)) -- moves it to the spawn position
	model.Parent = workspace -- parents it to the workspace

	local lifespan = Config.BubbleMinLife + math.random() * (Config.BubbleMaxLife - Config.BubbleMinLife) -- sets a random lifespan

	local bubble: Bubble = { model = model, alive = true } -- creates the bubble data table

	local cd = model:FindFirstChildOfClass("ClickDetector") -- finds the click detector
	if cd then -- checks if it exists
		cd.MouseClick:Connect(function() -- connects to when a player clicks it
			if not bubble.alive then return end -- exits if already popped
			self:_popBubble(bubble, true) -- pops the bubble and passes true for player click
		end)
	end

	table.insert(self._bubbles, bubble) -- adds the bubble to our list

	local primaryPart = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart") -- gets the main part
	if not primaryPart then -- checks if part is missing
		model:Destroy() -- destroys the broken model
		return -- exits early
	end

	local driftX = (math.random() - 0.5) * (Config.BubbleWobbleAmp * 15) -- calculates random X drift
	local driftZ = (math.random() - 0.5) * (Config.BubbleWobbleAmp * 15) -- calculates random Z drift
	local endPos = spawnPos + Vector3.new(driftX, Config.BubbleFloatSpeed * lifespan, driftZ) -- calculates final upward position

	local moveTween = TweenService:Create(primaryPart, TweenInfo.new(lifespan, Enum.EasingStyle.Linear), { -- creates a tween to move it smoothly
		CFrame = CFrame.new(endPos) -- sets the target position
	})
	moveTween:Play() -- starts moving the bubble

	task.delay(lifespan, function() -- delays execution until lifespan ends
		if bubble.alive then self:_popBubble(bubble, false) end -- pops the bubble automatically
	end)
end

function Workbench:_popBubble(bubble: Bubble, byPlayer: boolean) -- function to pop the bubble
	if not bubble.alive then return end -- exits if already popped
	bubble.alive = false -- sets alive state to false

	local idx = table.find(self._bubbles, bubble) -- finds the bubble in our list
	if idx then table.remove(self._bubbles, idx) end -- removes it from the list to prevent memory leak

	local part = bubble.model.PrimaryPart or bubble.model:FindFirstChildWhichIsA("BasePart") -- gets the part to animate

	if not part then -- checks if part is missing
		bubble.model:Destroy() -- destroys it normally
		if byPlayer then self:_reduceTimer() end -- gives time reduction if clicked
		return -- exits early
	end

	local tween = TweenService:Create(part, TweenInfo.new(Config.BubblePopDuration, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { -- creates pop animation
		Size = part.Size * Config.BubblePopScale, -- makes it grow bigger
		Transparency = 1, -- makes it invisible
	})
	tween:Play() -- plays the pop animation
	Debris:AddItem(bubble.model, Config.BubblePopDuration + 0.05) -- deletes the model after animation finishes

	if byPlayer then self:_reduceTimer() end -- gives time reduction if player clicked it
end

function Workbench:_reduceTimer() -- function to shave time off the clock
	self._timer = math.max(Config.TimerFloor, self._timer - Config.BubbleClickReduction) -- reduces time safely without going below floor
end

function Workbench:_clearBubbles() -- function to pop all leftover bubbles
	for i = #self._bubbles, 1, -1 do -- loops backwards through all bubbles
		self:_popBubble(self._bubbles[i], false) -- pops them automatically
	end
end

function Workbench:_enterOpened() -- function to finish opening and give reward
	if self._state ~= State.Opening then return end -- exits if not opening

	self._state = State.Opened -- changes state to Opened

	if self._hbConn then -- checks if heartbeat connection exists
		self._hbConn:Disconnect() -- disconnects the loop
		self._hbConn = nil -- clears the reference
	end

	self:_clearBubbles() -- cleans up all bubbles
	self:_burstParticles(false) -- turns off the shiny particles
	self.timerGui.Visible = false -- hides the timer UI
	self.FinishGui.Visible = true -- shows the finish UI

	self:_animateBoxOpen(self._box, function() -- plays the box open animation
		self:_spawnReward() -- spawns the reward when animation finishes
		if self._box then -- checks if box exists
			self._box:Destroy() -- deletes the empty box
			self._box = nil -- clears the reference
		end
	end)

	if self._placer then recordBoxOpened(self._placer) end -- saves score for the player who opened it

	task.delay(Config.RewardLifetime, function() -- waits until reward expires
		if self._state == State.Opened then -- checks if still in opened state
			self.FinishGui.Visible = false -- hides the finish UI
			self._state = State.Idle -- resets workbench back to idle
		end
	end)
end

function Workbench:_animateBoxOpen(box: Model?, onDone: () -> ()) -- function to animate box disappearing
	if not box then return onDone() end -- exits if no box

	local part = box.PrimaryPart -- gets the main part
	if not part then return onDone() end -- exits if missing main part

	local tween = TweenService:Create(part, TweenInfo.new(Config.BoxOpenAnimTime, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { -- creates open animation
		Size = part.Size * 1.6, -- makes it grow bigger
		Transparency = 1, -- makes it invisible
	})

	tween:Play() -- plays the animation
	tween.Completed:Once(onDone) -- calls the finish function when done
end

function Workbench:_spawnReward() -- function to give a random item
	if #rewardPool == 0 then return end -- exits if no rewards exist

	local chosen = rewardPool[math.random(1, #rewardPool)] -- picks a random reward
	local reward = chosen:Clone() -- clones the reward

	local spawnCF = self.PosBox.WorldCFrame * CFrame.new(0, 2, 0) -- sets spawn position slightly above table
	reward:PivotTo(spawnCF) -- moves the reward to spawn position
	reward.Parent = workspace -- parents it to workspace

	CollectionService:AddTag(reward, "Reward") -- tags it as a reward

	local dd = Instance.new("DragDetector") -- creates a drag detector to pick it up
	dd.ResponseStyle = Enum.DragDetectorResponseStyle.Physical -- sets to physical
	dd.DragStyle = Enum.DragDetectorDragStyle.BestForDevice -- sets to best for device
	dd.MaxForce = Config.RewardDragForce -- sets grab strength
	dd.MaxTorque = Config.RewardDragForce -- sets spin strength
	dd.MaxActivationDistance = 20 -- sets grab distance
	dd.Parent = reward -- parents to the reward

	dd.DragEnd:Connect(function() -- connects to when the player grabs the reward
		if self._state == State.Opened then -- checks if workbench is still opened
			self.FinishGui.Visible = false -- hides the UI
			self._state = State.Idle -- resets back to idle for the next person
		end
	end)

	task.delay(Config.RewardLifetime, function() -- waits until reward expires
		if reward and reward.Parent then reward:Destroy() end -- deletes it if nobody took it
	end)
end

function Workbench:_burstParticles(visible: boolean) -- function to turn particles on or off
	for _, desc in ipairs(self.ParticlesOpen:GetDescendants()) do -- loops through all children
		if desc:IsA("ParticleEmitter") then -- checks if it is a particle emitter
			desc.Enabled = visible -- sets enabled state to true or false
		end
	end
end

function Workbench:Destroy() -- function to clean up the workbench memory
	if self._hbConn then self._hbConn:Disconnect() end -- disconnects heartbeat loop
	for _, conn in ipairs(self._conns) do conn:Disconnect() end -- disconnects all stored connections
	table.clear(self._conns) -- clears the connections list
	self:_clearBubbles() -- pops any remaining bubbles
end

local benches = {} -- creates an empty table to hold all workbenches
for _, model in ipairs(WorkbenchFolder:GetChildren()) do -- loops through all models in the folder
	if model:IsA("Model") then table.insert(benches, Workbench.new(model)) end -- creates a workbench object for each model
end

WorkbenchFolder.ChildAdded:Connect(function(child) -- connects to when a new workbench is added
	if child:IsA("Model") then table.insert(benches, Workbench.new(child)) end -- creates object for new models
end)

game:BindToClose(function() -- connects to when the server shuts down
	for _, player in ipairs(Players:GetPlayers()) do -- loops through all players
		task.spawn(saveSession, player) -- forcefully saves their data
	end
	task.wait(3) -- waits 3 seconds to ensure the datastore finishes saving
end)
