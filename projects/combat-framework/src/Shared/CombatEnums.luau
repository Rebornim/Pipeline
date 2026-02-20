--!strict

local CombatEnums = {}

CombatEnums.DamageType = {
	Blaster = "blaster",
	Turbolaser = "turbolaser",
	Ion = "ion",
	ProtonTorpedo = "proton_torpedo",
	ConcussionMissile = "concussion_missile",
	Explosion = "explosion",
	Impact = "impact",
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

CombatEnums.VehicleClass = {
	LightSpeeder = "light_speeder",
	HeavySpeeder = "heavy_speeder",
	BipedWalker = "biped_walker",
	QuadWalker = "quad_walker",
}

return CombatEnums
