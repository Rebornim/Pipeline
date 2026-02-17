# Golden Tests: Wandering Props

Accumulating test scenarios from all passes. Each pass adds tests and lists regressions to re-run.

---

## Pass 1: Bare Bones Core Loop

### Test 1: Basic Spawn-Walk-Despawn Cycle
- **Setup:** Waypoint graph with 2 spawn nodes, 4 waypoint nodes, 2 despawn nodes, connected in a simple chain. 3 NPC models in WanderingPropModels. Config: MaxPopulation = 5, SpawnInterval = 1, DiagnosticsEnabled = true.
- **Action:** Start the server. Wait 10 seconds.
- **Expected:** 5 NPCs appear over the first few seconds, walk along the waypoint chain, and despawn at despawn nodes. As NPCs despawn, new ones spawn to maintain population of 5.
- **Pass condition:** Visual: NPCs walk smoothly along the waypoint path without floating or clipping through ground. Diagnostics: SPAWN and DESPAWN are healthy; no SPAWN_FAIL errors.

### Test 2: Late-Join Sync
- **Setup:** Same waypoint graph as Test 1. Config: MaxPopulation = 10.
- **Action:** Start server. Wait 15 seconds for NPCs to be mid-route. Join with a second client.
- **Expected:** Second client immediately sees all active NPCs at their current mid-route positions. NPCs continue walking from synced positions.
- **Pass condition:** Visual parity between clients is approximately correct. Diagnostics: BULK_SYNC fires with expected count.

### Test 3: Walk Speed Variation and Ground Snap
- **Setup:** Waypoint graph with a sloped ramp between two nodes. Config: BaseWalkSpeed = 8, WalkSpeedVariation = 3, MaxPopulation = 10.
- **Action:** Start server. Observe NPCs walking over the ramp section.
- **Expected:** NPCs walk at visibly different speeds and stay grounded on slope transitions.
- **Pass condition:** No obvious floating/clipping. Movement and animation speed feel coherent.

### Regression Tests
None (first pass).

---

## Pass 2: Points of Interest

### Test 4: Scenic POI Visit
- **Setup:** Waypoint graph with spawn, 3 waypoints, despawn. One Scenic POI linked to middle waypoint, with a ViewZone part offset to one side. Config: MaxPopulation = 3, ScenicDwellMin = 5, ScenicDwellMax = 5, DiagnosticsEnabled = true.
- **Action:** Start server. Wait for NPC to reach Scenic POI waypoint.
- **Expected:** NPC stops, faces ViewZone, idles for dwell duration, then resumes route.
- **Pass condition:** Scenic dwell and facing behavior are correct; POI_ROUTE diagnostics are present.

### Test 5: Social POI Sit and Walk In/Out
- **Setup:** One Social POI linked to a route waypoint, with 2 groups of 2 seats (4 total). Config: MaxPopulation = 5, SocialDwellMin = 8, SocialDwellMax = 8, SocialCapacityPercent = 0.75, SitAnimationId set.
- **Action:** Start server. Observe multiple NPCs at social stop.
- **Expected:** NPCs walk to seats, sit for dwell, then walk back out to route. Capacity cap is respected.
- **Pass condition:** No seat teleport for normal flow; seat claim/release behavior is consistent.

### Test 6: Busy POI Walk-Through
- **Setup:** Route includes one Busy POI.
- **Action:** Start server. Observe NPCs passing Busy POI.
- **Expected:** NPCs do not dwell at Busy POI.
- **Pass condition:** Continuous walk-through behavior.

### Test 7: Stuck NPC Fallback
- **Setup:** One POI is unreachable from spawn path; others are reachable.
- **Action:** Start server and observe route creation.
- **Expected:** Unreachable POI is dropped; NPC still gets valid fallback route.
- **Pass condition:** POI_SKIP/no_path diagnostics appear; NPCs still complete routes.

### Test 8: Late-Join with POI State
- **Setup:** Scenic/Social POIs active with dwell times > 0.
- **Action:** Join second client while NPCs are mid-route and mid-dwell.
- **Expected:** Late join reproduces current state (walking, scenic dwell, or social sit) correctly.
- **Pass condition:** No major state desync on join.

### Regression Tests
Re-run from Pass 1:
- **Test 1: Basic Spawn-Walk-Despawn Cycle**
- **Test 2: Late-Join Sync**
- **Test 3: Walk Speed Variation and Ground Snap**

---

## Pass 3: Zones + Clock Hook + Night Drain

### Test 9: Zone Waypoint Variation
- **Setup:** Route with spawn, 2 zone waypoints (`Zone=true`, e.g. Size 30x1x30), 1 spot waypoint, despawn. Diagnostics on.
- **Action:** Start server and observe multiple NPCs.
- **Expected:** Zone waypoints produce spread-out positions; spot waypoint remains converged.
- **Pass condition:** Clear spatial variation at zone nodes and stable spot behavior.

### Test 10: Scenic POI Stand-Point Variation
- **Setup:** Scenic POI with internal `Waypoint` part sized as a small area (not a single point), valid link to graph, ViewZone present.
- **Action:** Observe several NPC visits to the same Scenic POI.
- **Expected:** Scenic NPCs stand at different points on that Scenic waypoint area while still performing scenic dwell/facing.
- **Pass condition:** No center-only clustering when internal Scenic waypoint area is used.

### Test 11: Clock-Based Day/Night Hook
- **Setup:** Config: `DayNightEnabled=true`, `NightStartHour=19`, `DayStartHour=6`, `NightPopulationMultiplier=0.3`, `SpawnInterval=1`, diagnostics on.
- **Action:** Set `Lighting.ClockTime` to day (e.g. 12) and let population fill. Then set to night (e.g. 22). Later set back to day (e.g. 8).
- **Expected:** System reads clock time directly. Night lowers effective cap; day restores it.
- **Pass condition:** `DAYNIGHT_CHANGE` diagnostics appear on transitions and active population follows cap behavior.

### Test 12: Night Drain Route Shortening (Despawn-Point Safe)
- **Setup:** Enable `NightDrainEnabled=true`, set low `NightPopulationMultiplier` (e.g. 0.3), with POIs present.
- **Action:** Fill daytime population, then move clock into night window.
- **Expected:** Excess active NPCs get rerouted to short completion paths and despawn via despawn waypoints (not in-place deletion).
- **Pass condition:** Faster nighttime reduction while preserving route-end despawn behavior.

### Test 13: Social Seat Exit During Night Drain
- **Setup:** Night drain enabled and social POIs active.
- **Action:** Trigger night while some NPCs are seated.
- **Expected:** Seated NPCs are not rerouted mid-seat; they stand and walk out naturally before continuing shortened route.
- **Pass condition:** No snap from seat to social waypoint during seat-exit flow.

### Test 14: Marker Visibility Toggle
- **Setup:** Run once with `HideMarkersAtRuntime=true`, once with `false`.
- **Action:** Observe waypoint markers, POI waypoint parts, scenic ViewZone helper, and social seat helper parts.
- **Expected:** True = hidden markers. False = visible markers.
- **Pass condition:** Visibility toggles without breaking behavior.

### Regression Tests
Re-run:
- **Test 1: Basic Spawn-Walk-Despawn Cycle**
- **Test 2: Late-Join Sync**
- **Test 4: Scenic POI Visit**
- **Test 5: Social POI Sit and Walk In/Out**

---

## Pass 4: Optimization (LOD + Pooling)

### Test 15: LOD Tier Visual Transitions
- **Setup:** Waypoint graph spanning a large area (>300 studs across). Config: MaxPopulation = 20, LODEnabled = true, LODNearDistance = 50, LODLowDistance = 100, LODMidDistance = 200, DiagnosticsEnabled = true.
- **Action:** Start server. Walk player from one end of the map to the other, moving through clusters of NPCs.
- **Expected:** NPCs near the player walk with full animation. NPCs far away are invisible. As the player moves closer, distant NPCs reappear at their correct route positions with correct animation state. No visual pop-in glitches (NPCs don't appear in wrong positions).
- **Pass condition:** LOD_TRANSITION diagnostics fire as player moves. NPCs restored from far tier are at plausible route positions. No frozen or T-posed NPCs.

### Test 16: Model Pool Reuse
- **Setup:** Config: MaxPopulation = 10, SpawnInterval = 1, PoolEnabled = true, PoolMaxPerModel = 5, DiagnosticsEnabled = true. Use 2 NPC models.
- **Action:** Start server. Wait 60 seconds for several spawn/despawn cycles.
- **Expected:** After the first cycle of despawns, subsequent spawns reuse pooled models. POOL_ACQUIRE diagnostics appear. Model count in memory stays bounded.
- **Pass condition:** POOL_ACQUIRE fires regularly after initial population. No POOL_FULL_DESTROY unless population turnover is very high. NPCs spawned from pool behave identically to cloned NPCs (walk, animate, despawn normally).

### Test 17: LOD + POI State Consistency
- **Setup:** Route includes Scenic and Social POIs. Config: MaxPopulation = 10, LODEnabled = true, LODMidDistance = 30 (short, to trigger far tier easily).
- **Action:** Start server. Walk player far away so NPCs enter far tier while some are dwelling or sitting. Walk back.
- **Expected:** NPCs restored from far tier are in correct state: if dwell/sit time not expired, they appear dwelling/sitting; if expired, they appear walking past the POI.
- **Pass condition:** No NPC is frozen at a POI they should have left. No NPC skips a POI they should be at. Seat animations play correctly after restoration.

### Test 18: LOD Disabled Regression
- **Setup:** Config: LODEnabled = false, PoolEnabled = false, MaxPopulation = 20.
- **Action:** Run all Pass 1-3 golden tests.
- **Expected:** All behavior is identical to pre-Pass-4.
- **Pass condition:** No regressions when optimization features are disabled.

### Regression Tests
Re-run from previous passes:
- **Test 1: Basic Spawn-Walk-Despawn Cycle**
- **Test 2: Late-Join Sync**
- **Test 4: Scenic POI Visit**
- **Test 5: Social POI Sit and Walk In/Out**
- **Test 9: Zone Waypoint Variation**
- **Test 11: Clock-Based Day/Night Hook**
- **Test 12: Night Drain Route Shortening**
- **Test 13: Social Seat Exit During Night Drain**

---

## Pass 5: Visual Polish

### Test 19: Corner Beveling Smooth Pathing
- **Setup:** Waypoint graph with at least two 90° turns (e.g., L-shaped or zigzag route). Config: BevelEnabled = true, BevelRadius = 3, BevelSegments = 4, MaxPopulation = 5, DiagnosticsEnabled = true.
- **Action:** Start server. Observe NPCs navigating the sharp-turn waypoints.
- **Expected:** NPCs follow visible curved paths at corners instead of sharp angle turns. The curves are smooth and natural-looking. NPCs do not clip through walls or geometry at beveled corners.
- **Pass condition:** BEVEL_PATH diagnostics fire on spawn. No sharp angle turns at intermediate waypoints. POI stop positions are unchanged (NPCs still arrive at exact POI waypoint for dwell/seat).

### Test 20: Smooth Elevation and Rotation
- **Setup:** Waypoint graph with stairs/steps (elevation change > 1 stud between adjacent nodes) and at least one turn > 45°. Config: GroundSnapSmoothing = true, GroundSnapLerpSpeed = 15, TurnSmoothing = true, TurnLerpSpeed = 8.
- **Action:** Start server. Observe NPCs walking over steps and turning at waypoints.
- **Expected:** NPCs smoothly rise/fall over elevation changes instead of snapping vertically. Body rotation is gradual during turns — no instant facing snaps.
- **Pass condition:** No visible vertical snapping on step transitions. No instant rotation snaps at corners. Scenic POI facing turns smoothly rather than snapping to view target.

### Test 21: Head Look Player Recognition
- **Setup:** Config: HeadLookEnabled = true, HeadLookChance = 1.0 (force trigger), HeadLookDistance = 30, HeadLookDuration = 3, MaxPopulation = 5, DiagnosticsEnabled = true.
- **Action:** Start server. Walk player close to NPCs (within 30 studs). Observe head behavior.
- **Expected:** NPC heads smoothly turn to track the player position. After HeadLookDuration seconds, heads smoothly turn back to neutral. Head does not exceed natural rotation limits (no 180° head spin).
- **Pass condition:** HEAD_LOOK_START diagnostics fire. Head rotation is smooth (no snapping). Works during walking, dwelling, and sitting states. NPCs with no Neck Motor6D are silently skipped (no errors).

### Test 22: Path Lateral Offset
- **Setup:** Waypoint graph with straight paths between spawn and despawn (at least 3 intermediate waypoints). Config: PathLateralOffsetMax = 3, MaxPopulation = 10, DiagnosticsEnabled = true.
- **Action:** Start server. Observe multiple NPCs walking the same path segment simultaneously.
- **Expected:** NPCs walk slightly different lateral paths between the same waypoints. No ant-trail clustering along a single line.
- **Pass condition:** Visible lateral spread between NPCs on the same route. Zone waypoints and POI waypoints remain unaffected.

### Test 23: Spawn/Despawn Fade
- **Setup:** Config: FadeEnabled = true, SpawnFadeDuration = 1.0, DespawnFadeDuration = 0.8, SpawnInterval = 2, MaxPopulation = 5, DiagnosticsEnabled = true.
- **Action:** Start server. Observe NPC spawns and watch NPCs reach their route endpoint.
- **Expected:** NPCs fade in gradually over 1 second on spawn (transparent → solid). NPCs fade out gradually over 0.8 seconds when reaching route end (solid → transparent). No pop-in or pop-out.
- **Pass condition:** FADE_IN_START and FADE_OUT_START diagnostics fire. Fade is smooth and continuous. Pool models after despawn have correct (non-transparent) state when reused for next spawn.

### Test 24: All Pass 5 Features Disabled Regression
- **Setup:** Config: BevelEnabled = false, GroundSnapSmoothing = false, TurnSmoothing = false, HeadLookEnabled = false, PathLateralOffsetMax = 0, FadeEnabled = false, LODEnabled = true, PoolEnabled = true.
- **Action:** Run all Pass 1-4 golden tests.
- **Expected:** Behavior identical to pre-Pass-5.
- **Pass condition:** No regressions when all Pass 5 features are disabled.

### Regression Tests
Re-run from previous passes:
- **Test 1: Basic Spawn-Walk-Despawn Cycle**
- **Test 2: Late-Join Sync**
- **Test 4: Scenic POI Visit**
- **Test 5: Social POI Sit and Walk In/Out**
- **Test 9: Zone Waypoint Variation**
- **Test 11: Clock-Based Day/Night Hook**
- **Test 15: LOD Tier Visual Transitions**
- **Test 16: Model Pool Reuse**
- **Test 17: LOD + POI State Consistency**

---

## Pass 6: Internal POI Navigation

### Test 25: Social POI with Internal Waypoints
- **Setup:** Social POI with InternalWaypoints folder containing 3 connected BasePart nodes (IW_Entrance, IW_Hall, IW_Corner). IW_Entrance has ObjectValue linking to the POI's Waypoint part. Nodes linked sequentially: Entrance->Hall->Corner. Seat group has AccessPoint ObjectValue pointing to IW_Corner. Config: MaxPopulation = 5, InternalNavigationEnabled = true, DiagnosticsEnabled = true.
- **Action:** Start server. Wait for NPCs to reach the social POI.
- **Expected:** NPC walks to the POI waypoint, then walks through IW_Entrance -> IW_Hall -> IW_Corner (internal approach), sits at the seat, then walks back IW_Corner -> IW_Hall -> IW_Entrance (internal exit), and resumes the main route.
- **Pass condition:** INTERNAL_NAV_EXPAND diagnostics fire. NPC visibly walks through interior waypoints before and after sitting. No teleportation between waypoints.

### Test 26: Scenic POI with Stand Points
- **Setup:** Scenic POI with StandPoints folder containing 2 BasePart children (SP1: Size 4x1x4, SP2: Size 4x1x4) at different positions within the POI area. ViewZone present. Config: MaxPopulation = 5, InternalNavigationEnabled = true, DiagnosticsEnabled = true.
- **Action:** Start server. Observe multiple NPC visits to the same scenic POI.
- **Expected:** NPCs walk to one of the stand point positions (not the original POI waypoint center). Different NPCs may choose different stand points. NPCs dwell facing ViewZone from the chosen stand point.
- **Pass condition:** Visible position variation across stand points. No NPCs standing at the exact POI waypoint center when stand points exist.

### Test 27: Backward Compatibility — POIs Without Internal Features
- **Setup:** Social POI without InternalWaypoints folder. Scenic POI without StandPoints folder. Config: InternalNavigationEnabled = true.
- **Action:** Start server. Observe NPCs visiting both POIs.
- **Expected:** Social NPC walks directly to seat and back without internal waypoints. Scenic NPC stands at POI waypoint (or randomized within waypoint size) as in Pass 5.
- **Pass condition:** Behavior identical to Pass 5 for POIs without the new folders.

### Test 28: Feature Toggle Disabled
- **Setup:** Social POI with InternalWaypoints folder and connected nodes. Scenic POI with StandPoints folder. Config: InternalNavigationEnabled = false, DiagnosticsEnabled = true.
- **Action:** Start server. Observe NPC behavior.
- **Expected:** Internal waypoint folders and stand point folders are completely ignored. Social NPCs walk directly to seats. Scenic NPCs use POI waypoint position (not stand points).
- **Pass condition:** No INTERNAL_NAV_EXPAND diagnostics. Behavior identical to Pass 5.

### Test 29: Late-Join with Internal Waypoints
- **Setup:** Social POI with internal waypoints. Config: MaxPopulation = 10, InternalNavigationEnabled = true.
- **Action:** Start server. Wait 15 seconds for NPCs to be mid-route (some walking through internal waypoints). Join with a second client.
- **Expected:** Late-joining client receives bulk sync with expanded waypoints array. NPCs interpolate correctly through the longer route including internal waypoint positions.
- **Pass condition:** No desync between clients. NPCs on the second client walk through internal waypoints at correct positions.

### Regression Tests
Re-run from previous passes:
- **Test 1: Basic Spawn-Walk-Despawn Cycle**
- **Test 2: Late-Join Sync**
- **Test 4: Scenic POI Visit**
- **Test 5: Social POI Sit and Walk In/Out**
- **Test 9: Zone Waypoint Variation**
- **Test 11: Clock-Based Day/Night Hook**
- **Test 15: LOD Tier Visual Transitions**
- **Test 16: Model Pool Reuse**
- **Test 17: LOD + POI State Consistency**

---

## Pass 7: Market POI Type

### Test 30: Market POI Basic Flow
- **Setup:** Market POI with `Stands/` folder (3 stands), `InternalWaypoints/` folder (3 nodes, entry linked to graph). Config: MarketStandsMin = 2, MarketStandsMax = 3, MaxPopulation = 5, InternalNavigationEnabled = true, DiagnosticsEnabled = true.
- **Action:** Start server. Wait for NPC to reach market POI.
- **Expected:** NPC enters market via internal waypoints, visits 2-3 stands (dwells at each), then exits via internal waypoints and continues route.
- **Pass condition:** `[P7_TEST] MARKET_EXPAND` shows `stands_visited=2` or `3`. NPC visually walks to stands and pauses at each. `[P7_TEST] MARKET_STOP` entries logged for each stand visit.

### Test 31: Market Stand Capacity
- **Setup:** Market with 2 stands, MarketStandCapacity = 1. Config: MaxPopulation = 5, MarketStandsMin = 2.
- **Action:** Start server. Spawn 2 NPCs that both select the same market.
- **Expected:** Each NPC claims a different stand. If both stands are occupied, subsequent NPCs skip the market.
- **Pass condition:** `[P7_TEST] MARKET_STAND_CLAIM` shows 2 separate claims on different stands. No stand exceeds capacity.

### Test 32: Market Skip When No Stands Available
- **Setup:** Market with 1 stand, MarketStandCapacity = 1. 1 NPC already claimed the stand. Config: MaxPopulation = 5.
- **Action:** 2nd NPC tries to select this market.
- **Expected:** Market skipped entirely (like social capacity skip).
- **Pass condition:** `[P7_TEST] MARKET_POI_SKIP reason=no_available_stands` logged. NPC routes through other POIs normally.

### Test 33: Market Head Scanning
- **Setup:** Market with 1 stand + ViewTarget part. Config: HeadLookEnabled = true, MarketHeadScanSpeed = 0.4, MaxPopulation = 3.
- **Action:** NPC arrives at market stand and begins dwell. Player walks near NPC during dwell.
- **Expected:** Head sweeps horizontally toward ViewTarget during dwell. When player is nearby, player head-look overrides scan. When player leaves, scan resumes.
- **Pass condition:** `[P7_TEST] SCAN_START` logged. Visual head sweep visible. Player proximity triggers normal head-look behavior.

### Test 34: Market Backward Compatibility — InternalNavigationEnabled=false
- **Setup:** Market POI exists in world. Config: InternalNavigationEnabled = false, MaxPopulation = 5, DiagnosticsEnabled = true.
- **Action:** Start server. Spawn NPCs.
- **Expected:** Market POI skipped during discovery (not in registry). NPCs route through other POIs normally.
- **Pass condition:** No `[P7_TEST] MARKET_DISCOVER` logged. System behaves identically to Pass 6.

### Test 35: Market with Night Drain
- **Setup:** Market NPC mid-route browsing stands. Config: DayNightEnabled = true, NightDrainEnabled = true, NightPopulationMultiplier = 0.3.
- **Action:** Trigger night drain by setting Lighting.ClockTime to night.
- **Expected:** Market stand claims released. NPC rerouted to despawn.
- **Pass condition:** `[P7_TEST] MARKET_CLAIM_RELEASE reason=drain` logged. NPC despawns via despawn waypoint.

### Regression Tests
Re-run from previous passes:
- **Test 1: Basic Spawn-Walk-Despawn Cycle**
- **Test 2: Late-Join Sync**
- **Test 4: Scenic POI Visit**
- **Test 5: Social POI Sit and Walk In/Out**
- **Test 9: Zone Waypoint Variation**
- **Test 11: Clock-Based Day/Night Hook**
- **Test 15: LOD Tier Visual Transitions**
- **Test 16: Model Pool Reuse**
- **Test 17: LOD + POI State Consistency**
- **Test 25: Social POI with Internal Waypoints**
- **Test 27: Backward Compatibility — POIs Without Internal Features**
