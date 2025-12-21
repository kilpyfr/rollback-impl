--!strict
local Debug = {}

type DebugUi = {
	Frame: {
		localframe: TextLabel,
		remoteframe: TextLabel,
		rollbackframes: TextLabel
	} & Frame
}

local UI: DebugUi

function Debug.AddUI(Gui: ScreenGui)
	UI = Gui :: DebugUi
end

function Debug.UpdateFrames(localframe: number, remoteframe: number)
	UI.Frame.localframe.Text = "local frame: " .. localframe
	UI.Frame.remoteframe.Text = "remote frame: " .. remoteframe
end

function Debug.UpdateRollbackFrames(rollbackframes: number)
	UI.Frame.rollbackframes.Text = "rollback frames: " .. rollbackframes
end

return Debug
