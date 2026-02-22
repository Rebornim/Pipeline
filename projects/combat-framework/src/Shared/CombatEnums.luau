--!strict

local CombatEnums = {}

CombatEnums.DamageType = {
	Blaster = "blaster",
	Turbolaser = "turbolaser",
	Ion = "ion",
	ProtonTorpedo = "proton_torpedo",
	ConcussionMissile = "concussion_missile",
	ArtilleryShell = "artillery_shell",
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
	Light = "light",
	Heavy = "heavy",
	BipedWalker = "biped_walker",
	QuadWalker = "quad_walker",
}

return CombatEnums
