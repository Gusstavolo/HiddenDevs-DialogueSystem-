local Players = game:GetService("Players") -- getting the players
local RunService = game:GetService("RunService") -- need this for game loops
local TweenService = game:GetService("TweenService") -- for smooth animations
local Debris = game:GetService("Debris") -- to delete things after a while so it doesn't lag
local CollectionService = game:GetService("CollectionService") -- to group similar objects together
local DataStoreService = game:GetService("DataStoreService") -- for saving player data

local ReplicatedStorage = game:GetService("ReplicatedStorage") -- stuff both client and server can use

local Assets = ReplicatedStorage:WaitForChild("Assets") -- folder with our models and things
local boxTemplate = Assets:WaitForChild("Box"):WaitForChild("Box") -- the main box we copy every time it spawns
local popTemplate = Assets:WaitForChild("Pops"):WaitForChild("PopTime") -- the bubble effect we copy
local rewardFolder = Assets:WaitForChild("Rewards") -- where we keep the rewards

local rewardPool = rewardFolder:GetChildren() -- making a list of all the rewards inside the folder

local WorkbenchFolder = workspace:WaitForChild("Workbench") -- holds all workbench models in the map
local BoxSpawnModel = workspace:WaitForChild("BoxSpawn") -- this is where the box first appears for the player
local spawnAnchor = BoxSpawnModel:WaitForChild("Pos") -- the exact spot to put the new box


local Config = {}

Config.DragMaxForce  = 50000    -- how strong the dragging is, so the player can actually pull it
Config.DragMaxTorque = 50000    -- lets the box spin a bit while holding it
Config.DragActivationDist = 15      -- how close you need to be to grab it
Config.DragDistanceLimit  = 20      -- drops the box if you walk too far away
Config.DragYOffset  = 5       -- lifts the box a bit so it doesn't drag on the floor


Config.OpenDuration  = 18.0    -- how long it takes to open normally
Config.TimerFloor = 4.0     -- minimum wait time, you can't open it instantly
Config.TimerUpdateRate = 0.05    -- updates the text timer super fast to look smooth

Config.BubbleInterval = 1.8     -- time before a new bubble shows up
Config.BubbleMinLife = 3.0     -- at least 3 seconds before the bubble pops itself
Config.BubbleMaxLife = 6.5     -- bubble is gone after this much time
Config.BubbleFloatSpeed = 2.2     -- how fast the bubble goes up
Config.BubbleSpawnRadius = 5.0     -- how far from the middle bubbles can spawn
Config.BubbleSpawnYMin = 2.0     -- lowest spawn point for a bubble
Config.BubbleSpawnYMax  = 3.5     -- highest spawn point for a bubble
Config.BubbleWobbleAmp = 0.18    -- makes the bubble move side to side a bit
Config.BubbleWobbleSpeed = 2.5     -- how fast it shakes side to side
Config.BubbleClickReduction = 2.5    -- clicking a bubble skips this much time
Config.BubblePopScale = 2.8     -- bubble gets bigger right before it pops
Config.BubblePopDuration = 0.18    -- how fast the pop animation plays


Config.RewardDragForce = 40000   -- strength needed to grab the reward item
Config.RewardLifetime = 30      -- delete the reward if nobody takes it
Config.BoxOpenAnimTime = 0.55    -- time it takes for the box to disappear when opened


Config.DataStoreName       = "WorkbenchBoxCount_v1" -- name of the save file for the database

local State = { -- workbench states
	Idle    = "Idle",      -- waiting for someone to put a box here
	Opening = "Opening",   -- counting down and popping bubbles
	Opened  = "Opened",    -- box is open, get your reward
}

local BoxStore = DataStoreService:GetDataStore(Config.DataStoreName)   -- where we actually save the player's data
local sessions = {}   -- [userId] = { boxesOpened = number, dirty = boolean }

-- Loading the player's save file when they join
local function loadSession(player: Player)
	local key = "player_" .. tostring(player.UserId) -- the unique name to find this exact player's save

	-- trying to get their saved data without breaking the game if it fails
	local ok, stored = pcall(function()
		return BoxStore:GetAsync(key)
	end)

	local count = 0
	-- if we found their save, use that number. if not, they start at 0
	if ok and stored and stored.boxesOpened then
		count = stored.boxesOpened
	end

	-- saving their info locally so we don't have to ask the database every second
	sessions[player.UserId] = {
		key         = key,
		boxesOpened = count,
		dirty       = false, -- 'dirty' just means "did the score change? do we need to save it?"
	}

	-- making the folder so players can see their score on the top right (leaderboard)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name   = "leaderstats"
	leaderstats.Parent = player

	-- creating the actual score number for "Boxes Opened"
	local boxesValue = Instance.new("IntValue")
	boxesValue.Name = "Boxes Opened" 
	boxesValue.Value = count       
	boxesValue.Parent = leaderstats
end

-- What happens when they finally open a box
local function recordBoxOpened(player: Player)
	local session = sessions[player.UserId]
	if not session then return end -- if we don't have their info, just stop here

	session.boxesOpened += 1
	session.dirty        = true -- mark that the score changed and we need to save it later

	-- update the screen so the player sees the new number go up
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		local boxesValue = leaderstats:FindFirstChild("Boxes Opened")
		if boxesValue then
			boxesValue.Value = session.boxesOpened  
		end
	end

	-- quickly save the new score to the database right now, just to be safe
	pcall(function()
		BoxStore:UpdateAsync(session.key, function()
			return { boxesOpened = session.boxesOpened }
		end)
	end)

	session.dirty = false -- score is saved, so it's not 'dirty' anymore
end

-- Saving player stuff when they leave the game
local function saveSession(player: Player)
	local session = sessions[player.UserId] 
	if not session then return end   

	-- only save if their score actually changed, so we don't spam the database for nothing
	if session.dirty then  
		pcall(function()
			BoxStore:UpdateAsync(session.key, function()
				return { boxesOpened = session.boxesOpened } 
			end)
		end)
	end

	sessions[player.UserId] = nil -- remove their info from the local list since they left
end

-- whenever someone joins, load their stuff
Players.PlayerAdded:Connect(function(player)
	task.spawn(loadSession, player)
end)

-- whenever someone leaves, save their stuff
Players.PlayerRemoving:Connect(function(player)
	saveSession(player)
end)

-- if someone is already in the game when this script starts, load their stuff too
for _, p in ipairs(Players:GetPlayers()) do  
	task.spawn(loadSession, p)
end


local function spawnBox()
	local box = boxTemplate:Clone()   -- making a new box from the template
	box.Parent = BoxSpawnModel   -- putting it in the spawn area
	box:PivotTo(spawnAnchor.WorldCFrame) -- moving it to the exact starting spot

	CollectionService:AddTag(box, "Box")  -- tagging it so the game knows this is a real box

	local dd = Instance.new("DragDetector")  -- making the box draggable
	dd.ResponseStyle = Enum.DragDetectorResponseStyle.Physical  -- making it feel like real physics
	dd.DragStyle = Enum.DragDetectorDragStyle.BestForDevice -- works nicely on PC and phones
	dd.MaxForce  = Config.DragMaxForce        -- how hard you can pull it
	dd.MaxTorque = Config.DragMaxTorque      -- how much it can spin while dragging
	dd.MaxActivationDistance = Config.DragActivationDist  -- how close you need to be to grab it

	-- lifting the box a bit while dragging so it doesn't get stuck in the floor
	dd:AddConstraintFunction(1, function(proposed: CFrame): CFrame
		return proposed + Vector3.new(0, Config.DragYOffset, 0)
	end)

	-- checking things while the player is moving the box
	dd.DragContinue:Connect(function(player: Player)
		local char = player.Character                                              
		if not char then return end

		local hrp = char:FindFirstChild("HumanoidRootPart")  -- the player's body
		if not hrp then return end

		local dist = (box.PrimaryPart.Position - hrp.Position).Magnitude 

		-- if the player walks too far away, force them to drop the box
		if dist > Config.DragDistanceLimit then   
			dd.Enabled = false       
			task.wait() 
			dd.Enabled = true     
		end
	end)

	-- remember who picked up the box first
	dd.DragStart:Connect(function(player: Player)
		box:SetAttribute("PlacedBy", player.Name)  
	end)

	-- when they let go, put the box in the main world space
	dd.DragEnd:Once(function()
		box.Parent = workspace 
	end)

	dd.Parent = box  

	return box  
end

-- this part makes sure there is always a box ready to be grabbed
do
	spawnBox()  

	BoxSpawnModel.ChildRemoved:Connect(function()
		local hasBox = false
		for _, child in ipairs(BoxSpawnModel:GetChildren()) do
			if CollectionService:HasTag(child, "Box") then
				hasBox = true
				break
			end
		end

		-- if the spawn area is empty, spawn a new one
		if not hasBox then 
			spawnBox()     
		end
	end)
end

-- Setting up the Workbench (where players put the box to open it)
local Workbench   = {}
Workbench.__index = Workbench

function Workbench.new(model: Model)
	local self = setmetatable({}, Workbench)

	-- getting all the parts of the workbench we need
	self.Model = model
	self.PosBox = model:WaitForChild("PosBox")
	self.ZoneBox = model:WaitForChild("ZoneBox")

	-- getting the UI stuff (texts, timers)
	self.gui = model:WaitForChild("Gui")
	self.timerGui = self.gui:WaitForChild("Timer")
	self.TimerLabel = self.timerGui:WaitForChild("Text")
	self.FinishGui = self.gui:WaitForChild("Finish") 

	self.ParticlesOpen = model:WaitForChild("Particles"):WaitForChild("Open")  

	-- basic setup when the workbench is created
	self._state = State.Idle
	self._box = nil 
	self._placer = nil        
	self._timer = 0         
	self._timerAcc = 0      
	self._spawnAcc = 0          
	self._bubbles = {}          
	self._hbConn = nil 
	self._conns = {}

	-- hiding things until we actually need them
	self.FinishGui.Visible = false
	self.TimerLabel.Text   = ""

	self:_listenForBox() -- wait for someone to put a box here

	return self
end

-- Waiting for a player to drop a box on the table
function Workbench:_listenForBox()

	-- keeping track so the game doesn't trigger this a hundred times at once
	local debounce = {}

	local conn = self.ZoneBox.Touched:Connect(function(hit)
		if self._state ~= State.Idle then return end  -- if we are already doing something, stop here

		local parent = hit.Parent
		if not parent or not CollectionService:HasTag(parent, "Box") then return end   -- make sure it's actually a box

		if debounce[parent] then return end  
		debounce[parent] = true 

		-- wait a tiny bit and then start the opening process
		task.defer(function() 
			self:_enterOpening(parent)
			debounce[parent] = nil 
		end)
	end)

	table.insert(self._conns, conn) -- save this connection so we can turn it off later
end

-- what happens when the box is placed and starts opening
function Workbench:_enterOpening(box: Model)
	if self._state ~= State.Idle then return end 

	-- setup the basic stuff for this box
	self._state    = State.Opening 
	self._box      = box 
	self._timer    = Config.OpenDuration 
	self._timerAcc = 0
	self._spawnAcc = 0
	table.clear(self._bubbles)

	-- stop the player from grabbing the box again
	local dd = box:FindFirstChildOfClass("DragDetector")
	if dd then dd.Enabled = false end

	-- stop the box from moving, spinning, or flying away
	local primary = box.PrimaryPart
	primary.AssemblyLinearVelocity  = Vector3.zero
	primary.AssemblyAngularVelocity = Vector3.zero
	box:PivotTo(self.PosBox.WorldCFrame) -- snap it to the exact center of the table

	-- wait a split second and glue it to the table completely
	task.delay(.2,function()
		if primary and primary.Parent then
			primary.Anchored = true
		end
	end)

	-- remember who put the box here
	local placerName = box:GetAttribute("PlacedBy")
	self._placer = if placerName then Players:FindFirstChild(placerName) else nil

	-- show the timer on the screen and play the nice particles
	self.timerGui.Visible = true
	self:_burstParticles(true)
	self.TimerLabel.Text = tostring(math.ceil(self._timer))

	-- start a super fast loop to count down the time and move the bubbles
	self._hbConn = RunService.Heartbeat:Connect(function(dt)
		if self._state ~= State.Opening then return end 

		self:_tickTimer(dt)
		self:_tickBubbles(dt) 
	end)
end

-- doing the math to update the timer text
function Workbench:_tickTimer(dt: number)
	self._timer    -= dt -- take away time
	self._timerAcc += dt

	-- only update the screen text sometimes so it doesn't lag
	if self._timerAcc >= Config.TimerUpdateRate then 
		self._timerAcc = 0
		local display = math.max(0, math.ceil(self._timer)) -- make sure it never shows less than 0
		self.TimerLabel.Text = tostring(display)
	end

	-- when time is up, open the box
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

	if #self._bubbles == 0 then return end -- if there are no bubbles, just stop here

	-- check all bubbles (we go backwards so we don't mess up the list when we delete one)
	for i = #self._bubbles, 1, -1 do
		local b = self._bubbles[i]

		-- if it's already popped, delete it from the list
		if not b.alive then 
			table.remove(self._bubbles, i)
			continue
		end

		b.age     += dt
		b.wobbleT += dt * Config.BubbleWobbleSpeed 

		-- if the bubble is too old, pop it automatically
		if b.age >= b.lifespan then
			self:_popBubble(b, false)
			table.remove(self._bubbles, i)
			continue
		end

		local cf   = b.model:GetPivot() 

		-- math to make the bubble shake left and right a little bit
		local wobbleX = math.sin(b.wobbleT) * Config.BubbleWobbleAmp
		local wobbleZ = math.cos(b.wobbleT) * Config.BubbleWobbleAmp

		-- move the bubble up and add the shaking
		local delta = Vector3.new(
			wobbleX,
			Config.BubbleFloatSpeed * dt, 
			wobbleZ  
		)

		b.model:PivotTo(cf + delta)  
	end
end

-- Making a new bubble pop up around the box
function Workbench:_spawnBubble()

	-- random math to pick a spot around the box for the bubble to spawn
	local angle  = math.random() * math.pi * 2                                             
	local radius = math.sqrt(math.random()) * Config.BubbleSpawnRadius                            
	local height = Config.BubbleSpawnYMin + math.random() * (Config.BubbleSpawnYMax - Config.BubbleSpawnYMin) 

	local origin   = self.PosBox.WorldPosition  
	local spawnPos = origin + Vector3.new(
		math.cos(angle) * radius,
		height,
		math.sin(angle) * radius
	)

	-- creating the actual bubble and putting it in the world
	local model = popTemplate:Clone()
	model:PivotTo(CFrame.new(spawnPos))
	model.Parent = workspace

	-- deciding how long this specific bubble will live before it pops by itself
	local lifespan = Config.BubbleMinLife + math.random() * (Config.BubbleMaxLife - Config.BubbleMinLife)

	-- saving all the info about this new bubble
	local bubble = {
		model    = model,
		age      = 0,
		lifespan = lifespan, 
		wobbleT  = math.random() * math.pi * 2, -- so they don't all shake the exact same way
		alive    = true,
	}

	-- checking if the player clicks on the bubble
	local cd = model:FindFirstChildOfClass("ClickDetector")
	if cd then
		cd.MouseClick:Connect(function(_player: Player) 
			if not bubble.alive then return end
			self:_popBubble(bubble, true) -- true means the player clicked it
		end)
	end

	table.insert(self._bubbles, bubble) -- add it to our list of bubbles
end

-- Popping the bubble (either clicked by a player or it got too old)
function Workbench:_popBubble(bubble, byPlayer: boolean)
	if not bubble.alive then return end  
	bubble.alive = false                

	local part = bubble.model.PrimaryPart or bubble.model:FindFirstChildOfClass("BasePart")

	if part then
		-- making a smooth animation to make the bubble grow and fade out
		local info = TweenInfo.new(
			Config.BubblePopDuration,
			Enum.EasingStyle.Back,
			Enum.EasingDirection.Out
		)

		local tween = TweenService:Create(part, info, {
			Size         = part.Size * Config.BubblePopScale, 
			Transparency = 1, -- make it invisible
		})

		tween:Play() 

		-- delete the bubble from the game right after the animation finishes
		Debris:AddItem(bubble.model, Config.BubblePopDuration + 0.05)
	else
		bubble.model:Destroy()  
	end

	-- if the player actually clicked it, cut some time off the clock
	if byPlayer then
		self:_reduceTimer()  
	end
end

-- Taking time off the clock when they click a bubble
function Workbench:_reduceTimer()
	-- making sure the timer never goes below the minimum limit we set in Config
	self._timer = math.max(
		Config.TimerFloor,                            
		self._timer - Config.BubbleClickReduction   
	)
end

-- Popping all leftovers bubbles at once
function Workbench:_clearBubbles()
	for i = #self._bubbles, 1, -1 do
		self:_popBubble(self._bubbles[i], false)   
		table.remove(self._bubbles, i)
	end
end

-- Time is up Let's open the box.
function Workbench:_enterOpened()
	if self._state ~= State.Opening then return end   

	self._state = State.Opened  

	-- stop the countdown loop
	if self._hbConn then       
		self._hbConn:Disconnect()
		self._hbConn = nil
	end

	self:_clearBubbles()                          
	self:_burstParticles(false) -- turn off the opening particles
	self.timerGui.Visible  = false                
	self.FinishGui.Visible = true                    

	-- play the open animation and give the reward when it's done
	self:_animateBoxOpen(self._box, function() 
		self:_spawnReward()
		if self._box then
			self._box:Destroy() -- delete the empty box
			self._box = nil
		end
	end)

	-- save the point for the player who put the box here
	if self._placer then
		recordBoxOpened(self._placer) 
	end

	-- reset the workbench after a while if nobody takes the reward
	task.delay(Config.RewardLifetime, function()
		if self._state == State.Opened then
			self.FinishGui.Visible = false
			self._state = State.Idle
		end
	end)
end


function Workbench:_animateBoxOpen(box: Model, onDone: () -> ())-- Making the box grow and fade away when it opens
	-- if the box got deleted or is missing its main part, just skip this and move on
	if not box then onDone() return end  

	local part = box.PrimaryPart
	if not part then onDone() return end 

	-- setting up how the animation feels, 'Back' makes it do a cool little bounce
	local info = TweenInfo.new(
		Config.BoxOpenAnimTime,
		Enum.EasingStyle.Back,           
		Enum.EasingDirection.Out
	)

	-- telling the game WHAT to animat,: make it bigger and fully invisible
	local tween = TweenService:Create(part, info, {
		Size         = part.Size * 1.6,   
		Transparency = 1,                
	})

	tween:Play() -- play the animation

	-- wait until the animation is 100% done, then tell the game to give the reward
	tween.Completed:Once(function()   
		onDone()
	end)
end

-- Giving the player a random reward
function Workbench:_spawnReward()

	if #rewardPool == 0 then return end   

	-- pick a random item from the rewards folder
	local chosen = rewardPool[math.random(1, #rewardPool)]   
	local reward = chosen:Clone()                          

	-- spawn it slightly above the table
	local spawnCF = self.PosBox.WorldCFrame * CFrame.new(0, 2, 0)   
	reward:PivotTo(spawnCF)
	reward.Parent = workspace

	CollectionService:AddTag(reward, "Reward")   -- tag it so the game knows it's a reward item

	-- make the reward grabbable too
	local dd = Instance.new("DragDetector")
	dd.ResponseStyle = Enum.DragDetectorResponseStyle.Physical
	dd.DragStyle = Enum.DragDetectorDragStyle.BestForDevice
	dd.MaxForce = Config.RewardDragForce
	dd.MaxTorque = Config.RewardDragForce
	dd.MaxActivationDistance = 20           
	dd.Parent = reward        

	-- when they grab the reward, reset the workbench for the next player
	dd.DragEnd:Connect(function()
		if self._state == State.Opened then
			self.FinishGui.Visible = false
			self._state = State.Idle 
		end
	end)

	-- delete the reward if nobody picks it up after a while
	task.delay(Config.RewardLifetime, function()
		if reward and reward.Parent then
			reward:Destroy()  
		end
	end)
end

-- Turning the shiny particles on or off
function Workbench:_burstParticles(visible)
	for _, desc in ipairs(self.ParticlesOpen:GetDescendants()) do
		if desc:IsA("ParticleEmitter") then
			desc.Enabled = visible
		end
	end
end

-- cleaning up everything if the workbench gets deleted
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

-- setting up all the workbenches already in the map
local benches = {}  

for _, model in ipairs(WorkbenchFolder:GetChildren()) do 
	if model:IsA("Model") then                          
		local bench = Workbench.new(model)                
		table.insert(benches, bench)                    
	end
end

-- setting up any new workbenches added to the map later
WorkbenchFolder.ChildAdded:Connect(function(child)
	if child:IsA("Model") then
		local bench = Workbench.new(child)
		table.insert(benches, bench)
	end
end)
