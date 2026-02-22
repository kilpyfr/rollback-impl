--!strict

--[[
    Updater - Fixed timestep netcode for rollback fighting game stuff
    
    The gist: both clients run the same simulation. We predict the opponent's 
    moves locally, then rewind and replay when their actual inputs arrive.
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
local currentFrame = 0
local remoteFrame = 0
local syncFrame = 0

-- Animation timing (frames since action started)
local currentActionFrame = 0
local remoteActionFrame = 0

-- Jump state
local jumpFrame = 0
local jumping = false
local jumpInput = ""

local remoteJumpFrame = 0
local remoteJumping = false
local remoteJumpInput = ""

-- Jump config
local landFrames = 4  -- coyote time buffer
local lastJumpLand = 0
local jumpLength = 31  -- how long a jump takes

-- Fixed timestep stuff
local fixedDelta = 1/60
local accumulator = 0

-- Actions ("A", "D", "JumpL", etc)
local currentAction = ""
local remoteAction = ""

-- CFrames for jump calculations
local JumpStartCFrame: CFrame
local RemoteJumpCFrame: CFrame

local LocalCFrame: CFrame
local RemoteCFrame: CFrame

local Platform: BasePart
local DefaultY: number  -- ground height for landing

local RemotePlayer: Player
local LocalPlayer: Player

local lastPacket: Types.NetworkPacket

local RemoteHitbox: BasePart
local LocalHitbox: BasePart

local GameConnection: RBXScriptConnection

local function resetRemoteJump()
	remoteJumpFrame = 0
	remoteJumpInput = ""
	RemoteJumpCFrame = nil
	remoteJumping = false
	
	if string.find(remoteAction, "Jump") then
		remoteAction = ""
	end
end

local function updateHitbox()
	-- visual hitboxes lag one frame behind but that's fine for debugging
	LocalHitbox.CFrame = LocalCFrame - Vector3.new(0, 0.3, 0)
	RemoteHitbox.CFrame = RemoteCFrame - Vector3.new(0, 0.3, 0)
end

local function faceOther()
	-- lock Y so we don't tilt up/down when someone jumps
	local target1 = Vector3.new(RemoteCFrame.Position.X, LocalCFrame.Position.Y, RemoteCFrame.Position.Z)
	LocalCFrame = CFrame.lookAt(LocalCFrame.Position, target1)
	
	local target2 = Vector3.new(LocalCFrame.Position.X, RemoteCFrame.Position.Y, LocalCFrame.Position.Z)
	RemoteCFrame = CFrame.lookAt(RemoteCFrame.Position, target2)
end

--[[
    Find the last frame where we agreed with the server/opponent.
    If we guessed wrong about their inputs, we rewind to here.
]]
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

--[[
    The rollback. necessary for responsive netcode.
    
    We load state from syncFrame, then re-simulate everything up to now
    using the correct remote inputs. If Movement.Jump isn't deterministic,
    this whole thing falls apart.
]]
local function initiateRollback()
	DebugManager.UpdateRollbackFrames(currentFrame - syncFrame)
	
	local State = GameState.read(syncFrame)
	local lastAction = remoteAction
	remoteAction = GameState.getRemoteData(syncFrame + 1).RemoteInput
	
	if lastAction ~= remoteAction then
		remoteActionFrame = remoteFrame - (syncFrame + 1)
	end
	
	local wasJumping = State.RemoteJumping
	local jumpstart = false

	-- did they start jumping between syncFrame and now?
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

--[[
    We send last 3 inputs because UDP drops packets sometimes.
    Redundancy means the remote can reconstruct our input stream
    even if one packet gets lost.
]]
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

	while accumulator > fixedDelta do
		accumulator -= fixedDelta
		
		-- check if we need to rollback
		if lastPacket and currentFrame >= 1 then	
			updateSyncFrame()
			if currentFrame > syncFrame and remoteFrame > syncFrame then
				initiateRollback()
			end
		end
		
		faceOther()
		currentFrame += 1
		
		-- grab local input
		local InputCheck = InputQueue.CheckInputs(currentFrame)	 

		if InputCheck then
			if string.find(InputCheck, "Jump") then	
				-- only jump if we're grounded and not spamming
				if currentFrame - lastJumpLand >= landFrames and not jumping then
					jumping = true
					jumpInput = InputCheck
					InputQueue.AddInput(currentAction, currentFrame, 1)
					currentAction = InputCheck
					currentActionFrame = 0
				end
			else
				currentAction = InputCheck
				currentActionFrame = 0
			end
		end			
		
		-- local physics
		if (currentAction == "D" or currentAction == "A") and not jumping then
			LocalCFrame = Movement.Walk(LocalCFrame, currentAction)
		elseif jumping then
			if not JumpStartCFrame then
				JumpStartCFrame = LocalCFrame
			end	
			jumpFrame += 1
			
			local result = Movement.Jump(JumpStartCFrame, jumpInput, jumpFrame)
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
		
		-- remote physics (predicted or corrected)
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
		
		-- save state so we can rollback later
		GameState.addPredictedData(currentFrame, remoteAction)
		GameState.add(currentAction, remoteAction, LocalCFrame, RemoteCFrame, currentFrame, remoteFrame, jumping, remoteJumping)
	
		DebugManager.UpdateFrames(currentFrame, remoteFrame)
		updateHitbox()
		
		-- send inputs to other player
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
	
	-- render happens every visual frame, not every sim step
	Renderer.RenderFrame(currentAction, remoteAction, LocalCFrame, RemoteCFrame, jumping, remoteJumping, currentActionFrame, remoteActionFrame)
end

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

--[[
    Packets can arrive out of order. We use frame numbers to slot
    inputs into the right place and ignore duplicates.
]]
function Updater.DecipherPacket(Info: Types.NetworkPacket)
	remoteFrame = Info.frame3
	
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
