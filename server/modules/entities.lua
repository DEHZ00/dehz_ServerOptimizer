local Dehz = Dehz
local log = Dehz.log
local util = Dehz.util
local caps = Dehz.caps

local entities = {}

local index = {}
local counts = { vehicles = 0, peds = 0, objects = 0 }
local modelCounts = { vehicles = {}, peds = {}, objects = {} }
local scriptCounts = {}
local listeners = {}

local scanId = 0
local lastScanAt = 0
local lastScanDurationMs = 0
local lastScanTotal = 0
local newKeys = {}

local poolFor = {
    vehicles = function() return GetAllVehicles() end,
    peds = function() return GetAllPeds() end,
    objects = function() return GetAllObjects() end
}

local function categoryEnabled(category)
    local cfg = Config.Entities.categories
    return cfg and cfg[category] ~= false
end

local pendingCounts, pendingModels, pendingScripts

local function record(handle, category, now)
    local netId = NetworkGetNetworkIdFromEntity(handle)
    local key = (netId and netId ~= 0) and ('n' .. netId) or ('h' .. handle)

    local rec = index[key]
    if not rec then
        rec = {
            key = key,
            netId = netId,
            category = category,
            firstSeen = now,
            failStreak = 0
        }
        index[key] = rec
        newKeys[#newKeys + 1] = key
    end

    rec.handle = handle
    rec.lastSeen = now
    rec.scanId = scanId
    rec.model = GetEntityModel(handle)

    local coords = GetEntityCoords(handle)
    rec.x, rec.y, rec.z = coords.x, coords.y, coords.z

    rec.popType = GetEntityPopulationType(handle)
    rec.bucket = GetEntityRoutingBucket(handle)
    rec.owner = NetworkGetEntityOwner(handle)
    rec.attached = GetEntityAttachedTo(handle)

    if caps.entityScript then
        local ok, script = pcall(GetEntityScript, handle)
        rec.script = (ok and script ~= '' and script) or nil
    end

    if caps.getOrphanMode then
        local ok, mode = pcall(GetEntityOrphanMode, handle)
        rec.orphanMode = ok and mode or nil
    end

    if category == 'vehicles' then
        local ok, plate = pcall(GetVehicleNumberPlateText, handle)
        rec.plate = ok and util.normalisePlate(plate) or nil
    end

    pendingCounts[category] = pendingCounts[category] + 1
    local models = pendingModels[category]
    models[rec.model] = (models[rec.model] or 0) + 1

    if rec.script then
        pendingScripts[rec.script] = (pendingScripts[rec.script] or 0) + 1
    end

    return rec
end

local function scan()
    if not caps.entityPool then return end

    local started = GetGameTimer()
    scanId = scanId + 1
    newKeys = {}

    pendingCounts = { vehicles = 0, peds = 0, objects = 0 }
    pendingModels = { vehicles = {}, peds = {}, objects = {} }
    pendingScripts = {}

    local perTick = tonumber(Config.Entities.entitiesPerTick) or 250
    if perTick < 25 then perTick = 25 end

    local processed = 0
    local total = 0

    for i = 1, #Dehz.CATEGORY do
        local category = Dehz.CATEGORY[i]
        if categoryEnabled(category) then
            local ok, pool = pcall(poolFor[category])
            if ok and type(pool) == 'table' then
                for j = 1, #pool do
                    local handle = pool[j]
                    if DoesEntityExist(handle) then
                        record(handle, category, started)
                        total = total + 1
                    end

                    processed = processed + 1
                    if processed >= perTick then
                        processed = 0
                        Wait(0)
                    end
                end
            else
                log.warn('entities', 'entity pool query failed for category "%s"', category)
            end
        end
    end

    for key, rec in pairs(index) do
        if rec.scanId ~= scanId then
            index[key] = nil
        end
    end

    counts = pendingCounts
    modelCounts = pendingModels
    scriptCounts = pendingScripts

    lastScanAt = started
    lastScanDurationMs = GetGameTimer() - started
    lastScanTotal = total

    for i = 1, #listeners do
        util.guard('entities', listeners[i], newKeys)
    end
end

function entities.onScan(fn)
    listeners[#listeners + 1] = fn
end

function entities.all()
    return index
end

function entities.get(key)
    return index[key]
end

function entities.counts()
    return {
        vehicles = counts.vehicles,
        peds = counts.peds,
        objects = counts.objects,
        total = counts.vehicles + counts.peds + counts.objects
    }
end

function entities.ratio()
    local players = #GetPlayers()
    local total = counts.vehicles + counts.peds + counts.objects
    if players == 0 then return total end
    return util.round(total / players, 1)
end

function entities.topModels(category, n)
    local source = modelCounts[category]
    if not source then return {} end
    return util.topN(source, n or 20, function(item)
        return { model = item.key, count = item.value }
    end)
end

function entities.topScripts(n)
    return util.topN(scriptCounts, n or 15, function(item)
        return { resource = item.key, count = item.value }
    end)
end

function entities.scriptCounts()
    local out = {}
    for name, count in pairs(scriptCounts) do out[name] = count end
    return out
end

function entities.scanInfo()
    return {
        scanId = scanId,
        lastScanAt = lastScanAt,
        durationMs = lastScanDurationMs,
        indexed = lastScanTotal,
        available = caps.entityPool
    }
end

function entities.snapshot()
    local c = entities.counts()
    return {
        vehicles = c.vehicles,
        peds = c.peds,
        objects = c.objects,
        total = c.total,
        players = #GetPlayers(),
        ratio = entities.ratio()
    }
end

function entities.forceScan()
    util.guard('entities', scan)
    return entities.scanInfo()
end

function entities.start()
    if not Config.Entities.enabled then
        log.info('entities', 'entity index disabled in config')
        return
    end

    if not caps.entityPool then
        log.warn('entities', 'entity index cannot start: no server-side entity list (OneSync is "%s")', caps.oneSync)
        return
    end

    util.loop('entities', function()
        return Config.Entities.scanInterval or 15000
    end, scan, 5000)

    log.info('entities', 'entity index running every %dms', Config.Entities.scanInterval or 15000)
end

Dehz.entities = entities
