local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RingBufferMod = require(ReplicatedStorage.RingBuffer)
local Types = require(ReplicatedStorage.Types)
local InputQueue = {}

type queue = {
	[number] : string
}

local queue: queue = {}
local storageQueue = RingBufferMod.new(8) 
function InputQueue.AddInput(input,currentFrame, delayframes)
	
	queue[currentFrame + delayframes] = input
end

function InputQueue.CheckInputs(frame: number)
	if queue[frame] then	
		local input = queue[frame]
		queue[frame] = nil
		
		return input
	end
end

function InputQueue.StoreInput(i, f)
	local s = {
		input = i,
		frame = f,
	}
	storageQueue:push(s)
end

function InputQueue.ReadInput(frame): Types.packet

	for _, v in pairs(storageQueue) do
	if type(v) == "table" then
		if v.frame == frame then
			
			return v
		end
	end
		
	end
end

return InputQueue
