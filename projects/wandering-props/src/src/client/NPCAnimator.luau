--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingProps")
local Config = require(sharedFolder:WaitForChild("Config"))

type AnimatorHandle = {
    animator: Animator,
    walkTrack: AnimationTrack,
    idleTrack: AnimationTrack,
    sitTrack: AnimationTrack,
}

local NPCAnimator = {}

type RuntimeState = {
    enabled: boolean,
    activeTrack: AnimationTrack?,
    playbackRate: number,
    steppedFps: number?,
    accumulator: number,
}

local stateByHandle: { [AnimatorHandle]: RuntimeState } = {}
local stepConnection: RBXScriptConnection? = nil

local function ensureStepConnection(): ()
    if stepConnection then
        return
    end

    stepConnection = RunService.Heartbeat:Connect(function(dt)
        for _, state in pairs(stateByHandle) do
            if not state.enabled then
                continue
            end

            local steppedFps = state.steppedFps
            local activeTrack = state.activeTrack
            if not steppedFps or steppedFps <= 0 or not activeTrack then
                continue
            end

            local validTrack = pcall(function()
                return activeTrack.Length
            end)
            if not validTrack then
                state.activeTrack = nil
                state.accumulator = 0
                continue
            end

            if not activeTrack.IsPlaying then
                activeTrack:Play(0.1, 1, 0)
                activeTrack:AdjustSpeed(0)
            end

            local stepInterval = 1 / steppedFps
            state.accumulator += dt
            local stepCount = math.floor(state.accumulator / stepInterval)
            if stepCount <= 0 then
                continue
            end

            state.accumulator -= stepCount * stepInterval
            local deltaTimePosition = stepCount * stepInterval * state.playbackRate

            local currentPosition = activeTrack.TimePosition
            local nextPosition = currentPosition + deltaTimePosition
            local trackLength = activeTrack.Length
            if trackLength > 0 then
                if activeTrack.Looped then
                    nextPosition = nextPosition % trackLength
                else
                    nextPosition = math.min(nextPosition, trackLength)
                end
            end

            pcall(function()
                activeTrack.TimePosition = nextPosition
            end)
        end
    end)
end

local function getState(handle: AnimatorHandle): RuntimeState
    local state = stateByHandle[handle]
    if state then
        return state
    end

    ensureStepConnection()
    state = {
        enabled = true,
        activeTrack = nil,
        playbackRate = 1,
        steppedFps = nil,
        accumulator = 0,
    }
    stateByHandle[handle] = state
    return state
end

local function loadTrack(animator: Animator, animationId: string): AnimationTrack
    local animation = Instance.new("Animation")
    animation.AnimationId = animationId
    local track = animator:LoadAnimation(animation)
    animation:Destroy()
    return track
end

local function stopTrack(track: AnimationTrack): ()
    local ok, isPlaying = pcall(function()
        return track.IsPlaying
    end)
    if ok and isPlaying then
        pcall(function()
            track:Stop(0.1)
        end)
    end
end

local function playTrack(track: AnimationTrack, speed: number, steppedFps: number?): ()
    local playbackSpeed = if steppedFps and steppedFps > 0 then 0 else speed
    if not track.IsPlaying then
        track:Play(0.1, 1, playbackSpeed)
    else
        track:AdjustSpeed(playbackSpeed)
    end
end

local function isEnabled(handle: AnimatorHandle): boolean
    return getState(handle).enabled
end

local function selectTrack(
    handle: AnimatorHandle,
    targetTrack: AnimationTrack,
    playbackRate: number,
    steppedFps: number?
): ()
    if targetTrack ~= handle.walkTrack then
        stopTrack(handle.walkTrack)
    end
    if targetTrack ~= handle.idleTrack then
        stopTrack(handle.idleTrack)
    end
    if targetTrack ~= handle.sitTrack then
        stopTrack(handle.sitTrack)
    end

    local state = getState(handle)
    state.activeTrack = targetTrack
    state.playbackRate = math.max(0.01, playbackRate)
    state.steppedFps = if steppedFps and steppedFps > 0 then steppedFps else nil
    state.accumulator = 0

    playTrack(targetTrack, state.playbackRate, state.steppedFps)
end

function NPCAnimator.setup(model: Model): AnimatorHandle?
    local animationController = model:FindFirstChildOfClass("AnimationController")
    if not animationController then
        return nil
    end

    -- Reset pooled rig animator so stale tracks from prior uses cannot accumulate.
    for _, child in ipairs(animationController:GetChildren()) do
        if child:IsA("Animator") then
            child:Destroy()
        end
    end
    local animator = Instance.new("Animator")
    animator.Parent = animationController

    local walkTrack = loadTrack(animator, Config.WALK_ANIMATION_ID)
    local idleTrack = loadTrack(animator, Config.IDLE_ANIMATION_ID)
    local sitTrack = loadTrack(animator, Config.SIT_ANIMATION_ID)

    local handle: AnimatorHandle = {
        animator = animator,
        walkTrack = walkTrack,
        idleTrack = idleTrack,
        sitTrack = sitTrack,
    }
    local state = getState(handle)
    state.enabled = true
    return handle
end

function NPCAnimator.playWalk(
    handle: AnimatorHandle,
    walkSpeed: number,
    speedMultiplier: number?,
    steppedFps: number?
): ()
    if not isEnabled(handle) then
        return
    end

    local baseSpeed = math.max(0.001, tonumber(Config.BASE_WALK_SPEED) or 10)
    local multiplier = if speedMultiplier and speedMultiplier > 0 then speedMultiplier else 1
    selectTrack(handle, handle.walkTrack, math.max(0.01, (walkSpeed / baseSpeed) * multiplier), steppedFps)
end

function NPCAnimator.playIdle(handle: AnimatorHandle, speedMultiplier: number?, steppedFps: number?): ()
    if not isEnabled(handle) then
        return
    end

    local multiplier = if speedMultiplier and speedMultiplier > 0 then speedMultiplier else 1
    selectTrack(handle, handle.idleTrack, math.max(0.01, multiplier), steppedFps)
end

function NPCAnimator.playSit(handle: AnimatorHandle, speedMultiplier: number?, steppedFps: number?): ()
    if not isEnabled(handle) then
        return
    end

    local multiplier = if speedMultiplier and speedMultiplier > 0 then speedMultiplier else 1
    selectTrack(handle, handle.sitTrack, math.max(0.01, multiplier), steppedFps)
end

function NPCAnimator.stopAll(handle: AnimatorHandle): ()
    stopTrack(handle.walkTrack)
    stopTrack(handle.idleTrack)
    stopTrack(handle.sitTrack)

    local state = stateByHandle[handle]
    if state then
        state.activeTrack = nil
        state.accumulator = 0
    end
end

function NPCAnimator.setEnabled(handle: AnimatorHandle, enabled: boolean): ()
    local state = getState(handle)
    state.enabled = enabled
    if not enabled then
        NPCAnimator.stopAll(handle)
    end
end

function NPCAnimator.cleanup(handle: AnimatorHandle): ()
    NPCAnimator.stopAll(handle)
    pcall(function()
        handle.walkTrack:Destroy()
    end)
    pcall(function()
        handle.idleTrack:Destroy()
    end)
    pcall(function()
        handle.sitTrack:Destroy()
    end)
    stateByHandle[handle] = nil
end

return NPCAnimator
