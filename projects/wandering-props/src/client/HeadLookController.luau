local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingPropsShared")
local Config = require(sharedFolder:WaitForChild("Config"))

local HeadLookController = {}

function HeadLookController.init(npc, neckMotor: Motor6D?, neckOriginalC0: CFrame?)
	npc.headLookNeckMotor = neckMotor
	npc.headLookOriginalC0 = neckOriginalC0
	npc.headLookActive = false
	npc.headLookAlpha = 0
	npc.headLookEndTime = 0
	local checkInterval = math.max(0.1, Config.HeadLookCheckInterval)
	npc.headLookNextCheckTime = Workspace:GetServerTimeNow() + math.random() * checkInterval

	if not npc.headLookNeckMotor or not npc.headLookOriginalC0 then
		for _, desc in ipairs(npc.model:GetDescendants()) do
			if desc:IsA("Motor6D") and desc.Name == "Neck" then
				npc.headLookNeckMotor = desc
				npc.headLookOriginalC0 = desc.C0
				break
			end
		end
	end
end

function HeadLookController.update(npc, playerPosition: Vector3, dt: number, now: number)
	local neckMotor = npc.headLookNeckMotor
	local originalC0 = npc.headLookOriginalC0
	if not neckMotor or not originalC0 then
		return
	end
	if not neckMotor.Parent then
		return
	end

	if not npc.headLookActive
		and (npc.headLookAlpha or 0) <= 0
		and now < (npc.headLookNextCheckTime or 0)
	then
		return
	end

	if now >= (npc.headLookNextCheckTime or 0) then
		local rootPart = npc.model.PrimaryPart
		if rootPart then
			local distance = (playerPosition - rootPart.Position).Magnitude
			if distance <= Config.HeadLookDistance then
				if npc.headLookActive then
					npc.headLookEndTime = now + Config.HeadLookDuration
				elseif math.random() <= Config.HeadLookChance then
					npc.headLookActive = true
					npc.headLookEndTime = now + Config.HeadLookDuration
					if Config.DiagnosticsEnabled then
						print(string.format("[WanderingProps] HEAD_LOOK_START %s distance=%.1f", npc.id, distance))
					end
				end
			end
		end
		npc.headLookNextCheckTime = now + math.max(0.1, Config.HeadLookCheckInterval)
	end

	if npc.headLookActive and now >= (npc.headLookEndTime or 0) then
		npc.headLookActive = false
	end

	local targetAlpha = if npc.headLookActive then 1 else 0
	local currentAlpha = npc.headLookAlpha or 0
	local blendAlpha = math.min(1, math.max(0, dt) * math.max(0, Config.HeadLookLerpSpeed))
	local nextAlpha = currentAlpha + (targetAlpha - currentAlpha) * blendAlpha
	npc.headLookAlpha = nextAlpha

	if nextAlpha < 0.01 then
		neckMotor.C0 = originalC0
		npc.headLookAlpha = 0
		return
	end

	local rootPart = npc.model.PrimaryPart
	if not rootPart then
		return
	end

	local headPos = rootPart.Position
	if neckMotor.Part1 then
		headPos = neckMotor.Part1.Position
	end

	local toPlayer = playerPosition - headPos
	if toPlayer.Magnitude <= 0.001 then
		neckMotor.C0 = originalC0
		return
	end

	local localDir = rootPart.CFrame:VectorToObjectSpace(toPlayer.Unit)
	local yaw = math.atan2(localDir.X, -localDir.Z)
	local forward = math.sqrt(localDir.X * localDir.X + localDir.Z * localDir.Z)
	local pitch = math.atan2(-localDir.Y, forward)

	local maxYaw = math.rad(Config.HeadLookMaxYaw)
	local maxPitch = math.rad(Config.HeadLookMaxPitch)
	local breakYaw = maxYaw * 0.8
	local breakPitch = maxPitch * 0.8
	if npc.headLookActive and (math.abs(yaw) > breakYaw or math.abs(pitch) > breakPitch) then
		npc.headLookActive = false
		npc.headLookEndTime = 0
		npc.headLookNextCheckTime = now + Config.HeadLookCheckInterval
		npc.headLookAlpha = currentAlpha + (0 - currentAlpha) * blendAlpha
		if npc.headLookAlpha < 0.01 then
			npc.headLookAlpha = 0
		end
		neckMotor.C0 = neckMotor.C0:Lerp(originalC0, blendAlpha)
		return
	end

	yaw = math.clamp(yaw, -maxYaw, maxYaw)
	pitch = math.clamp(pitch, -maxPitch, maxPitch)

	local rotation = CFrame.Angles(pitch * nextAlpha, -yaw * nextAlpha, 0)
	neckMotor.C0 = originalC0 * rotation
end

function HeadLookController.reset(npc)
	if npc.headLookNeckMotor and npc.headLookOriginalC0 then
		npc.headLookNeckMotor.C0 = npc.headLookOriginalC0
	end
	npc.headLookAlpha = 0
	npc.headLookActive = false
	npc.headLookEndTime = 0
	npc.headLookNextCheckTime = 0
end

return HeadLookController
