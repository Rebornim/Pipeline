--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local configModule = ReplicatedStorage:WaitForChild("Config", 10)
assert(configModule and configModule:IsA("ModuleScript"), "WanderingProps SeatManager: ReplicatedStorage.Config not found")

local typesModule = ReplicatedStorage:WaitForChild("Types", 10)
assert(typesModule and typesModule:IsA("ModuleScript"), "WanderingProps SeatManager: ReplicatedStorage.Types not found")

local Config = require(configModule)
local Types = require(typesModule)
type _RouteStep = Types.RouteStep

type SeatReservation = {
	startTime: number,
	endTime: number,
	npcId: string?,
}

type SeatRecord = {
	seat: Part,
	groupKey: Instance,
	reservations: { SeatReservation },
}

type SocialRecord = {
	poi: Part,
	seats: { SeatRecord },
	capacityCap: number,
}

local SeatManager = {}

local DEFAULT_CAPACITY_CAP = 0.75

local socialByPOI: { [Part]: SocialRecord } = {}
local initialized = false

local function debugLog(message: string): ()
	if Config.DEBUG_ENABLED then
		warn(("[WanderingProps/SeatManager] %s"):format(message))
	end
end

local function intervalsOverlap(startA: number, endA: number, startB: number, endB: number): boolean
	return startA < endB and startB < endA
end

local function getCapacityCap(socialPOI: Part): number
	local raw = socialPOI:GetAttribute("CapacityCap")
	if typeof(raw) == "number" then
		return math.clamp(raw, 0, 1)
	end
	return DEFAULT_CAPACITY_CAP
end

local function pruneExpiredReservations(nowTime: number): ()
	for _, socialRecord in pairs(socialByPOI) do
		for _, seatRecord in ipairs(socialRecord.seats) do
			for i = #seatRecord.reservations, 1, -1 do
				local reservation = seatRecord.reservations[i]
				if reservation.endTime <= nowTime then
					table.remove(seatRecord.reservations, i)
				end
			end
		end
	end
end

local function resolveSeatGroupKey(seat: Part, socialPOI: Part): Instance
	local topChildUnderSocial: Instance = seat
	local cursor: Instance? = seat

	while cursor and cursor ~= socialPOI do
		topChildUnderSocial = cursor
		cursor = cursor.Parent
	end

	return topChildUnderSocial
end

function SeatManager.init(): ()
	socialByPOI = {}
	initialized = false

	local taggedSocialPOIs = CollectionService:GetTagged(Config.TAG_SOCIAL)
	for _, tagged in ipairs(taggedSocialPOIs) do
		if not tagged:IsDescendantOf(Workspace) then
			continue
		end

		if not tagged:IsA("Part") then
			debugLog(("Ignoring non-Part social POI tagged instance: %s"):format(tagged:GetFullName()))
			continue
		end

		socialByPOI[tagged] = {
			poi = tagged,
			seats = {},
			capacityCap = getCapacityCap(tagged),
		}
	end

	local taggedSeats = CollectionService:GetTagged(Config.TAG_SEAT)
	for _, taggedSeat in ipairs(taggedSeats) do
		if not taggedSeat:IsDescendantOf(Workspace) then
			continue
		end

		if not taggedSeat:IsA("Part") then
			debugLog(("Ignoring non-Part seat tagged instance: %s"):format(taggedSeat:GetFullName()))
			continue
		end

		local socialPOI: Part? = nil
		local cursor = taggedSeat.Parent
		while cursor do
			if cursor:IsA("Part") and socialByPOI[cursor] then
				socialPOI = cursor
				break
			end
			cursor = cursor.Parent
		end

		if not socialPOI then
			debugLog(("Seat %s has no ancestor social POI"):format(taggedSeat:GetFullName()))
			continue
		end

		local socialRecord = socialByPOI[socialPOI]
		if not socialRecord then
			continue
		end

		table.insert(socialRecord.seats, {
			seat = taggedSeat,
			groupKey = resolveSeatGroupKey(taggedSeat, socialPOI),
			reservations = {},
		})
	end

	initialized = true
end

function SeatManager.reserveSeat(
	socialPOI: Part,
	arrivalTime: number,
	duration: number,
	npcId: string?
): Part?
	if not initialized then
		SeatManager.init()
	end

	if duration <= 0 then
		return nil
	end

	local socialRecord = socialByPOI[socialPOI]
	if not socialRecord then
		debugLog(("reserveSeat called with unknown social POI: %s"):format(socialPOI:GetFullName()))
		return nil
	end

	pruneExpiredReservations(arrivalTime)

	local seats = socialRecord.seats
	if #seats == 0 then
		return nil
	end

	local maxOccupied = math.floor(#seats * socialRecord.capacityCap)
	-- For tiny setups (for example, one-seat social POIs), permit at least one
	-- occupant when capacity cap is positive so social POIs remain usable.
	if socialRecord.capacityCap > 0 then
		maxOccupied = math.max(1, maxOccupied)
	end
	if maxOccupied <= 0 then
		return nil
	end

	local endTime = arrivalTime + duration
	local occupiedSeats = 0
	local groupOccupancy: { [Instance]: number } = {}
	local candidates: { SeatRecord } = {}

	for _, seatRecord in ipairs(seats) do
		local blocked = false

		for _, reservation in ipairs(seatRecord.reservations) do
			if intervalsOverlap(arrivalTime, endTime, reservation.startTime, reservation.endTime) then
				blocked = true
				break
			end
		end

		if blocked then
			occupiedSeats += 1
			groupOccupancy[seatRecord.groupKey] = (groupOccupancy[seatRecord.groupKey] or 0) + 1
		else
			table.insert(candidates, seatRecord)
		end
	end

	if occupiedSeats + 1 > maxOccupied then
		return nil
	end

	if #candidates == 0 then
		return nil
	end

	local occupiedWeight = math.max(0, tonumber(Config.SOCIAL_WEIGHT_OCCUPIED) or 0)
	local emptyWeight = math.max(0, tonumber(Config.SOCIAL_WEIGHT_EMPTY) or 0)
	local totalWeight = 0
	local candidateWeights: { number } = table.create(#candidates, 0)

	for i, candidate in ipairs(candidates) do
		local groupCount = groupOccupancy[candidate.groupKey] or 0
		local weight = if groupCount > 0 then occupiedWeight else emptyWeight
		if weight < 0 then
			weight = 0
		end
		candidateWeights[i] = weight
		totalWeight += weight
	end

	local selectedCandidate: SeatRecord
	if totalWeight > 0 then
		local roll = math.random() * totalWeight
		local running = 0

		selectedCandidate = candidates[1]
		for i, candidate in ipairs(candidates) do
			running += candidateWeights[i]
			if roll <= running then
				selectedCandidate = candidate
				break
			end
		end
	else
		selectedCandidate = candidates[math.random(1, #candidates)]
	end

	local reservation: SeatReservation = {
		startTime = arrivalTime,
		endTime = endTime,
		npcId = npcId,
	}
	table.insert(selectedCandidate.reservations, reservation)

	return selectedCandidate.seat
end

function SeatManager.releaseByNPC(npcId: string): ()
	if not initialized then
		SeatManager.init()
	end

	for _, socialRecord in pairs(socialByPOI) do
		for _, seatRecord in ipairs(socialRecord.seats) do
			for i = #seatRecord.reservations, 1, -1 do
				local reservation = seatRecord.reservations[i]
				if reservation.npcId == npcId then
					table.remove(seatRecord.reservations, i)
				end
			end
		end
	end

	pruneExpiredReservations(tick())
end

function SeatManager.claimReservations(seatParts: { Part }, npcId: string): ()
	if not initialized then
		SeatManager.init()
	end

	if npcId == "" then
		return
	end

	for _, socialRecord in pairs(socialByPOI) do
		for _, seatRecord in ipairs(socialRecord.seats) do
			for _, seatPart in ipairs(seatParts) do
				if seatRecord.seat == seatPart then
					for _, reservation in ipairs(seatRecord.reservations) do
						if reservation.npcId == nil then
							reservation.npcId = npcId
						end
					end
				end
			end
		end
	end
end

return SeatManager
