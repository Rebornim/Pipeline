--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local configModule = ReplicatedStorage:WaitForChild("Config", 10)
assert(configModule and configModule:IsA("ModuleScript"), "WanderingProps NPCAnimator: ReplicatedStorage.Config not found")

local Config = require(configModule)

local NPCAnimator = {}

type ClientNPC = {
	id: string,
	animator: Animator?,
	walkTrack: AnimationTrack?,
	idleTrack: AnimationTrack?,
	sitTrack: AnimationTrack?,
}

type RuntimeState = {
	frozen: boolean,
	walkSpeedScale: number,
}

local runtimeByNpcId: { [string]: RuntimeState } = {}
local reportedInvalidAnimationIds = false

local function getRuntimeState(npc: ClientNPC): RuntimeState
	local state = runtimeByNpcId[npc.id]
	if not state then
		state = {
			frozen = false,
			walkSpeedScale = 1,
		}
		runtimeByNpcId[npc.id] = state
	end
	return state
end

local function isInvalidAnimationId(animationId: unknown): boolean
	return type(animationId) ~= "string" or animationId == "" or animationId == "rbxassetid://0"
end

local function hasValidAnimationIds(): boolean
	local valid = not isInvalidAnimationId(Config.ANIM_WALK)
		and not isInvalidAnimationId(Config.ANIM_IDLE)
		and not isInvalidAnimationId(Config.ANIM_SIT)

	if not valid and not reportedInvalidAnimationIds then
		reportedInvalidAnimationIds = true
		warn(
			"[WanderingProps/NPCAnimator] Animation IDs not configured in Config.luau — replace ANIM_WALK/IDLE/SIT with valid IDs"
		)
	end

	return valid
end

local function createTrack(animator: Animator, animationId: string): AnimationTrack
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	local track = animator:LoadAnimation(animation)
	animation:Destroy()
	return track
end

local function stopTrack(track: AnimationTrack?): ()
	if track and track.IsPlaying then
		track:Stop(0.1)
	end
end

local function playTrack(track: AnimationTrack, speed: number): ()
	if not track.IsPlaying then
		track:Play(0.1, 1, 1)
	end
	track:AdjustSpeed(speed)
end

function NPCAnimator.setup(npc: ClientNPC): ()
	local animator = npc.animator
	if not animator then
		warn(("[WanderingProps/NPCAnimator] NPC %s missing Animator; cannot setup animations"):format(npc.id))
		return
	end

	if not hasValidAnimationIds() then
		npc.walkTrack = nil
		npc.idleTrack = nil
		npc.sitTrack = nil
		return
	end

	stopTrack(npc.walkTrack)
	stopTrack(npc.idleTrack)
	stopTrack(npc.sitTrack)

	npc.walkTrack = createTrack(animator, Config.ANIM_WALK)
	npc.idleTrack = createTrack(animator, Config.ANIM_IDLE)
	npc.sitTrack = createTrack(animator, Config.ANIM_SIT)

	local state = getRuntimeState(npc)
	state.frozen = false
	state.walkSpeedScale = 1
end

function NPCAnimator.playWalk(npc: ClientNPC, speed: number): ()
	local walkTrack = npc.walkTrack
	if not walkTrack then
		return
	end

	stopTrack(npc.idleTrack)
	stopTrack(npc.sitTrack)

	local naturalSpeed = tonumber(Config.WALK_ANIMATION_NATURAL_SPEED) or 1
	if naturalSpeed <= 0 then
		naturalSpeed = 1
	end

	local state = getRuntimeState(npc)
	state.walkSpeedScale = speed / naturalSpeed

	if state.frozen then
		playTrack(walkTrack, 0)
	else
		playTrack(walkTrack, state.walkSpeedScale)
	end
end

function NPCAnimator.playIdle(npc: ClientNPC): ()
	local idleTrack = npc.idleTrack
	if not idleTrack then
		return
	end

	stopTrack(npc.walkTrack)
	stopTrack(npc.sitTrack)

	local state = getRuntimeState(npc)
	if state.frozen then
		playTrack(idleTrack, 0)
	else
		playTrack(idleTrack, 1)
	end
end

function NPCAnimator.playSit(npc: ClientNPC): ()
	local sitTrack = npc.sitTrack
	if not sitTrack then
		return
	end

	stopTrack(npc.walkTrack)
	stopTrack(npc.idleTrack)

	local state = getRuntimeState(npc)
	if state.frozen then
		playTrack(sitTrack, 0)
	else
		playTrack(sitTrack, 1)
	end
end

function NPCAnimator.stopAll(npc: ClientNPC): ()
	stopTrack(npc.walkTrack)
	stopTrack(npc.idleTrack)
	stopTrack(npc.sitTrack)

	local state = getRuntimeState(npc)
	state.frozen = false
	state.walkSpeedScale = 1
	runtimeByNpcId[npc.id] = nil
end

function NPCAnimator.freeze(npc: ClientNPC): ()
	local state = getRuntimeState(npc)
	state.frozen = true

	local animator = npc.animator
	if not animator then
		return
	end

	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		track:AdjustSpeed(0)
	end
end

function NPCAnimator.unfreeze(npc: ClientNPC): ()
	local state = getRuntimeState(npc)
	state.frozen = false

	local animator = npc.animator
	if not animator then
		return
	end

	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		if npc.walkTrack and track == npc.walkTrack then
			track:AdjustSpeed(state.walkSpeedScale)
		else
			track:AdjustSpeed(1)
		end
	end
end

return NPCAnimator
