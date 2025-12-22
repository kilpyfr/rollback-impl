--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Movement = require(script.Parent.Movement)
local Types = require(ReplicatedStorage.Types)
local InputQueue = require(script.Parent.InputQueue)
local Packets = require(ReplicatedStorage.AllPackets)
local GameState =require(script.Parent.GameState)
local AnimUtil = require(script.Parent.AnimationUtil)
local DebugManager = require(script.Parent.DebugManager)

local Updater = {}

local maxRollbackFrames = 8

local currentFrame = 0
local remoteFrame = 0
local syncFrame = 0

local jumpFrame = 0
local jumping = false
local jumpInput = ""

local remoteJumpFrame = 0
local remoteJumping = false
local remoteJumpInput = ""

local fixedDelta = 1/60
local accumulator = 0

local currentAction = ""
local remoteAction = ""

local LocalPlayerModel: Types.Character
local RemotePlayerModel: Types.Character

local RemotePlayer: Player
local LocalPlayer: Player

local RemoteHrp: BasePart
local LocalHrp: BasePart

local RemoteAnimator: Animator
local LocalAnimator: Animator

local Platform: BasePart

local lastPacket: Types.NetworkPacket

local JumpStartCFrame: CFrame | any
local RemoteJumpCFrame: CFrame | any
local DefaultY: number

local GameConnection: RBXScriptConnection

local function faceOther()
	local OtherPosition1 = Vector3.new(RemoteHrp.Position.X, LocalHrp.Position.Y, RemoteHrp.Position.Z)
	
	LocalHrp.CFrame = CFrame.lookAt(LocalHrp.Position, OtherPosition1)
	
	local OtherPosition2 = Vector3.new(LocalHrp.Position.X, RemoteHrp.Position.Y, LocalHrp.Position.Z)
	RemoteHrp.CFrame = CFrame.lookAt(RemoteHrp.Position, OtherPosition2)
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

		remoteAction = GameState.getRemoteData(syncFrame + 1).RemoteInput
		
		local jumpstart = false
		if string.find(remoteAction, "Jump") and not remoteJumping then
			remoteJumpInput = remoteAction
			remoteJumping = true
			remoteJumpFrame = 0
			jumpstart = true
		end
		
		local resultantPosition = State.RemotePosition
		
		AnimUtil.TerminateAllAnims(RemoteAnimator)
		
		--print("updating")
		for i = syncFrame +1, currentFrame do
			
			GameState.replaceRemoteInput(i, remoteAction)
			GameState.correctPredictedData(i, remoteAction)
			
			if (remoteAction == "D" or remoteAction == "A") and not remoteJumping then
				resultantPosition = Movement.Walk(resultantPosition, remoteAction)

			elseif jumpstart then
			
				if not RemoteJumpCFrame then
					RemoteJumpCFrame = resultantPosition
				end
				remoteJumpFrame += 1

				local result = Movement.Jump(RemoteJumpCFrame, remoteJumpInput, remoteJumpFrame)

				local collisionResult = Movement.CheckCollision(result.Position, Vector3.new(0,-3,0), Platform, RemotePlayerModel:GetChildren())
				if collisionResult and remoteJumpFrame > 1 then
					resultantPosition = resultantPosition.Rotation + Vector3.new(resultantPosition.X, DefaultY, resultantPosition.Z)
					
					remoteJumpFrame = 0
					remoteJumpInput  = ""
					RemoteJumpCFrame = nil
					remoteJumping = false
				else
					resultantPosition = result
				end
			end
			GameState.replaceRemotePosition(i, resultantPosition)
		end
		
		
		if not remoteJumping then
			RemoteHrp.CFrame = resultantPosition
			--print("animsupdate")
			AnimUtil.TranslateToAnimation(remoteAction, RemoteAnimator, RemoteHrp.CFrame.LookVector)
		else
			
			AnimUtil.TranslateToAnimation("Jump", RemoteAnimator, Vector3.new())
		end

	
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
				Find out why line 108 sometimes prints false and/or errors
				Figure out the core cause of the desync (may need to jot down some math/logic)
				Find out why line 93 errors when spamming D or A very fast
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
		InputQueue.StoreInput(currentAction, currentFrame)
		local networkinputs = getLastInputStates(2)
		
		
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
				
		if InputCheck then
			if string.find(InputCheck, "Jump") and not jumping then
				jumping = true
				jumpInput = InputCheck
				InputQueue.AddInput(currentAction, currentFrame, 1)
			end
			AnimUtil.TerminateAllAnims(LocalAnimator)
			if not jumping then
				AnimUtil.TranslateToAnimation(InputCheck, LocalAnimator, LocalHrp.CFrame.LookVector)
			else
				AnimUtil.TranslateToAnimation("Jump", LocalAnimator, Vector3.new())
			end
			currentAction = InputCheck
			
		end			
		if (currentAction == "D" or currentAction == "A") and not jumping then
			local result = Movement.Walk(LocalHrp.CFrame, currentAction)
			LocalHrp.CFrame = result
		elseif jumping then
			
			if not JumpStartCFrame then
			JumpStartCFrame = LocalHrp.CFrame
			end	
			jumpFrame += 1
			
			local result = Movement.Jump(JumpStartCFrame, jumpInput, jumpFrame)
		--	print(result, LocalHrp.CFrame)
			
			local collisionResult = Movement.CheckCollision(result.Position, Vector3.new(0,-3,0), Platform, LocalPlayerModel:GetChildren())
			
			if collisionResult and jumpFrame > 1 then
		
				LocalHrp.CFrame = LocalHrp.CFrame.Rotation + Vector3.new(LocalHrp.Position.X, DefaultY, LocalHrp.Position.Z)
				
				jumpFrame = 0
				jumpInput  = ""
				JumpStartCFrame = nil
				jumping = false
				
				AnimUtil.TerminateAllAnims(LocalAnimator)
				AnimUtil.TranslateToAnimation(currentAction, LocalAnimator, LocalHrp.CFrame.LookVector)
			else
				LocalHrp.CFrame = LocalHrp.CFrame.Rotation + result.Position
			end
		end
		
		if (remoteAction == "D" or remoteAction == "A") and not remoteJumping then
		
			local result = Movement.Walk(RemoteHrp.CFrame, remoteAction)
			RemoteHrp.CFrame = result

		elseif remoteJumping then
			
			remoteJumpFrame += 1

			local result = Movement.Jump(RemoteJumpCFrame, remoteJumpInput, remoteJumpFrame)
			
			local collisionResult = Movement.CheckCollision(result.Position, Vector3.new(0,-3,0), Platform, RemotePlayerModel:GetChildren())

			if collisionResult and remoteJumpFrame > 1 then

				RemoteHrp.CFrame = RemoteHrp.CFrame.Rotation + Vector3.new(RemoteHrp.Position.X, DefaultY, RemoteHrp.Position.Z)
				
				remoteJumpFrame = 0
				remoteJumpInput  = ""
				RemoteJumpCFrame = nil
				remoteJumping = false
				
				AnimUtil.TerminateAllAnims(RemoteAnimator)
				AnimUtil.TranslateToAnimation(remoteAction, RemoteAnimator, RemoteHrp.CFrame.LookVector)
			else
				RemoteHrp.CFrame = RemoteHrp.CFrame.Rotation + result.Position
			end
		end
		GameState.addPredictedData(currentFrame, remoteAction)
		
		GameState.add(currentAction, remoteAction, LocalHrp.CFrame, RemoteHrp.CFrame, currentFrame, remoteFrame)
		--ReadPacket(lastPacket)
		DebugManager.UpdateFrames(currentFrame, remoteFrame)
	end
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
function Updater.AddPlayerInfo(CurrentPlayerModel:Model, OtherPlayerModel: Model, CurrentPlayer: Player, OtherPlayer: Player, Ground: BasePart)
	LocalPlayerModel = CurrentPlayerModel :: Types.Character
	RemotePlayerModel = OtherPlayerModel :: Types.Character
	LocalPlayer = CurrentPlayer
	RemotePlayer = OtherPlayer
	LocalHrp = LocalPlayerModel.HumanoidRootPart
	RemoteHrp = RemotePlayerModel.HumanoidRootPart 
	LocalAnimator = LocalPlayerModel.Humanoid.Animator
	RemoteAnimator = RemotePlayerModel.Humanoid.Animator
	DefaultY = LocalHrp.Position.Y
	Platform = Ground
	
	AnimUtil.LoadAnimations(LocalAnimator)
	AnimUtil.LoadAnimations(RemoteAnimator)
	
	AnimUtil.TranslateToAnimation("", LocalAnimator, Vector3.new())
	AnimUtil.TranslateToAnimation("", RemoteAnimator, Vector3.new())
	

	DebugManager.AddUI(CurrentPlayer.PlayerGui.Debug)
end

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

