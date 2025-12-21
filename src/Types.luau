local Types = {}

export type Character = {
	Head : BasePart,
	Torso:BasePart,
	HumanoidRootPart: BasePart,
	Humanoid: {Animator: Animator} & Humanoid,
	Parent : any,
	GetChildren: (self: Character) -> {Instance}
}

export type packet = {
	input: string,
	frame: number,
}

export type NetworkPacket = {
	input1: string,
	frame1: number,
	input2: string,
	frame2:number,
	input3:string,
	frame3: number,
	TimeSent: number,
	OtherPlayer: Instance,
}

export type StoragePacket = {
	RemoteInput:string,
	LocalInput: string,
	LocalPosition: CFrame,
	RemotePosition: CFrame,
	Frame: number,
	RemoteFrame: number,
}

export type PredictedData = {
	Frame: number,
	Input: string,
}

export type RemotedData = {
	RemoteFrame: number,
	RemoteInput: string,
}

return Types
