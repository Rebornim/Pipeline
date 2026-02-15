local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingPropsShared")
local Config = require(sharedFolder:WaitForChild("Config"))

local LODController = {}

function LODController.computeTier(npcPosition: Vector3, playerPosition: Vector3): string
	local distance = (npcPosition - playerPosition).Magnitude
	if distance <= Config.LODNearDistance then
		return "near"
	end
	if distance <= Config.LODLowDistance then
		return "low"
	end
	if distance <= Config.LODMidDistance then
		return "mid"
	end
	return "far"
end

function LODController.shouldRaycast(tier: string, globalFrame: number, raycastPhase: number): boolean
	if tier == "near" then
		return true
	end
	if tier == "low" then
		local skip = math.max(1, Config.LODLowRaycastSkip)
		return ((globalFrame + raycastPhase) % skip) == 0
	end
	if tier == "mid" then
		local skip = math.max(1, Config.LODMidRaycastSkip)
		return ((globalFrame + raycastPhase) % skip) == 0
	end
	return false
end

function LODController.shouldAnimate(tier: string): boolean
	return tier == "near" or tier == "low"
end

function LODController.shouldMove(tier: string): boolean
	return tier ~= "far"
end

return LODController
