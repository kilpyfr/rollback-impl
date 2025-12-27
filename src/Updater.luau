--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Movement = require(script.Parent.Movement)
local Types = require(ReplicatedStorage.Types)
local InputQueue = require(script.Parent.InputQueue)
local Packets = require(ReplicatedStorage.AllPackets)
local GameState =require(script.Parent.GameState)
local AnimUtil = require(script.Parent.AnimationUtil)
local Renderer = require(script.Renderer)
local DebugManager = require(script.Parent.DebugManager)

local Updater = {}

local currentFrame = 0
local remoteFrame = 0
local syncFrame = 0

local currentActionFrame = 0
local remoteActionFrame = 0

local jumpFrame = 0
local jumping = false
local jumpInput = ""

local remoteJumpFrame = 0
local remoteJumping = false
local remoteJumpInput = ""

local landFrames = 4
local lastJumpLand = 0

local jumpLength = 31

local fixedDelta = 1/60
local accumulator = 0

local currentAction = ""
local remoteAction = ""

local JumpStartCFrame: CFrame | any
local RemoteJumpCFrame: CFrame | any

local LocalCFrame: CFrame
local RemoteCFrame: CFrame

local Platform: BasePart

local DefaultY: number

local RemotePlayer: Player
local LocalPlayer: Player

local lastPacket: Types.NetworkPacket

local RemoteHitbox: BasePart
local LocalHitbox: BasePart

local GameConnection: RBXScriptConnection

local function resetRemoteJump()
	-- reset data for remote jump
	remoteJumpFrame = 0
	remoteJumpInput  = ""
	RemoteJumpCFrame = nil
	remoteJumping = false
	
	if string.find(remoteAction, "Jump") then
		remoteAction = ""
	end
end


local function updateHitbox()
	-- update hitbox visualizer
	LocalHitbox.CFrame = LocalCFrame - Vector3.new(0,0.3,0)
	RemoteHitbox.CFrame = RemoteCFrame - Vector3.new(0,0.3,0)
end

local function faceOther()
	local OtherPosition1 = Vector3.new(RemoteCFrame.Position.X, LocalCFrame.Position.Y, RemoteCFrame.Position.Z)
	
	LocalCFrame = CFrame.lookAt(LocalCFrame.Position, OtherPosition1)
	
	local OtherPosition2 = Vector3.new(LocalCFrame.Position.X, RemoteCFrame.Position.Y, LocalCFrame.Position.Z)
	RemoteCFrame = CFrame.lookAt(RemoteCFrame.Position, OtherPosition2)
end
local function updateSyncFrame()
	local finalFrame = remoteFrame
	if remoteFrame > currentFrame then finalFrame = currentFrame end

	local foundFrame: number

	for i = syncFrame + 1, finalFrame do
		--print(syncFrame, remoteFrame, currentFrame)
		if GameState.getPredictedData(i).Input ~= GameState.getRemoteData(i).RemoteInput then
			foundFrame = i
			break
		end	

	end

	if foundFrame then
		syncFrame = foundFrame - 1
	else
		syncFrame = finalFrame
	end
	
end
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
		
		
		for i = syncFrame +1, currentFrame do
			
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

local function getLastInputStates(number: number): {[number]: Types.packet}
	local start = 0

	local packetArray = {}

	for i = number, start, -1 do
		local p = InputQueue.ReadInput(currentFrame - i)
		if not p then
			p = {input = "", frame = currentFrame}
		end
		packetArray[#packetArray + 1] = p
	end	
	return packetArray
end
	--[[To Do:
			Fix desync with jumping
			Decouple gamestate and rendering
		]]
local function loopFunction(delta: number)
	accumulator += delta

	while accumulator > fixedDelta do
		accumulator -= fixedDelta
		
		if lastPacket and currentFrame >= 1 then	
			updateSyncFrame()
			if currentFrame > syncFrame and remoteFrame > syncFrame then
				initiateRollback()
			end
		end
		
		faceOther()
		
		currentFrame += 1
		
		local InputCheck = InputQueue.CheckInputs(currentFrame)	 
	
		if InputCheck then
			-- filter out invalid inputs to be used
			if string.find(InputCheck, "Jump") then	
				
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
		if (currentAction == "D" or currentAction == "A") and not jumping then
			local result = Movement.Walk(LocalCFrame, currentAction)
			
			LocalCFrame = result
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
				jumpInput  = ""
				JumpStartCFrame = nil
				jumping = false
				lastJumpLand = currentFrame
				
				if string.find(currentAction, "Jump") then
					currentAction = ""
				end
			end
			
			print("localjump", jumpFrame, LocalCFrame)
		end
		
		if (remoteAction == "D" or remoteAction == "A") and not remoteJumping then
			
			local result = Movement.Walk(RemoteCFrame, remoteAction)
			RemoteCFrame = result

		elseif remoteJumping then
			
			remoteJumpFrame += 1

			local result = Movement.Jump(RemoteJumpCFrame, remoteJumpInput, remoteJumpFrame)


			RemoteCFrame = RemoteCFrame.Rotation + result.Position
		
			if remoteJumpFrame == jumpLength then
				RemoteCFrame = RemoteCFrame.Rotation + Vector3.new(RemoteCFrame.X, DefaultY, RemoteCFrame.Z)	
				resetRemoteJump()
			end
			print("remotejump", remoteJumpFrame, RemoteCFrame)
		end
		
		currentActionFrame += 1
		remoteActionFrame += 1
		
		GameState.addPredictedData(currentFrame, remoteAction)
		
		GameState.add(currentAction, remoteAction, LocalCFrame, RemoteCFrame, currentFrame, remoteFrame, jumping, remoteJumping)
	
		DebugManager.UpdateFrames(currentFrame, remoteFrame)
		
		updateHitbox()
		
		
		InputQueue.StoreInput(currentAction, currentFrame)
		local networkinputs = getLastInputStates(2)

		-- send info to remote player
		Packets.SendInfo.send({
			input1 = networkinputs[1].input,
			frame1= networkinputs[1].frame,
			input2 = networkinputs[2].input,
			frame2= networkinputs[2].frame,
			input3 = networkinputs[3].input,
			frame3= networkinputs[3].frame,
			OtherPlayer = RemotePlayer,
			TimeSent = workspace:GetServerTimeNow(),

		})

	end
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

function Updater.GetLocalFrame() : number
	return currentFrame
end
function Updater.AddPlayerInfo(CurrentPlayerModel:Types.Character, OtherPlayerModel: Types.Character, CurrentPlayer: Player, OtherPlayer: Player, CurrentHitbox: BasePart, OtherHitbox: BasePart, Ground: BasePart)
	--set information
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

function Updater.DecipherPacket(Info: Types.NetworkPacket)
	-- decipher info from remote player
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
