local Dehz = Dehz
local log = Dehz.log
local util = Dehz.util
local state = Dehz.state
local caps = Dehz.caps
local entities = Dehz.entities

local culling = {}

local applied = {}
local appliedCount = 0
local skippedCount = 0
local lastRunAt = 0
local active = false

local function overrideFor(model)
    local overrides = Config.Culling.modelOverrides or {}
    for key, radius in pairs(overrides) do
        local hash = util.modelHash(key)
        if hash == model then return radius end
    end
    return nil
end

local function radiusFor(rec)
    local override = overrideFor(rec.model)
    if override then return override end
    local radii = Config.Culling.radii or {}
    return radii[rec.category]
end

local function applyTo(rec)
    if applied[rec.key] then return false end

    local protection = Dehz.sweeper.protectionFor(rec)
    if protection then
        skippedCount = skippedCount + 1
        applied[rec.key] = 'skipped:' .. protection
        return false
    end

    local radius = radiusFor(rec)
    if not radius or radius <= 0.0 then return false end

    local ok = pcall(SetEntityDistanceCullingRadius, rec.handle, radius + 0.0)
    if ok then
        applied[rec.key] = radius
        appliedCount = appliedCount + 1
        return true
    end

    return false
end

local function pass(keys)
    if not active then return end
    if not state.isActive() then return end

    local index = entities.all()
    local perTick = tonumber(Config.Entities.entitiesPerTick) or 250
    local processed = 0

    local list = keys
    if not list then
        list = {}
        for key in pairs(index) do list[#list + 1] = key end
    end

    for i = 1, #list do
        local rec = index[list[i]]
        if rec and DoesEntityExist(rec.handle) then
            util.guard('culling', applyTo, rec)
        end

        processed = processed + 1
        if processed >= perTick then
            processed = 0
            Wait(0)
        end
    end

    for key in pairs(applied) do
        if not index[key] then applied[key] = nil end
    end

    lastRunAt = GetGameTimer()
end

function culling.status()
    return {
        enabled = Config.Culling.enabled == true,
        acknowledged = Config.Culling.acknowledgeDeprecated == true,
        active = active,
        nativeAvailable = caps.cullingNatives,
        appliedCount = appliedCount,
        skippedCount = skippedCount,
        lastRunAt = lastRunAt,
        deprecated = true,
        note = 'Cfx.re documents the culling natives as deprecated with known, unfixable issues. Prefer the onesync_distanceCulling and onesync_distanceCullVehicles convars, which the Config Auditor reports on.'
    }
end

function culling.start()
    if not Config.Culling.enabled then
        return
    end

    if not caps.cullingNatives then
        log.warn('culling', 'distance culling is enabled in config but SetEntityDistanceCullingRadius is not available on this server build. Module disabled.')
        return
    end

    if Config.Culling.acknowledgeDeprecated ~= true then
        log.warn('culling', 'distance culling is enabled but Config.Culling.acknowledgeDeprecated is false. This module stays disabled. Read the comment above it in config.lua: Cfx.re documents these natives as deprecated with known, unfixable issues.')
        return
    end

    if not caps.entityPool then
        log.warn('culling', 'distance culling cannot run: no server-side entity list (OneSync is "%s")', caps.oneSync)
        return
    end

    active = true

    log.warn('culling', 'distance culling ENABLED using deprecated natives. This is opt-in and unsupported by Cfx.re. Prefer onesync_distanceCulling / onesync_distanceCullVehicles.')

    entities.onScan(function(newKeys)
        if #newKeys > 0 then
            util.guard('culling', pass, newKeys)
        end
    end)

    util.loop('culling', function()
        return Config.Culling.interval or 60000
    end, function()
        pass(nil)
    end, 15000)
end

Dehz.culling = culling
