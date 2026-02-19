--!strict

local CombatEnums = {}

CombatEnums.DamageType = {
	Blaster = "blaster",
	Turbolaser = "turbolaser",
	Ion = "ion",
	ProtonTorpedo = "proton_torpedo",
	ConcussionMissile = "concussion_missile",
	Explosion = "explosion",
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

CombatEnums.ImpactType = {
	Shield = "shield",
	Hull = "hull",
	Environment = "environment",
}

return CombatEnums
