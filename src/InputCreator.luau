--!strict
local InputCreator = {}

local ContextTemplate: InputContext = script.Context
local ActionTemplate: InputAction = script.Action
local BindingTemplate: InputBinding = script.Binding

function InputCreator.NewContext(name: string) : InputContext
	local Context = ContextTemplate:Clone()
	
	Context.Name = name
	Context.Parent = script
	
	return Context
end

function InputCreator.NewAction(Context: InputContext, name: string) : InputAction
	local Action = ActionTemplate:Clone() 
	Action.Name = name
	Action.Parent = Context
	
	return Action
end

function InputCreator.NewBinding(Action: InputAction, name: string) : InputBinding
	local Binding = BindingTemplate:Clone()
	Binding.Name = name
	Binding.Parent = Action

	return Binding
end


return InputCreator
