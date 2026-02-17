local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

local api = require(script.Parent:WaitForChild("WanderingPropsAPI"))

task.wait(10)

print("[P8_MANUAL] SetMode pause(20)")
api.SetMode("pause", 20)

task.wait(12)
print(string.format("[P8_MANUAL] ActiveMode=%s", api.GetActiveMode()))

task.wait(6)
print("[P8_MANUAL] SetMode evacuate(18)")
api.SetMode("evacuate", 18)

task.wait(22)
print(string.format("[P8_MANUAL] ActiveMode=%s", api.GetActiveMode()))

task.wait(10)
print("[P8_MANUAL] SetMode scatter(10)")
api.SetMode("scatter", 10)

task.wait(14)
print(string.format("[P8_MANUAL] ActiveMode=%s", api.GetActiveMode()))

task.wait(8)
local player = Players:GetPlayers()[1]
if player then
	print(string.format("[P8_MANUAL] DesyncPlayer %s", player.Name))
	api.DesyncPlayer(player)
	task.wait(6)
	print(string.format("[P8_MANUAL] ResyncPlayer %s", player.Name))
	api.ResyncPlayer(player)
end

task.wait(4)
print(string.format("[P8_MANUAL] ActiveMode=%s", api.GetActiveMode()))
