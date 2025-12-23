--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")

local Player  = game.Players.LocalPlayer :: Player

local InputModule = require(script.InputCreator)
local Updater = require(script.GameUpdater)
local Packets = require(ReplicatedStorage.AllPackets)
local Types = require(ReplicatedStorage.Types)
local InputQueue = require(script.InputQueue)
local DebugManager = require(script.DebugManager)

local Cam = workspace.CurrentCamera :: Camera
local References = ReplicatedStorage.PlayerReferences

local PlayerType: string

local Peer: Player

local DefaultContext = InputModule.NewContext("Default")

local DWalkAction = InputModule.NewAction(DefaultContext, "DWalk")
local AWalkAction = InputModule.NewAction(DefaultContext, "AWalk")
local JumpAction = InputModule.NewAction(DefaultContext, "Jump")

local DWalkBind1 = InputModule.NewBinding(DWalkAction, "DBinding")
local AWalkBind1 = InputModule.NewBinding(AWalkAction, "ABinding")
local JumpBind = InputModule.NewBinding(JumpAction, "Binding")

DWalkBind1.KeyCode = Enum.KeyCode.D
AWalkBind1.KeyCode = Enum.KeyCode.A

JumpBind.KeyCode = Enum.KeyCode.Space

local WalkKey

DWalkAction.Pressed:Connect(function()
	WalkKey = "D"	
	InputQueue.AddInput("D", Updater.GetLocalFrame(), 1)
end)
AWalkAction.Pressed:Connect(function()
	WalkKey = "A"
	InputQueue.AddInput("A", Updater.GetLocalFrame(), 1)
end)

DWalkAction.Released:Connect(function()
	Updater.Stop()
	WalkKey = nil
end)
AWalkAction.Released:Connect(function()
	Updater.Stop()
	WalkKey = nil
end)

JumpAction.Pressed:Connect(function()
	if WalkKey then
		InputQueue.AddInput("Jump" .. WalkKey, Updater.GetLocalFrame(), 1)
		
	else
		InputQueue.AddInput("Jump", Updater.GetLocalFrame(), 1)
	end
end)


DefaultContext.Enabled = false



Packets.StartGame.listen(function(Info)
	PlayerType = Info.PlayerType
	Peer = Info.OtherPlayer :: Player
	
	Packets.SendHandshake.send({
		OtherPlayer = Info.OtherPlayer,
		TimeSent = Info.TimeSent,
	})
end)

Packets.SendHandshake.listen(function(Info)
	print("handshake")
	
	DefaultContext.Enabled = true
	Cam.CameraType = Enum.CameraType.Scriptable
	
	-- Spawn Models
	for _, v: Part in pairs(ReplicatedStorage.LocalLoad:GetChildren()) do
		v:Clone().Parent = workspace
	end
	
	Cam.CFrame = ReplicatedStorage.CamPart.CFrame
	local Ground = workspace:FindFirstChild("FightGround") :: BasePart
	
	local Player1Model = References.Player1:Clone() :: Types.Character & Model
	local Player2Model = References.Player2:Clone() :: Types.Character & Model
	
	Player1Model.Parent = workspace
	Player2Model.Parent = workspace
	
	Player1Model.HumanoidRootPart.CFrame = ReplicatedStorage.LocalLoad.Player1Spawn.CFrame
	Player2Model.HumanoidRootPart.CFrame = ReplicatedStorage.LocalLoad.Player2Spawn.CFrame

	
	if PlayerType == "Player1"	then
		Updater.AddPlayerInfo(Player1Model, Player2Model, Player, Peer, Ground)
	elseif PlayerType == "Player2" then
		Updater.AddPlayerInfo(Player2Model, Player1Model, Player, Peer, Ground)
	end
	
	Updater.StartLoop((workspace:GetServerTimeNow() - Info.TimeSent) * 60)
end)

Packets.SendInfo.listen(function(Info)
	
	
	Updater.DecipherPacket(Info)

end)
