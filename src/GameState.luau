local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RingBufferModule = require(ReplicatedStorage.RingBuffer)
local Types = require(ReplicatedStorage.Types)
local GameState = {}

local Data = RingBufferModule.new(50)
local PredictedData = RingBufferModule.new(50)
local RemoteData = RingBufferModule.new(50)

local function getEmptyTable(): Types.StoragePacket
	
	return {
		LocalInput = "",
		RemoteInput = "",
		LocalPosition = CFrame.new(),
		RemotePosition = CFrame.new(),
		Frame = 0,
	}

end

function GameState.replaceRemotePosition(frame, pos)
	for _, v: Types.StoragePacket in pairs(Data) do		
		v = v :: Types.StoragePacket
		if typeof(v) == "table" then
		if v.Frame == frame then
			v.RemotePosition = pos
			return
		end 
		end
	end
end

function GameState.readNewest(): Types.StoragePacket
	return Data:readNewest()
end

function GameState.replaceRemoteInput(frame, input)
	for _, v: Types.StoragePacket in pairs(Data) do		
		v = v :: Types.StoragePacket
		if typeof(v) == "table" then
		if v.Frame == frame then
			v.RemoteInput = input
			return
		end
		end
	end
end

function GameState.add(locinput, reminput, locposition, remposition,  frame, remframe)
	local StoragePacket = {
		LocalInput = locinput,
		RemoteInput = reminput,
		LocalPosition = locposition,
		RemotePosition = remposition,
		Frame = frame,
		RemoteFrame = remframe
	}
	
	Data:push(StoragePacket)
end

function GameState.read(frame: number): Types.StoragePacket
	for _, v: Types.StoragePacket in pairs(Data) do
		if typeof(v) == "table" then
		if v.Frame == frame then
			return v
		end
		end
	end

end

function GameState.readRemote(remframe: number): Types.StoragePacket
	for _, v: Types.StoragePacket in pairs(Data) do
		v = v:: Types.StoragePacket
		if typeof(v)  == "table" then
		if v.RemoteFrame == remframe then
			return v
		end
		end
	end
	
end

function GameState.addRemoteData(frame, input)
	RemoteData:push({
		RemoteFrame = frame,
		RemoteInput = input
	})
end

function GameState.getOldestRemoteData(): Types.RemotedData
	return RemoteData:readOldest()
end

function GameState.getRemoteData(frame, input) : Types.RemotedData
	for i , v in pairs(RemoteData) do
		if typeof(v) == "table" then
			if v.RemoteFrame == frame then
				return v
			end
		end
	end
end

function GameState.addPredictedData(frame, input)
	local data = {
		Frame = frame,
		Input = input
	}
	PredictedData:push(data)
end

function GameState.getMostRecentlyPredicted(): Types.PredictedData
	return PredictedData:readNewest()
end

function GameState.getMostOldestPredicted(): Types.PredictedData
	return PredictedData:readOldest()
end

function GameState.correctPredictedData(frame, input)
	for i , v in pairs(PredictedData) do
		if typeof(v) == "table" then
			if v.Frame == frame then
				v.Input = input
			end
		end
	end
end

function GameState.getPredictedData(frame) : Types.PredictedData
	for i , v in pairs(PredictedData) do
		if typeof(v) == "table" then
		if v.Frame == frame then
			return v
		end
		end
	end
end

return GameState
