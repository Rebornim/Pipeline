--!strict

local CombatEnums = {}

CombatEnums.DamageType = {
	Blaster = "blaster",
}

CombatEnums.Faction = {
	Empire = "empire",
	Rebel = "rebel",
	Neutral = "neutral",
}

CombatEnums.EntityState = {
	Active = "active",
	Destroyed = "destroyed",
	Respawning = "respawning",
}

return CombatEnums
