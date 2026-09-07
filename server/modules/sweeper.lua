local Dehz = Dehz
local log = Dehz.log
local util = Dehz.util
local state = Dehz.state
local caps = Dehz.caps
local entities = Dehz.entities
local bridge = Dehz.bridge

local sweeper = {}

local history
local pendingVerify = {}
local lastResults = {}
local totals = { reported = 0, orphaned = 0, deleted = 0, resurrected = 0 }
local blockedReason = nil

local POP_NAME = Dehz.POP_TYPE
local KEEP_ENTITY = Dehz.ORPHAN_MODE.KEEP_ENTITY

local function protectCfg()
    return Config.Sweeper.protect or {}
end

local function buildModelSet()
    local out = {}
    local list = protectCfg().models or {}
    for i = 1, #list do
        local hash = util.modelHash(list[i])
        if hash then out[hash] = true end
    end
    return out
end

local function buildResourceSet()
    return util.setFromList(protectCfg().resources or {})
end

local function buildBucketSet()
    return util.setFromList(protectCfg().routingBuckets or {})
end

local function playerPositions()
    local out = {}
    local players = GetPlayers()
    for i = 1, #players do
        local ped = GetPlayerPed(players[i])
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            local coords = GetEntityCoords(ped)
            out[#out + 1] = { x = coords.x, y = coords.y, z = coords.z }
        end
    end
    return out
end

local function nearestPlayerDistance(rec, positions)
    local best = math.huge
    for i = 1, #positions do
        local p = positions[i]
        local d = util.dist2(rec.x, rec.y, rec.z, p.x, p.y, p.z)
        if d < best then best = d end
    end
    if best == math.huge then return math.huge end
    return math.sqrt(best)
end

local function buildRadiusSet(category, radius)
    local set = {}
    local typeId = Dehz.ENTITY_TYPE[category]
    local players = GetPlayers()

    for i = 1, #players do
        local ped = GetPlayerPed(players[i])
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            local coords = GetEntityCoords(ped)
            local ok, list = pcall(GetEntitiesInRadius, coords.x, coords.y, coords.z, radius, typeId, false, {})
            if ok and type(list) == 'table' then
                for j = 1, #list do
                    set[list[j]] = true
                end
            end
        end
    end

    return set
end

local function vehicleOccupied(handle)
    local depth = tonumber(Config.Sweeper.seatScanDepth) or 8
    if GetPedInVehicleSeat(handle, -1) ~= 0 then return true end
    for seat = 0, depth - 2 do
        if GetPedInVehicleSeat(handle, seat) ~= 0 then return true end
    end
    return false
end

local function stateFlag(handle, key)
    local ok, value = pcall(function()
        return Entity(handle).state[key]
    end)
    if not ok then return nil end
    return value
end

local function protectionReason(rec, sets)
    local cfg = protectCfg()

    if cfg.skipUnsyncedOrigin ~= false and rec.x == 0.0 and rec.y == 0.0 and rec.z == 0.0 then
        return 'unsynced_origin'
    end

    if cfg.skipAttached ~= false and rec.attached and rec.attached ~= 0 then
        return 'attached'
    end

    if cfg.respectKeepEntityOrphanMode ~= false and rec.orphanMode == KEEP_ENTITY then
        return 'orphan_keep'
    end

    if rec.model and sets.models[rec.model] then
        return 'model_whitelist'
    end

    if rec.script and sets.resources[rec.script] then
        return 'resource_whitelist'
    end

    local bucket = rec.bucket or 0
    if bucket ~= 0 and cfg.protectNonZeroBuckets ~= false then
        return 'routing_bucket'
    end
    if sets.buckets[bucket] then
        return 'routing_bucket_whitelist'
    end

    local zone = util.pointInZones(cfg.zones, rec.x, rec.y, rec.z)
    if zone then
        return 'zone:' .. zone
    end

    if rec.category == 'vehicles' and rec.plate and bridge.isPlateProtected(rec.plate) then
        return 'owned_plate'
    end

    local key = cfg.stateKey or 'dehz_protected'
    if stateFlag(rec.handle, key) then
        return 'state_bag'
    end

    local foreign = cfg.foreignStateKeys or {}
    for i = 1, #foreign do
        if stateFlag(rec.handle, foreign[i]) then
            return 'foreign_state:' .. foreign[i]
        end
    end

    return nil
end

local function eligibility(rec, rules, now, positions, radiusSet)
    if not rules or rules.enabled == false then return false, 'category_disabled' end

    local age = now - rec.firstSeen
    if age < (rules.minAgeMs or 600000) then return false, 'too_young' end

    local popName = POP_NAME[rec.popType or 0] or 'unknown'
    local allowed = rules.sweepablePopulationTypes or {}
    local popOk = false
    for i = 1, #allowed do
        if allowed[i] == popName then popOk = true; break end
    end
    if not popOk then return false, 'population_type:' .. popName end

    if rules.requireNoOwner ~= false then
        local owner = rec.owner
        if owner and owner ~= -1 and owner ~= 0 then return false, 'has_owner' end
    end

    local minDistance = rules.minDistance or 300.0

    if radiusSet then
        if radiusSet[rec.handle] then return false, 'near_player' end
    else
        if #positions == 0 then return false, 'no_players' end
        local distance = nearestPlayerDistance(rec, positions)
        if distance < minDistance then return false, 'near_player' end
        rec.lastDistance = distance
    end

    if rec.category == 'vehicles' and vehicleOccupied(rec.handle) then
        return false, 'occupied'
    end

    return true, nil
end

local function describe(rec, now)
    return {
        key = rec.key,
        netId = rec.netId,
        category = rec.category,
        model = rec.model,
        coords = { x = util.round(rec.x, 2), y = util.round(rec.y, 2), z = util.round(rec.z, 2) },
        ageMs = now - rec.firstSeen,
        population = POP_NAME[rec.popType or 0] or 'unknown',
        bucket = rec.bucket or 0,
        script = rec.script,
        plate = rec.plate,
        distance = rec.lastDistance and util.round(rec.lastDistance, 1) or nil,
        failStreak = rec.failStreak
    }
end

local function verifyPending()
    if Config.Sweeper.verifyDeletions == false then
        pendingVerify = {}
        return 0
    end

    local resurrected = 0
    for i = 1, #pendingVerify do
        local item = pendingVerify[i]
        if item.action == 'delete' and DoesEntityExist(item.handle) then
            resurrected = resurrected + 1
        end
    end

    if resurrected > 0 then
        totals.resurrected = totals.resurrected + resurrected
        state.counters.resurrections = totals.resurrected
        log.warn('sweeper', '%d of %d entities deleted last sweep still exist. Server-side deletion does not always stick when a client re-creates the entity.',
            resurrected, #pendingVerify)
    end

    pendingVerify = {}
    return resurrected
end

local function preconditions(force)
    if not Config.Sweeper.enabled then return false, 'sweeper disabled in config' end
    if not caps.entityPool then return false, 'no server-side entity list (OneSync required)' end

    if not force then
        if state.uptime() < (Config.Sweeper.startupGrace or 180000) then
            return false, 'within startup grace period'
        end
        local players = #GetPlayers()
        if players < (Config.Sweeper.minPlayersOnline or 1) then
            return false, ('only %d players online (minimum %d)'):format(players, Config.Sweeper.minPlayersOnline or 1)
        end
    end

    return true
end

local function resolveAction(dryRunOverride)
    if dryRunOverride == true then return 'report', nil end

    local action = state.sweeperAction()

    if action == 'report' then
        if not state.isActive() then return 'report', 'Config.Mode is monitor' end
        if Config.Sweeper.dryRun ~= false then return 'report', 'Config.Sweeper.dryRun is true' end
        return 'report', 'Config.Sweeper.action is report'
    end

    if dryRunOverride == false or dryRunOverride == nil then
        if bridge.plateLookupBlocksLiveSweep() then
            return 'report', ('owned-vehicle plate lookup failed and Config.Sweeper.requirePlateLookup is true (%s)')
                :format(tostring(state.plateLookupError))
        end
        return action, nil
    end

    return 'report', nil
end

local function actOn(rec, action)
    if action == 'orphan' then
        if not caps.setOrphanMode then return false, 'SetEntityOrphanMode unavailable on this build' end
        local ok = pcall(SetEntityOrphanMode, rec.handle, Dehz.ORPHAN_MODE.DELETE_ON_OWNER_DISCONNECT)
        return ok
    end

    if action == 'delete' then
        local ok = pcall(DeleteEntity, rec.handle)
        return ok
    end

    return true
end

local function sweepCategory(category, action, actor)
    local started = GetGameTimer()
    local rules = Config.Sweeper.categories and Config.Sweeper.categories[category]

    local result = {
        category = category,
        action = action,
        dryRun = action == 'report',
        scanned = 0,
        eligible = 0,
        acted = 0,
        failed = 0,
        protected = 0,
        capped = false,
        byRule = {},
        byProtection = {},
        byResource = {},
        candidates = {},
        at = os.time(),
        actor = actor or 'scheduler'
    }

    if not rules or rules.enabled == false then
        result.skipped = 'category disabled'
        result.durationMs = 0
        return result
    end

    local now = GetGameTimer()
    local sets = {
        models = buildModelSet(),
        resources = buildResourceSet(),
        buckets = buildBucketSet()
    }

    local positions = playerPositions()
    local radiusSet = nil
    if Config.Sweeper.useRadiusQuery and caps.entitiesInRadius then
        radiusSet = buildRadiusSet(category, rules.minDistance or 300.0)
    end

    local cap = tonumber(Config.Sweeper.maxDeletionsPerSweep) or 50
    local grace = tonumber(Config.Sweeper.graceSweeps) or 3
    local perTick = tonumber(Config.Entities.entitiesPerTick) or 250
    local processed = 0

    local index = entities.all()
    local keys = {}
    for key, rec in pairs(index) do
        if rec.category == category then
            keys[#keys + 1] = key
        end
    end

    for k = 1, #keys do
        local rec = index[keys[k]]
        if rec and rec.category == category then
            result.scanned = result.scanned + 1

            if not DoesEntityExist(rec.handle) then
                rec.failStreak = 0
            else
                local eligible, reason = eligibility(rec, rules, now, positions, radiusSet)

                if not eligible then
                    rec.failStreak = 0
                    local bucketKey = reason or 'unknown'
                    result.byRule[bucketKey] = (result.byRule[bucketKey] or 0) + 1
                else
                    local protection = protectionReason(rec, sets)
                    if protection then
                        rec.failStreak = 0
                        result.protected = result.protected + 1
                        result.byProtection[protection] = (result.byProtection[protection] or 0) + 1
                    else
                        rec.failStreak = (rec.failStreak or 0) + 1
                        if rec.failStreak >= grace then
                            result.eligible = result.eligible + 1
                            if #result.candidates < cap then
                                result.candidates[#result.candidates + 1] = rec
                            else
                                result.capped = true
                            end
                        else
                            result.byRule['awaiting_grace'] = (result.byRule['awaiting_grace'] or 0) + 1
                        end
                    end
                end
            end

            processed = processed + 1
            if processed >= perTick then
                processed = 0
                Wait(0)
            end
        end
    end

    local described = {}

    for i = 1, #result.candidates do
        local rec = result.candidates[i]
        described[i] = describe(rec, now)

        if rec.script then
            result.byResource[rec.script] = (result.byResource[rec.script] or 0) + 1
        end

        if action == 'report' then
            result.acted = result.acted + 1
            log.info('sweeper', 'DRY RUN would %s %s model=%d at %.1f,%.1f,%.1f age=%.0fs pop=%s bucket=%d created-by=%s%s',
                state.isActive() and (Config.Sweeper.action or 'report') or 'report',
                rec.category, rec.model or 0, rec.x, rec.y, rec.z,
                (now - rec.firstSeen) / 1000,
                POP_NAME[rec.popType or 0] or 'unknown',
                rec.bucket or 0,
                rec.script or 'unknown',
                rec.plate and (' plate=' .. rec.plate) or '')
        else
            local ok, err = actOn(rec, action)
            if ok then
                result.acted = result.acted + 1
                if action == 'delete' then
                    pendingVerify[#pendingVerify + 1] = { key = rec.key, handle = rec.handle, action = action }
                end
                log.info('sweeper', '%s %s model=%d at %.1f,%.1f,%.1f age=%.0fs created-by=%s',
                    action == 'delete' and 'deleted' or 'marked for owner-disconnect cleanup',
                    rec.category, rec.model or 0, rec.x, rec.y, rec.z,
                    (now - rec.firstSeen) / 1000, rec.script or 'unknown')
            else
                result.failed = result.failed + 1
                if err then log.warn('sweeper', 'action failed: %s', tostring(err)) end
            end
        end
    end

    result.candidates = described
    result.durationMs = GetGameTimer() - started

    if result.capped then
        log.warn('sweeper', 'sweep of %s hit the maxDeletionsPerSweep cap of %d. %d entities were eligible. Hitting this cap almost always means a config value is wrong, not that your server is that dirty. Review the dry run output before continuing.',
            category, cap, result.eligible)
    end

    if action == 'report' then
        totals.reported = totals.reported + result.acted
    elseif action == 'orphan' then
        totals.orphaned = totals.orphaned + result.acted
    elseif action == 'delete' then
        totals.deleted = totals.deleted + result.acted
    end

    state.counters.reported = totals.reported
    state.counters.orphaned = totals.orphaned
    state.counters.deleted = totals.deleted

    return result
end

local function reportWebhook(results, action, blocked)
    local eligible = 0
    local acted = 0
    for i = 1, #results do
        eligible = eligible + (results[i].eligible or 0)
        acted = acted + (results[i].acted or 0)
    end
    if eligible == 0 then return end

    local fields = {}
    for i = 1, #results do
        local r = results[i]
        fields[#fields + 1] = {
            name = r.category,
            value = ('scanned `%d`  eligible `%d`  acted `%d`  protected `%d`%s')
                :format(r.scanned, r.eligible, r.acted, r.protected, r.capped and '  **capped**' or ''),
            inline = false
        }
    end

    if blocked then
        fields[#fields + 1] = { name = 'live action blocked', value = blocked, inline = false }
    end

    Dehz.webhook.send('sweeper', {
        title = ('Entity sweep - %s'):format(action == 'report' and 'DRY RUN' or action),
        description = ('%d entities eligible, %d acted on.'):format(eligible, acted),
        severity = action == 'report' and 'info' or 'warning',
        fields = fields
    })
end

function sweeper.run(category, dryRunOverride, actor, force)
    local ok, reason = preconditions(force)
    if not ok then
        blockedReason = reason
        log.debug('sweeper', 'sweep skipped: %s', reason)
        return { blocked = reason, results = {} }
    end

    blockedReason = nil
    state.sweepRunning = true
    state.lastSweepAt = GetGameTimer()
    state.counters.sweeps = state.counters.sweeps + 1

    local resurrected = verifyPending()

    local action, blocked = resolveAction(dryRunOverride)

    local categories = {}
    if category and category ~= 'all' then
        categories[1] = category
    else
        categories = Dehz.CATEGORY
    end

    local results = {}
    for i = 1, #categories do
        local r = sweepCategory(categories[i], action, actor)
        r.resurrectedLastSweep = (i == 1) and resurrected or nil
        r.blocked = blocked
        results[#results + 1] = r
        history:push(r)
        lastResults[r.category] = r
        Dehz.persist.recordSweep(r, actor)
    end

    state.sweepRunning = false

    if blocked and action == 'report' and state.isActive() then
        log.warn('sweeper', 'live action was requested but downgraded to a dry run: %s', blocked)
    end

    reportWebhook(results, action, blocked)

    return { results = results, action = action, blocked = blocked, resurrected = resurrected }
end

function sweeper.forceSweep(category, dryRun)
    return sweeper.run(category, dryRun, 'export', true)
end

function sweeper.protectEntity(entity)
    if not entity or not DoesEntityExist(entity) then return false end
    local key = protectCfg().stateKey or 'dehz_protected'
    local ok = pcall(function()
        Entity(entity).state:set(key, true, Config.Sweeper.replicateProtectionState ~= false)
    end)
    if ok and Config.Sweeper.setKeepEntityOnProtect ~= false and caps.setOrphanMode then
        pcall(SetEntityOrphanMode, entity, Dehz.ORPHAN_MODE.KEEP_ENTITY)
    end
    return ok
end

function sweeper.unprotectEntity(entity)
    if not entity or not DoesEntityExist(entity) then return false end
    local key = protectCfg().stateKey or 'dehz_protected'
    local ok = pcall(function()
        Entity(entity).state:set(key, nil, Config.Sweeper.replicateProtectionState ~= false)
    end)
    if ok and Config.Sweeper.setKeepEntityOnProtect ~= false and caps.setOrphanMode then
        pcall(SetEntityOrphanMode, entity, Dehz.ORPHAN_MODE.DELETE_WHEN_NOT_RELEVANT)
    end
    return ok
end

function sweeper.isEntityProtected(entity)
    if not entity or not DoesEntityExist(entity) then return false end
    local key = protectCfg().stateKey or 'dehz_protected'
    if stateFlag(entity, key) then return true, 'state_bag' end

    if caps.getOrphanMode then
        local ok, mode = pcall(GetEntityOrphanMode, entity)
        if ok and mode == KEEP_ENTITY and protectCfg().respectKeepEntityOrphanMode ~= false then
            return true, 'orphan_keep'
        end
    end

    local model = GetEntityModel(entity)
    if buildModelSet()[model] then return true, 'model_whitelist' end

    if caps.entityScript then
        local ok, script = pcall(GetEntityScript, entity)
        if ok and script and buildResourceSet()[script] then return true, 'resource_whitelist' end
    end

    local coords = GetEntityCoords(entity)
    local zone = util.pointInZones(protectCfg().zones, coords.x, coords.y, coords.z)
    if zone then return true, 'zone:' .. zone end

    if GetEntityType(entity) == 2 then
        local ok, plate = pcall(GetVehicleNumberPlateText, entity)
        if ok and bridge.isPlateProtected(plate) then return true, 'owned_plate' end
    end

    return false
end

local cachedSets, cachedSetsAt = nil, 0

local function protectionSets()
    local now = GetGameTimer()
    if cachedSets and (now - cachedSetsAt) < 30000 then return cachedSets end
    cachedSets = {
        models = buildModelSet(),
        resources = buildResourceSet(),
        buckets = buildBucketSet()
    }
    cachedSetsAt = now
    return cachedSets
end

function sweeper.protectionFor(rec)
    return protectionReason(rec, protectionSets())
end

function sweeper.history(count)
    return history:latest(count or 25)
end

function sweeper.lastResults()
    return lastResults
end

function sweeper.status()
    return {
        enabled = Config.Sweeper.enabled == true,
        mode = state.mode(),
        action = state.sweeperAction(),
        configuredAction = Config.Sweeper.action,
        dryRun = state.isDryRun(),
        blocked = blockedReason,
        plateLookup = bridge.plateStats(),
        liveBlockedByPlates = bridge.plateLookupBlocksLiveSweep(),
        totals = totals,
        lastSweepAt = state.lastSweepAt,
        interval = Config.Sweeper.interval,
        cap = Config.Sweeper.maxDeletionsPerSweep,
        graceSweeps = Config.Sweeper.graceSweeps,
        orphanModeAvailable = caps.setOrphanMode
    }
end

function sweeper.start()
    history = util.ring(60)

    if not Config.Sweeper.enabled then
        log.info('sweeper', 'entity sweeper disabled in config')
        return
    end

    if not caps.entityPool then
        log.warn('sweeper', 'entity sweeper cannot run: no server-side entity list (OneSync is "%s")', caps.oneSync)
        return
    end

    if Config.Sweeper.action == 'orphan' and not caps.setOrphanMode then
        log.warn('sweeper', 'Config.Sweeper.action is "orphan" but SetEntityOrphanMode is not available on this server build. Sweeps will report only.')
    end

    util.loop('sweeper', function()
        return Config.Sweeper.interval or 300000
    end, function()
        sweeper.run(nil, nil, 'scheduler', false)
    end, Config.Sweeper.startupGrace or 180000)

    log.info('sweeper', 'entity sweeper armed: mode=%s action=%s interval=%dms cap=%d grace=%d sweeps',
        state.mode(), state.sweeperAction(), Config.Sweeper.interval or 300000,
        Config.Sweeper.maxDeletionsPerSweep or 50, Config.Sweeper.graceSweeps or 3)
end

Dehz.sweeper = sweeper
