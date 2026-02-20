--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))

local Runner = {}
local Pass5Test = require(script.Parent:WaitForChild("Pass5_Test"))
local Pass5CriticVerify = require(script.Parent:WaitForChild("Pass5_CriticVerify"))

local function useCriticVerify(): boolean
	return Workspace:GetAttribute("P5CriticVerifyEnabled") == true
end

function Runner.isEnabled(): boolean
	return CombatConfig.TestHarnessEnabled == true or Workspace:GetAttribute("CombatTestHarnessEnabled") == true
end

function Runner.setup(): ()
	if not Runner.isEnabled() then
		return
	end
	if useCriticVerify() then
		return
	end
	Pass5Test.setup()
end

function Runner.run(): ()
	if not Runner.isEnabled() then
		return
	end
	if useCriticVerify() then
		Pass5CriticVerify.run()
		return
	end
	Pass5Test.run()
end

return Runner
