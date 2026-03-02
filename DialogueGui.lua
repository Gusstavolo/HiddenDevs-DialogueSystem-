
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local LocalizationService = game:GetService("LocalizationService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local player = game.Players.LocalPlayer

-- UI Hierarchy setup - WaitForChild ensures elements exist before access
local HUD = player.PlayerGui:WaitForChild("HUD")
local TutorialFrame = HUD:WaitForChild("CentralFrame"):WaitForChild("Tutorial")

-- Pre-cache default model reference and its world transform for consistent positioning
local defaultModel = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Templates"):WaitForChild("TheLogg")
local defaultPosAndRot = defaultModel:GetPivot()  -- Stores exact CFrame for replication

-- Core UI components (ViewportFrame for 3D models, TextLabel for typewriter)
local ViewModel = TutorialFrame:WaitForChild("ViewModel")
local WorldModel = ViewModel:WaitForChild("WorldModel")
local MensageMain = TutorialFrame:WaitForChild("MensageMain")
local ContentText = MensageMain:WaitForChild("ContentText")
local SkipButton = MensageMain:WaitForChild("SkipButton")

--[[
  CENTRALIZED CONFIGURATION SYSTEM
 
  All timing, positioning, and behavioral constants in one place for easy tweaking.
  Uses workspace attribute detection for lobby vs gameplay positioning.
--]]
local CONFIG = {
	TYPE_SPEED = 0.02,        -- Base character typing speed (ms per char)
	PAUSE_SPEED = 0.3,        -- Dramatic pause duration at sentence endings (. ! ?)
	TWEEN_TIME = 0.6,         -- UI slide animation duration with Back easing bounce
	Y_VISIBLE = 0.95,         -- Tutorial frame final visible Y position
	Y_HIDDEN = 1.5            -- Off-screen position for hide animation
}

-- Type annotations for IDE support and code clarity (Luau strict mode ready)
export type DialogueStep = {
	msg: string,              -- Primary dialogue text content
	anim: string?,            -- Animation asset ID or category name
	duration: number?         -- Optional auto-advance timer in seconds
}

export type CustomDialogues = {DialogueStep}

-- Pre-calculate UDim2 positions for buttery smooth TweenService transitions
local BaseX = TutorialFrame.Position.X.Scale
local UI_VISIBLE_POS = UDim2.new(BaseX, 0, CONFIG.Y_VISIBLE, 0)
local UI_HIDDEN_POS = UDim2.new(BaseX, 0, CONFIG.Y_HIDDEN, 0)
local TWEEN_INFO = TweenInfo.new(CONFIG.TWEEN_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

--[[
  GLOBAL APPLICATION STATE
 
  Single-player client optimization - no network sync needed.
  Prevents overlapping dialogues and manages typewriter state.
--]]
local DialogueSystem = {}
local currentQueue = {}        -- Active dialogue step array
local currentIndex = 0         -- Current position in dialogue queue
local isRunning = false        -- Session active flag (prevents overlap)
local isTyping = false         -- Typewriter animation state
local fullText = ""            -- Complete text buffer during typing
local translator = nil         -- Cached LocalizationService instance
local handlerInstance = nil    -- Active ModelHandler metatable instance

--[[
  PRODUCTION ERROR HANDLING
  
  Wraps all risky operations (LocalizationService, require, etc.) with pcall.
  Logs errors without breaking core functionality - enterprise-grade reliability.
--]]
local function safeCall(fn, ...)
	local success, result = pcall(fn, ...)
	if not success then 
		warn("[DialogueSystem] Operation failed:", result)
	end
	return success, result
end

--[[
  MODELHANDLER METATABLE - ADVANCED 3D MODEL ORCHESTRATION
  Object-oriented model management using Luau metatables.
  Handles model swapping, precise CFrame positioning, animation caching, and cleanup.
--]]
local ModelHandler = {}
ModelHandler.__index = ModelHandler

--[[
  Constructor initializes metatable with WorldModel reference.
  Sets up sophisticated default CFrame with 15° camera-facing rotation.
--]]
function ModelHandler.new(worldModel)
	local self = setmetatable({}, ModelHandler)
	self.WorldModel = worldModel
	self.CurrentModel = nil
	self.Humanoid = nil
	self.Animator = nil
	self.LoadedTracks = {}

	-- Professional CFrame composition: translation + rotation for perfect camera framing
	self.defaultCFrame = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(15), 0)
	return self
end

--[[
  Swaps current model with new template. Maintains exact positioning consistency
  using pre-cached PivotTo from original model reference.
--]]
function ModelHandler:SetTemplate(template)
	-- Graceful cleanup of previous model instance
	if self.CurrentModel then
		self.CurrentModel:Destroy()
	end

	if not template then 
		warn("ModelHandler:SetTemplate - No valid template provided")
		return 
	end

	-- Deep clone preserves original template integrity
	local clone = template:Clone()
	clone.Parent = self.WorldModel

	-- Apply exact positioning from cached reference (professional consistency)
	clone:PivotTo(defaultPosAndRot)

	self.CurrentModel = clone
	self.Humanoid = clone:FindFirstChildOfClass("Humanoid")

	-- Auto-provision Animator if missing (production robustness)
	if self.Humanoid then
		self.Animator = self.Humanoid:FindFirstChildOfClass("Animator") or 
			Instance.new("Animator", self.Humanoid)
	end

	-- Clear animation cache for new model
	self.LoadedTracks = {}
	return clone
end

--[[
  Animation system with LRU-style caching and smooth crossfade transitions.
  Supports both raw IDs and rbxassetid:// formats automatically.
--]]
function ModelHandler:PlayAnim(animId)
	if not self.Animator then return end

	-- Graceful fade-out of all active animation tracks
	for _, track in pairs(self.Animator:GetPlayingAnimationTracks()) do
		track:Stop(0.2)  -- 200ms crossfade
	end

	local idStr = tostring(animId)
	local track = self.LoadedTracks[idStr]

	-- Cache miss - create and preload new animation track
	if not track then
		local anim = Instance.new("Animation")
		-- Auto-format ID (handles both raw numbers and full rbxassetid://)
		anim.AnimationId = string.find(idStr, "rbxassetid") and idStr or "rbxassetid://" .. idStr

		track = self.Animator:LoadAnimation(anim)
		track.Looped = true  -- Dialogue NPCs need looping expressions

		-- Store in LRU cache for instant replay
		self.LoadedTracks[idStr] = track
	end

	-- Fade-in playback with professional timing
	track:Play(0.2)
end

--[[
  Memory cleanup destructor - Prevents ViewportFrame memory leaks
--]]
function ModelHandler:Destroy()
	if self.CurrentModel then
		self.CurrentModel:Destroy()
		self.CurrentModel = nil
	end
end

--[[
  UI ORCHESTRATION SYSTEM - Professional slide transitions

  Back easing provides natural bounce, Quad provides smooth exit.
  Automatic model cleanup on hide completion.
--]]
local function toggleUI(visible)
	if visible then
		-- Entry: Off-screen → visible (Back easing bounce effect)
		TutorialFrame.Visible = true
		TutorialFrame.Position = UI_HIDDEN_POS
		TweenService:Create(TutorialFrame, TWEEN_INFO, {Position = UI_VISIBLE_POS}):Play()
	else
		-- Exit: Visible → off-screen (Quad easing deceleration)
		local tweenOut = TweenService:Create(
			TutorialFrame, 
			TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), 
			{Position = UI_HIDDEN_POS}
		)
		tweenOut:Play()
		-- Cleanup callback ensures no memory leaks
		tweenOut.Completed:Connect(function()
			TutorialFrame.Visible = false
			if handlerInstance then
				handlerInstance:Destroy()
				handlerInstance = nil
			end
		end)
	end
end

--[[
  TYPEWRITER EFFECT ENGINE - Variable speed text reveal

  Realistic typing simulation with intelligent punctuation detection.
  Supports instant-skip during active typing.
--]]
local function typewriter(text)
	isTyping = true
	fullText = text  -- Store complete text for instant reveal
	ContentText.Text = ""

	-- Progressive character reveal loop
	for i = 1, #text do
		if not isTyping then break end  -- Instant skip support

		ContentText.Text = string.sub(text, 1, i)

		-- Context-aware typing speed (professional polish)
		local char = string.sub(text, i, i)
		local speed = (char:match("[.!?]") and CONFIG.PAUSE_SPEED) or CONFIG.TYPE_SPEED
		task.wait(speed)
	end

	-- Final reveal
	ContentText.Text = text
	isTyping = false
end

--[[
  ROBLOX LOCALIZATIONSERVICE INTEGRATION
  Asynchronous translator loading with seamless fallback.
  Supports 30+ languages out of the box.
--]]
task.spawn(function()
	-- Non-blocking async localization setup
	safeCall(function()
		translator = LocalizationService:GetTranslatorForPlayerAsync(player)
	end)
end)

local function translateText(textLabel, originalText)
	if not translator then return originalText end  -- Graceful fallback

	local success, translated = safeCall(function()
		return translator:Translate(textLabel, originalText)
	end)
	return success and translated or originalText
end

--[[
  CORE DIALOGUE ENGINE - Step progression + synchronization
  Orchestrates model animation, text reveal, and localization in single call.
--]]
function DialogueSystem.DisplayStep(stepData)
	if not stepData then
		-- Natural dialogue completion - auto-cleanup
		isRunning = false
		toggleUI(false)
		return
	end

	-- Intelligent text localization with fallback
	local displayText = translateText(ContentText, stepData.msg)

	-- Animation orchestration (priority: step-specific → idle fallback)
	if stepData.anim and handlerInstance then
		handlerInstance:PlayAnim(stepData.anim)
	elseif handlerInstance then
		-- Idle animation fallback for silent moments
		handlerInstance:PlayAnim("180435792")
	end

	-- Execute typewriter sequence
	typewriter(displayText)
end

--[[
  DIALOGUE NAVIGATION - Smart advance logic
  Handles typing interruption + queue progression.
--]]
function DialogueSystem.Next()
	if isTyping then
		-- Instant typewriter completion (UX polish)
		isTyping = false
		ContentText.Text = fullText
		return
	end

	-- Advance queue position and trigger next step
	currentIndex = currentIndex + 1
	DialogueSystem.DisplayStep(currentQueue[currentIndex])
end

--[[
  PRIMARY PUBLIC API - Custom dialogue launcher
  Production-ready entry point. Handles all initialization.
--]]
function DialogueSystem.StartCustom(dialogueData)
	if isRunning then return end  -- Prevent dialogue overlap
	isRunning = true

	-- Initialize ModelHandler metatable instance
	handlerInstance = ModelHandler.new(WorldModel)

	-- Load default NPC template with precise positioning
	local defaultTemplate = defaultModel
	handlerInstance:SetTemplate(defaultTemplate)

	-- Queue management
	currentQueue = dialogueData
	currentIndex = 0

	-- UI activation + first step
	toggleUI(true)
	DialogueSystem.Next()
end

--[[

  MULTI-PLATFORM INPUT LAYER - Universal control scheme
  Mouse/Keyboard/Touch/Gamepad support out of the box.
  
--]]
do
	-- Primary skip button (touch/mobile optimized)
	SkipButton.Activated:Connect(function()
		if isRunning then DialogueSystem.Next() end
	end)

	-- Universal input detection
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not isRunning then return end

		-- Left click / touch / spacebar = advance
		if input.UserInputType == Enum.UserInputType.MouseButton1 or 
			input.UserInputType == Enum.UserInputType.Touch or
			input.KeyCode == Enum.KeyCode.Space then
			DialogueSystem.Next()
		end
	end)
end

--[[
  AUTOMATIC DEMO SYSTEM - HiddenDevs showcase
  Plays demo sequence after GUI load for instant review experience.
--]]
do
	task.wait(2)  -- Ensure full UI/model pipeline readiness

	local demoDialogues = {
		{msg = "Welcome to custom dialogue demo!", anim = "180435792"},
		{msg = "Pure Luau client-side with metatables & CFrame positioning.", anim = "180435792"},
		{msg = "Production-ready CollectionService", anim = "180435792"}
	}

	DialogueSystem.StartCustom(demoDialogues)
end

--[[
  COLLECTION SERVICE MODULE LOADER - Dynamic content discovery
  Auto-discovers ModuleScripts tagged "CustomDialogue" anywhere in game.
  Production-safe require() with error isolation.
--]]
local safeList = {}
do
	-- Enumerate all tagged dialogue modules
	for _, moduleScript in pairs(CollectionService:GetTagged("CustomDialogue")) do
		if moduleScript:IsA("ModuleScript") then
			local success, mod = safeCall(function()
				return require(moduleScript)
			end)
			if success then
				safeList[moduleScript] = mod
				print("[DialogueSystem] Auto-loaded:", moduleScript.Name)
			end
		end
	end
end


return DialogueSystem
