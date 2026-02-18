--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local sharedRoot = ReplicatedStorage:WaitForChild("CombatFramework")
local CombatConfig = require(sharedRoot:WaitForChild("CombatConfig"))

local serverRoot = ServerScriptService:WaitForChild("CombatFramework")
local Pass1_Test = require(serverRoot:WaitForChild("TestHarness"):WaitForChild("Pass1_Test"))

local Runner = {}

function Runner.setup()
	if not CombatConfig.TestHarnessEnabled then
		return
	end

	if CombatConfig.ActiveTestPass == 1 then
		Pass1_Test.setup()
	else
		warn(string.format("[P1_TEST] no setup module for pass %d", CombatConfig.ActiveTestPass))
	end
end

function Runner.run()
	if not CombatConfig.TestHarnessEnabled then
		return
	end

	if CombatConfig.ActiveTestPass == 1 then
		Pass1_Test.run()
	else
		warn(string.format("[P1_TEST] no run module for pass %d", CombatConfig.ActiveTestPass))
	end
end

return Runner
