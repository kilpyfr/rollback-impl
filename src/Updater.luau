--!strict

--[[
    Updater - Fixed timestep rollback netcode
    
    Fighting games need sub-frame response times. Roblox's default replication 
    has ~100ms latency, which feels terrible for precise platforming/combat.
    
    Instead, we run the full simulation locally and predict what the opponent 
    will do. When their actual inputs arrive, we rewind to where we diverged 
    and replay with the correct data. This is how GGPO and modern fighters work.
    
    Tradeoff: requires deterministic physics (same inputs = same results) and
    burns CPU to resimulate. But latency feels instant.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Movement = require(script.Parent.Movement)
local Types = require(ReplicatedStorage.Types)
local InputQueue = require(script.Parent.InputQueue)
local Packets = require(ReplicatedStorage.AllPackets)
local GameState = require(script.Parent.GameState)
local AnimUtil = require(script.Parent.AnimationUtil)
local Renderer = require(script.Renderer)
local DebugManager = require(script.Parent.DebugManager)

local Updater = {}

-- Frame counters
-- currentFrame: our simulation head, always advances
-- remoteFrame: last confirmed frame from opponent (stale until packet arrives)
-- syncFrame: last frame where our prediction matched reality
local currentFrame = 0
local remoteFrame = 0
local syncFrame = 0

-- Animation timing tracks "how long since action started" rather than 
-- absolute frames. This lets us blend animations smoothly even during rollback.
local currentActionFrame = 0
local remoteActionFrame = 0

-- Jump state machines
-- Local jump: predicted immediately for responsive feel
-- Remote jump: simulated here but driven by delayed network inputs
-- Both use identical physics curves to keep determinism
local jumpFrame = 0
local jumping = false
local jumpInput = ""

local remoteJumpFrame = 0
local remoteJumping = false
local remoteJumpInput = ""

-- Jump tuning
local landFrames = 4      -- coyote time: can jump this many frames after leaving ground
local lastJumpLand = 0    -- frame we last landed, for spam prevention
local jumpLength = 31     -- fixed animation curve length in frames

-- Fixed timestep accumulator
-- Heartbeat fires irregularly (60-240hz depending on client). We accumulate
-- delta time and step simulation in discrete 1/60s chunks. This ensures:
-- 1. Identical physics across all clients regardless of render FPS
-- 2. Reproducible replays (same inputs = same positions)
-- 3. Stable rollback (we can re-simulate frame N identically)
local fixedDelta = 1/60
local accumulator = 0

-- Action strings ("A", "D", "JumpL") instead of enums
-- Tradeoff: typo-vulnerable but human-readable in network dumps and debugger
local currentAction = ""
local remoteAction = ""

-- Jump physics needs start CFrame for consistent arcs
-- We store full CFrame (not just Position) because facing direction matters
local JumpStartCFrame: CFrame
local RemoteJumpCFrame: CFrame

-- Current simulation positions
local LocalCFrame: CFrame
local RemoteCFrame: CFrame

-- Ground reference for landing height reset
-- Assumes flat ground; curved terrain would need raycast instead
local Platform: BasePart
local DefaultY: number

-- Player references for network targeting and camera ownership
local RemotePlayer: Player
local LocalPlayer: Player

-- Last packet for detecting network stalls (not fully implemented yet)
local lastPacket: Types.NetworkPacket

-- Visual hitbox debuggers
-- Using parts instead of UI so we can see world-space alignment
local RemoteHitbox: BasePart
local LocalHitbox: BasePart

local GameConnection: RBXScriptConnection

-- Reset remote jump state. Separated because rollback may need to reset
-- mid-simulation without affecting local state.
local function resetRemoteJump()
	remoteJumpFrame = 0
	remoteJumpInput = ""
	RemoteJumpCFrame = nil
	remoteJumping = false
	
	-- Strip Jump prefix but preserve directional modifiers if any
	if string.find(remoteAction, "Jump") then
		remoteAction = ""
	end
end

-- Update visual hitbox positions. These lag one simulation frame behind
-- but that's fine for debugging - they're just visualization.
local function updateHitbox()
	LocalHitbox.CFrame = LocalCFrame - Vector3.new(0, 0.3, 0)
	RemoteHitbox.CFrame = RemoteCFrame - Vector3.new(0, 0.3, 0)
end

-- Lock characters to face each other on X/Z plane, ignoring Y (jump height).
-- This guarantees attacks connect horizontally even during vertical spacing.
-- Separate calculations because local and remote Y positions differ.
local function faceOther()
	local target1 = Vector3.new(RemoteCFrame.Position.X, LocalCFrame.Position.Y, RemoteCFrame.Position.Z)
	LocalCFrame = CFrame.lookAt(LocalCFrame.Position, target1)
	
	local target2 = Vector3.new(LocalCFrame.Position.X, RemoteCFrame.Position.Y, RemoteCFrame.Position.Z)
	RemoteCFrame = CFrame.lookAt(RemoteCFrame.Position, target2)
end

-- Find the oldest frame where our prediction diverged from reality.
-- We scan forward from last known good (syncFrame) because inputs arrive
-- out of order and we may have already corrected some frames.
--
-- Optimization: stop at min(currentFrame, remoteFrame) because we can't
-- validate frames we haven't simulated or haven't received yet.
local function updateSyncFrame()
	local finalFrame = math.min(remoteFrame, currentFrame)
	local foundFrame: number?

	for i = syncFrame + 1, finalFrame do
		if GameState.getPredictedData(i).Input ~= GameState.getRemoteData(i).RemoteInput then
			foundFrame = i
			break
		end	
	end

	syncFrame = foundFrame and (foundFrame - 1) or finalFrame
end

-- Rollback and resimulation. This is the core of the netcode.
--
-- When syncFrame < currentFrame, we diverged from the server/opponent.
-- We load state from syncFrame, then re-simulate everything up to now
-- using the correct remote inputs.
--
-- Critical: Movement.Jump must return identical results given identical
-- inputs and start CFrames, or desync compounds with each rollback.
local function initiateRollback()
	DebugManager.UpdateRollbackFrames(currentFrame - syncFrame)
	
	local State = GameState.read(syncFrame)
	local lastAction = remoteAction
	remoteAction = GameState.getRemoteData(syncFrame + 1).RemoteInput
	
	-- Action change detection: reset actionFrame for animation blending
	if lastAction ~= remoteAction then
		remoteActionFrame = remoteFrame - (syncFrame + 1)
	end
	
	local wasJumping = State.RemoteJumping
	local jumpstart = false

	-- Detect if opponent started jumping between syncFrame and now
	if string.find(remoteAction, "Jump") and not wasJumping then
		remoteJumpInput = remoteAction
		remoteJumping = true
		remoteJumpFrame = 0
		jumpstart = true
	end
	
	local resultantPosition: CFrame = State.RemotePosition
	
	if jumpstart then
		RemoteJumpCFrame = resultantPosition
	end
	
	-- Resimulation loop: deterministic replay with corrected inputs
	for i = syncFrame + 1, currentFrame do
		GameState.replaceRemoteInput(i, remoteAction)
		GameState.correctPredictedData(i, remoteAction)
		
		if (remoteAction == "D" or remoteAction == "A") and not wasJumping and not remoteJumping then
			resultantPosition = Movement.Walk(resultantPosition, remoteAction)
		elseif jumpstart then
			remoteJumpFrame += 1
			local result = Movement.Jump(RemoteJumpCFrame, remoteJumpInput, remoteJumpFrame)
			resultantPosition = result
			
			if remoteJumpFrame == jumpLength then		
				resultantPosition = resultantPosition.Rotation + Vector3.new(resultantPosition.X, DefaultY, resultantPosition.Z)
				resetRemoteJump()
			end
		end
		
		if not wasJumping then
			GameState.replaceRemotePosition(i, resultantPosition)
		end
	end

	RemoteCFrame = resultantPosition
end

-- Package last N inputs for network transmission.
-- We send 3 because UDP drops packets. Redundancy lets the remote reconstruct
-- our input stream even if one packet is lost. Frame numbers allow idempotent
-- application (they can ignore duplicates).
local function getLastInputStates(count: number): {[number]: Types.packet}
	local packetArray = {}
	for i = count, 0, -1 do
		local p = InputQueue.ReadInput(currentFrame - i)
		packetArray[#packetArray + 1] = p or {input = "", frame = currentFrame}
	end	
	return packetArray
end

local function loopFunction(delta: number)
	accumulator += delta

	-- Consume accumulated time in fixed chunks
	while accumulator > fixedDelta do
		accumulator -= fixedDelta
		
		-- Phase 1: Reconcile with remote if we have data
		if lastPacket and currentFrame >= 1 then	
			updateSyncFrame()
			if currentFrame > syncFrame and remoteFrame > syncFrame then
				initiateRollback()
			end
		end
		
		faceOther()
		currentFrame += 1
		
		-- Phase 2: Sample and validate local input
		local InputCheck = InputQueue.CheckInputs(currentFrame)	 

		if InputCheck then
			-- Jump validation: check coyote time and grounded state
			if string.find(InputCheck, "Jump") then	
				if currentFrame - lastJumpLand >= landFrames and not jumping then
					jumping = true
					jumpInput = InputCheck
					InputQueue.AddInput(currentAction, currentFrame, 1)
					currentAction = InputCheck
					currentActionFrame = 0
				end
			else
				-- Directional inputs: immediate transition, no validation needed
				currentAction = InputCheck
				currentActionFrame = 0
			end
		end			
		
		-- Phase 3: Local physics simulation
		if (currentAction == "D" or currentAction == "A") and not jumping then
			LocalCFrame = Movement.Walk(LocalCFrame, currentAction)
		elseif jumping then
			if not JumpStartCFrame then
				JumpStartCFrame = LocalCFrame
			end	
			jumpFrame += 1
			
			local result = Movement.Jump(JumpStartCFrame, jumpInput, jumpFrame)
			-- Preserve rotation, adopt new position from jump curve
			LocalCFrame = LocalCFrame.Rotation + result.Position
			
			if jumpFrame == jumpLength then	
				LocalCFrame = LocalCFrame.Rotation + Vector3.new(LocalCFrame.X, DefaultY, LocalCFrame.Z)
				jumpFrame = 0
				jumpInput = ""
				JumpStartCFrame = nil
				jumping = false
				lastJumpLand = currentFrame
				
				if string.find(currentAction, "Jump") then
					currentAction = ""
				end
			end
		end
		
		-- Phase 4: Remote physics simulation (predicted or corrected)
		if (remoteAction == "D" or remoteAction == "A") and not remoteJumping then
			RemoteCFrame = Movement.Walk(RemoteCFrame, remoteAction)
		elseif remoteJumping then
			remoteJumpFrame += 1
			local result = Movement.Jump(RemoteJumpCFrame, remoteJumpInput, remoteJumpFrame)
			RemoteCFrame = RemoteCFrame.Rotation + result.Position
		
			if remoteJumpFrame == jumpLength then
				RemoteCFrame = RemoteCFrame.Rotation + Vector3.new(RemoteCFrame.X, DefaultY, RemoteCFrame.Z)	
				resetRemoteJump()
			end
		end
		
		currentActionFrame += 1
		remoteActionFrame += 1
		
		-- Phase 5: Record state for future rollbacks
		GameState.addPredictedData(currentFrame, remoteAction)
		GameState.add(currentAction, remoteAction, LocalCFrame, RemoteCFrame, currentFrame, remoteFrame, jumping, remoteJumping)
	
		DebugManager.UpdateFrames(currentFrame, remoteFrame)
		updateHitbox()
		
		-- Phase 6: Network transmission
		InputQueue.StoreInput(currentAction, currentFrame)
		local networkinputs = getLastInputStates(2)

		Packets.SendInfo.send({
			input1 = networkinputs[1].input,
			frame1 = networkinputs[1].frame,
			input2 = networkinputs[2].input,
			frame2 = networkinputs[2].frame,
			input3 = networkinputs[3].input,
			frame3 = networkinputs[3].frame,
			OtherPlayer = RemotePlayer,
			TimeSent = workspace:GetServerTimeNow(),
		})
	end
	
	-- Render interpolation happens every visual frame, not every simulation step
	Renderer.RenderFrame(currentAction, remoteAction, LocalCFrame, RemoteCFrame, jumping, remoteJumping, currentActionFrame, remoteActionFrame)
end

-- Graceful shutdown: send empty input to signal disconnection
function Updater.Stop()
	InputQueue.AddInput("", currentFrame, 1)
end

function Updater.StartLoop(startFrame: number)
	currentFrame = 0
	GameConnection = RunService.Heartbeat:Connect(loopFunction)
end

function Updater.StopLoop()
	if GameConnection then
		GameConnection:Disconnect()
	end
end

function Updater.GetLocalFrame(): number
	return currentFrame
end

-- Dependency injection to avoid circular requires (GameState needs Updater)
function Updater.AddPlayerInfo(
	CurrentPlayerModel: Types.Character, 
	OtherPlayerModel: Types.Character, 
	CurrentPlayer: Player, 
	OtherPlayer: Player, 
	CurrentHitbox: BasePart, 
	OtherHitbox: BasePart, 
	Ground: BasePart
)
	LocalPlayer = CurrentPlayer
	RemotePlayer = OtherPlayer

	DefaultY = CurrentPlayerModel.HumanoidRootPart.CFrame.Y
	Platform = Ground
	LocalHitbox = CurrentHitbox
	RemoteHitbox = OtherHitbox
	
	LocalCFrame = CurrentPlayerModel.HumanoidRootPart.CFrame
	RemoteCFrame = OtherPlayerModel.HumanoidRootPart.CFrame

	DebugManager.AddUI(CurrentPlayer.PlayerGui.Debug)
	Renderer.AddRenderInstances(CurrentPlayerModel, OtherPlayerModel)
end

-- Process incoming packet. UDP doesn't guarantee order, so we use frame 
-- numbers to slot inputs into the right place and ignore duplicates.
function Updater.DecipherPacket(Info: Types.NetworkPacket)
	remoteFrame = Info.frame3
	
	-- Backfill missing frames if packet arrived out of order
	if not GameState.getRemoteData(Info.frame1) then
		GameState.addRemoteData(Info.frame1, Info.input1)
	end
	if not GameState.getRemoteData(Info.frame2) then
		GameState.addRemoteData(Info.frame2, Info.input2)
	end
	GameState.addRemoteData(remoteFrame, Info.input3)
	
	lastPacket = Info
end

return Updater
