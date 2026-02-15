--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local sharedFolder = ReplicatedStorage:WaitForChild("WanderingProps")
local Config = require(sharedFolder:WaitForChild("Config"))

type NodeData = {
    id: string,
    instance: BasePart,
    position: Vector3,
    nodeType: "spot" | "zone",
    nodeRole: "waypoint" | "spawn" | "despawn",
    connections: { string },
    size: Vector3?,
    poi: {
        poiType: "scenic" | "busy" | "social",
        weight: number,
        viewZone: BasePart?,
        seats: {
            {
                id: string,
                instance: BasePart,
                cframe: CFrame,
                approachNodeId: string?,
            }
        }?,
    }?,
    socialPOIId: string?,
}

local StartupValidator = {}

local function addError(errors: { string }, message: string): ()
    table.insert(errors, message)
end

local function validateModels(errors: { string }): ()
    local modelsFolder = ReplicatedStorage:FindFirstChild(Config.MODELS_FOLDER_NAME)
    if not modelsFolder then
        addError(errors, "[WP] ERROR: No NPC models found in ReplicatedStorage.WanderingPropModels")
        return
    end

    local models: { Model } = {}
    for _, child in ipairs(modelsFolder:GetChildren()) do
        if child:IsA("Model") then
            table.insert(models, child)
        end
    end

    if #models == 0 then
        addError(errors, "[WP] ERROR: No NPC models found in ReplicatedStorage.WanderingPropModels")
        return
    end

    for _, model in ipairs(models) do
        local hasAnimationController = model:FindFirstChildOfClass("AnimationController")
            or model:FindFirstChildWhichIsA("AnimationController", true)
        if not hasAnimationController then
            addError(errors, string.format("[WP] ERROR: Model '%s' missing AnimationController", model.Name))
        end

        if not model.PrimaryPart then
            addError(errors, string.format("[WP] ERROR: Model '%s' has no PrimaryPart set", model.Name))
        end
    end
end

local function validateNodeContracts(errors: { string }): ()
    local taggedNodes = CollectionService:GetTagged(Config.TAG_NODE)
    local nameSet: { [string]: boolean } = {}

    for _, tagged in ipairs(taggedNodes) do
        if not tagged:IsDescendantOf(Workspace) then
            continue
        end
        if not tagged:IsA("BasePart") then
            addError(errors, string.format("[WP] ERROR: '%s' tagged WP_Node is not a BasePart", tagged.Name))
            continue
        end

        if nameSet[tagged.Name] then
            addError(
                errors,
                string.format(
                    "[WP] ERROR: Duplicate WP_Node name '%s'. Rename nodes so each WP_Node has a unique Name.",
                    tagged.Name
                )
            )
        end
        nameSet[tagged.Name] = true

        local hasValidConnection = false
        for _, child in ipairs(tagged:GetChildren()) do
            if child:IsA("ObjectValue") then
                local target = child.Value
                if target == tagged then
                    addError(errors, string.format("[WP] ERROR: Node '%s' has a self-connection", tagged.Name))
                end

                if target and target:IsA("BasePart") and CollectionService:HasTag(target, Config.TAG_NODE) then
                    hasValidConnection = true
                end
            end
        end

        if not hasValidConnection then
            addError(
                errors,
                string.format(
                    "[WP] ERROR: Node '%s' has no valid connections (add ObjectValue children whose Value points to another WP_Node part)",
                    tagged.Name
                )
            )
        end
    end
end

local function validatePOIContracts(nodeGraph: any, errors: { string }): ()
    for _, poiNode: NodeData in ipairs(nodeGraph.getPOINodes()) do
        local poi = poiNode.poi
        if poi and poi.poiType == "scenic" then
            if not poi.viewZone then
                addError(errors, string.format("[WP] ERROR: Scenic POI '%s' missing WP_ViewZone child", poiNode.instance.Name))
            end
        elseif poi and poi.poiType == "social" then
            local seats = poi.seats or {}
            if #seats == 0 then
                addError(errors, string.format("[WP] ERROR: Social POI '%s' has no WP_Seat children", poiNode.instance.Name))
            end
            for _, seat in ipairs(seats) do
                if not seat.instance:IsA("BasePart") then
                    addError(
                        errors,
                        string.format("[WP] ERROR: Seat '%s' in POI '%s' is not a BasePart", seat.id, poiNode.instance.Name)
                    )
                end

                if seat.approachNodeId then
                    local approachNode: NodeData? = nodeGraph.getNode(seat.approachNodeId)
                    if not approachNode then
                        addError(
                            errors,
                            string.format(
                                "[WP] ERROR: Seat '%s' in social POI '%s' references missing approach node '%s'",
                                seat.id,
                                poiNode.instance.Name,
                                seat.approachNodeId
                            )
                        )
                    elseif approachNode.id ~= poiNode.id and approachNode.socialPOIId ~= poiNode.id then
                        addError(
                            errors,
                            string.format(
                                "[WP] ERROR: Seat '%s' in social POI '%s' points to node '%s' that is not in this social POI graph",
                                seat.id,
                                poiNode.instance.Name,
                                seat.approachNodeId
                            )
                        )
                    end
                end
            end
        end
    end

    for _, seatTagged in ipairs(CollectionService:GetTagged(Config.TAG_SEAT)) do
        if not seatTagged:IsDescendantOf(Workspace) then
            continue
        end
        if not seatTagged:IsA("BasePart") then
            addError(errors, string.format("[WP] ERROR: Seat '%s' in POI 'unknown' is not a BasePart", seatTagged.Name))
        end
    end

    for _, node: NodeData in ipairs(nodeGraph.getAllNodes()) do
        if node.socialPOIId then
            local owner = nodeGraph.getNode(node.socialPOIId)
            if not owner or not owner.poi or owner.poi.poiType ~= "social" then
                addError(
                    errors,
                    string.format(
                        "[WP] ERROR: Node '%s' has SocialPOIId '%s' but no matching social POI node exists",
                        node.id,
                        node.socialPOIId
                    )
                )
            end
        end
    end
end

local function validateConfigValues(errors: { string }): ()
    if Config.MIN_POPULATION > Config.MAX_POPULATION then
        addError(
            errors,
            string.format(
                "[WP] ERROR: Config.MIN_POPULATION (%s) > Config.MAX_POPULATION (%s)",
                tostring(Config.MIN_POPULATION),
                tostring(Config.MAX_POPULATION)
            )
        )
    end

    if Config.SPAWN_INTERVAL < Config.SERVER_TICK_RATE then
        addError(
            errors,
            string.format(
                "[WP] ERROR: Config.SPAWN_INTERVAL (%s) must be >= Config.SERVER_TICK_RATE (%s)",
                tostring(Config.SPAWN_INTERVAL),
                tostring(Config.SERVER_TICK_RATE)
            )
        )
    end

    if Config.BASE_WALK_SPEED <= 0 then
        addError(errors, "[WP] ERROR: Config.BASE_WALK_SPEED must be > 0")
    end

    if Config.CONTROLLER_DEBUG_INTERVAL <= 0 then
        addError(errors, "[WP] ERROR: Config.CONTROLLER_DEBUG_INTERVAL must be > 0")
    end

    if Config.MIN_POIS_PER_ROUTE > Config.MAX_POIS_PER_ROUTE then
        addError(errors, "[WP] ERROR: Config.MIN_POIS_PER_ROUTE must be <= Config.MAX_POIS_PER_ROUTE")
    end

    if Config.POI_REPEAT_CHANCE < 0 or Config.POI_REPEAT_CHANCE > 1 then
        addError(errors, "[WP] ERROR: Config.POI_REPEAT_CHANCE must be between 0 and 1")
    end

    if Config.SCENIC_DWELL_MIN > Config.SCENIC_DWELL_MAX then
        addError(errors, "[WP] ERROR: Config.SCENIC_DWELL_MIN must be <= Config.SCENIC_DWELL_MAX")
    end

    if Config.SOCIAL_DWELL_MIN > Config.SOCIAL_DWELL_MAX then
        addError(errors, "[WP] ERROR: Config.SOCIAL_DWELL_MIN must be <= Config.SOCIAL_DWELL_MAX")
    end

    if Config.DESPAWN_DWELL_MIN > Config.DESPAWN_DWELL_MAX then
        addError(errors, "[WP] ERROR: Config.DESPAWN_DWELL_MIN must be <= Config.DESPAWN_DWELL_MAX")
    end

    if Config.GROUP_SIZE_MIN > Config.GROUP_SIZE_MAX then
        addError(errors, "[WP] ERROR: Config.GROUP_SIZE_MIN must be <= Config.GROUP_SIZE_MAX")
    end

    if Config.SPAWN_BURST_PER_PASS < 1 then
        addError(errors, "[WP] ERROR: Config.SPAWN_BURST_PER_PASS must be >= 1")
    end

    if Config.SPAWN_MAX_ATTEMPTS_PER_PASS < Config.SPAWN_BURST_PER_PASS then
        addError(
            errors,
            "[WP] ERROR: Config.SPAWN_MAX_ATTEMPTS_PER_PASS must be >= Config.SPAWN_BURST_PER_PASS"
        )
    end

    if Config.WALK_ANIMATION_ID == "rbxassetid://0"
        or Config.IDLE_ANIMATION_ID == "rbxassetid://0"
        or Config.SIT_ANIMATION_ID == "rbxassetid://0"
    then
        addError(errors, "[WP] ERROR: Animation IDs not configured in Config.luau (still using placeholder)")
    end
end

local function validateGraphReachability(nodeGraph: any, errors: { string }): ()
    local spawns: { NodeData } = nodeGraph.getSpawnNodes()
    local despawns: { NodeData } = nodeGraph.getDespawnNodes()
    local pois: { NodeData } = nodeGraph.getPOINodes()

    if #spawns == 0 then
        addError(errors, "[WP] ERROR: No spawn nodes found. Tag a part WP_Node with NodeRole=\"spawn\"")
    end

    if #despawns == 0 then
        addError(errors, "[WP] ERROR: No despawn nodes found. Tag a part WP_Node with NodeRole=\"despawn\"")
    end

    if #pois == 0 then
        addError(errors, "[WP] ERROR: No points of interest found. Tag a part with WP_POI")
    end

    if #spawns > 0 and #despawns > 0 then
        local hasAnyPath = false
        for _, spawnNode in ipairs(spawns) do
            for _, despawnNode in ipairs(despawns) do
                if nodeGraph.findPath(spawnNode.id, despawnNode.id, nil) then
                    hasAnyPath = true
                    break
                end
            end
            if hasAnyPath then
                break
            end
        end

        if not hasAnyPath then
            addError(errors, "[WP] ERROR: No path exists from any spawn to any despawn. Check node connections.")
        end
    end

    if #spawns > 0 and #despawns > 0 then
        for _, poiNode in ipairs(pois) do
            local reachableFromSpawn = false
            for _, spawnNode in ipairs(spawns) do
                if nodeGraph.findPath(spawnNode.id, poiNode.id, nil) then
                    reachableFromSpawn = true
                    break
                end
            end

            if not reachableFromSpawn then
                addError(
                    errors,
                    string.format("[WP] ERROR: POI '%s' is unreachable from all spawn nodes", poiNode.instance.Name)
                )
            end

            local canReachDespawn = false
            for _, despawnNode in ipairs(despawns) do
                if nodeGraph.findPath(poiNode.id, despawnNode.id, nil) then
                    canReachDespawn = true
                    break
                end
            end

            if not canReachDespawn then
                addError(
                    errors,
                    string.format("[WP] ERROR: POI '%s' cannot reach any despawn node", poiNode.instance.Name)
                )
            end
        end
    end
end

function StartupValidator.validate(nodeGraph: any): (boolean, { string })
    local errors: { string } = {}

    validateModels(errors)
    validateConfigValues(errors)
    validateNodeContracts(errors)
    validatePOIContracts(nodeGraph, errors)
    validateGraphReachability(nodeGraph, errors)

    return #errors == 0, errors
end

return StartupValidator
