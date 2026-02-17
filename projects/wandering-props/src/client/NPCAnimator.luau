local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingPropsShared")
local Config = require(sharedFolder:WaitForChild("Config"))

local NPCAnimator = {}
local walkAnimation = Instance.new("Animation")
walkAnimation.AnimationId = Config.WalkAnimationId
local idleAnimation = Instance.new("Animation")
idleAnimation.AnimationId = Config.IdleAnimationId
local sitAnimation = Instance.new("Animation")
sitAnimation.AnimationId = Config.SitAnimationId

function NPCAnimator.setup(animator: Animator)
	local walkTrack = animator:LoadAnimation(walkAnimation)
	local idleTrack = animator:LoadAnimation(idleAnimation)
	walkTrack.Looped = true
	idleTrack.Looped = true
	walkTrack.Priority = Enum.AnimationPriority.Movement
	idleTrack.Priority = Enum.AnimationPriority.Idle

	return walkTrack, idleTrack
end

function NPCAnimator.update(npc, isMoving: boolean)
	-- Self-heal any lingering sit track when NPC is not in sitting state.
	if npc.sitTrack and npc.sitTrack.IsPlaying then
		npc.sitTrack:Stop(0.1)
	end

	if isMoving then
		if npc.idleTrack.IsPlaying then
			npc.idleTrack:Stop(0)
		end
		if not npc.walkTrack.IsPlaying then
			npc.walkTrack:Play(0.1)
		end

		local baseSpeed = Config.WalkAnimBaseSpeed
		local speedScale = 1
		if baseSpeed > 0 then
			speedScale = npc.walkSpeed / baseSpeed
		end
		npc.walkTrack:AdjustSpeed(speedScale)
	else
		if npc.walkTrack.IsPlaying then
			npc.walkTrack:Stop(0.15)
		end
		if not npc.idleTrack.IsPlaying then
			npc.idleTrack:Play(0.15)
		end
	end
end

function NPCAnimator.setupSit(animator: Animator): AnimationTrack
	local sitTrack = animator:LoadAnimation(sitAnimation)
	sitTrack.Looped = true
	sitTrack.Priority = Enum.AnimationPriority.Action

	return sitTrack
end

function NPCAnimator.playSit(npc)
	if npc.walkTrack.IsPlaying then
		npc.walkTrack:Stop(0.15)
	end
	if npc.idleTrack.IsPlaying then
		npc.idleTrack:Stop(0.15)
	end
	if npc.sitTrack and not npc.sitTrack.IsPlaying then
		npc.sitTrack:Play(0.15)
	end
	if npc.sitTrack then
		npc.sitTrack:AdjustSpeed(1)
	end
end

function NPCAnimator.stopSit(npc)
	if npc.sitTrack and npc.sitTrack.IsPlaying then
		npc.sitTrack:Stop(0.15)
	end
end

function NPCAnimator.stopAll(npc)
	if npc.walkTrack.IsPlaying then
		npc.walkTrack:Stop(0)
	end
	if npc.idleTrack.IsPlaying then
		npc.idleTrack:Stop(0)
	end
	if npc.sitTrack and npc.sitTrack.IsPlaying then
		npc.sitTrack:Stop(0)
	end
end

return NPCAnimator
