local Dehz = Dehz
local log = Dehz.log
local util = Dehz.util

local caps = {
    oneSync = 'unknown',
    entityPool = false,
    setOrphanMode = false,
    getOrphanMode = false,
    entityScript = false,
    entitiesInRadius = false,
    peerStatistics = false,
    convarListener = false,
    consoleListener = false,
    cullingNatives = false,
    filesystem = false,
    readdir = false,
    oxmysql = false,
    oxlib = false,
    perf = false,
    perfChecked = false,
    netPort = 30120,
    serverVersion = 'unknown'
}

local function hasNative(name)
    return type(_G[name]) == 'function'
end

local function probeEntityPool()
    if not hasNative('GetAllVehicles') then return false end
    local ok, result = pcall(GetAllVehicles)
    return ok and type(result) == 'table'
end

local function probeFilesystem()
    if type(io) ~= 'table' then return false, false end
    local hasReaddir = type(io.readdir) == 'function'
    if not hasReaddir then return type(io.open) == 'function', false end

    local ok, handle = pcall(io.readdir, GetResourcePath(GetCurrentResourceName()))
    if ok and handle then
        pcall(function() handle:close() end)
        return true, true
    end
    return type(io.open) == 'function', false
end

function caps.probe()
    local oneSyncVar = GetConvar('onesync', 'off')
    caps.oneSync = oneSyncVar

    caps.entityPool = probeEntityPool()
    caps.setOrphanMode = hasNative('SetEntityOrphanMode')
    caps.getOrphanMode = hasNative('GetEntityOrphanMode')
    caps.entityScript = hasNative('GetEntityScript')
    caps.entitiesInRadius = hasNative('GetEntitiesInRadius')
    caps.peerStatistics = hasNative('GetPlayerPeerStatistics')
    caps.convarListener = hasNative('AddConvarChangeListener')
    caps.consoleListener = hasNative('RegisterConsoleListener')
    caps.cullingNatives = hasNative('SetEntityDistanceCullingRadius')

    caps.filesystem, caps.readdir = probeFilesystem()

    caps.oxmysql = GetResourceState('oxmysql') == 'started'
    caps.oxlib = GetResourceState('ox_lib') == 'started'

    local port = tonumber(Config.Hitch and Config.Hitch.perf and Config.Hitch.perf.port) or 0
    if port and port > 0 then
        caps.netPort = port
    else
        caps.netPort = GetConvarInt('netPort', 30120)
    end

    caps.serverVersion = GetConvar('version', 'unknown')
end

function caps.perfUrl()
    local host = (Config.Hitch and Config.Hitch.perf and Config.Hitch.perf.host) or '127.0.0.1'
    return ('http://%s:%d/perf'):format(host, caps.netPort)
end

function caps.perfHeaders()
    local user = GetConvar('sv_prometheusBasicAuthUser', '')
    local password = GetConvar('sv_prometheusBasicAuthPassword', '')
    if user == '' and password == '' then return {} end

    local raw = user .. ':' .. password
    local encoded = Dehz.util.base64(raw)
    if not encoded then return {} end
    return { Authorization = 'Basic ' .. encoded }
end

function caps.probePerf(callback)
    if not Config.Hitch or not Config.Hitch.enabled or not Config.Hitch.sources.perf then
        caps.perfChecked = true
        if callback then callback(false) end
        return
    end

    PerformHttpRequest(caps.perfUrl(), function(status, body)
        caps.perfChecked = true
        caps.perf = (status == 200 and type(body) == 'string' and body:find('tickTime', 1, true) ~= nil)
        if not caps.perf then
            log.warn('caps', 'metrics endpoint %s unavailable (status %s) - hitch detection falls back to console and timer sources',
                caps.perfUrl(), tostring(status))
        end
        if callback then callback(caps.perf) end
    end, 'GET', '', caps.perfHeaders())
end

function caps.summary()
    return {
        oneSync = caps.oneSync,
        entityPool = caps.entityPool,
        orphanMode = caps.setOrphanMode,
        entityScript = caps.entityScript,
        entitiesInRadius = caps.entitiesInRadius,
        peerStatistics = caps.peerStatistics,
        convarListener = caps.convarListener,
        consoleListener = caps.consoleListener,
        cullingNatives = caps.cullingNatives,
        readdir = caps.readdir,
        oxmysql = caps.oxmysql,
        oxlib = caps.oxlib,
        perf = caps.perf,
        netPort = caps.netPort,
        serverVersion = caps.serverVersion
    }
end

function caps.report()
    local lines = {}
    lines[#lines + 1] = ('OneSync: %s  |  entity pool: %s  |  server: %s')
        :format(caps.oneSync, caps.entityPool and 'available' or 'UNAVAILABLE', caps.serverVersion)
    lines[#lines + 1] = ('orphan mode: %s  |  entity attribution: %s  |  radius query: %s')
        :format(caps.setOrphanMode and 'yes' or 'no', caps.entityScript and 'yes' or 'no', caps.entitiesInRadius and 'yes' or 'no')
    lines[#lines + 1] = ('filesystem scan: %s  |  peer statistics: %s  |  convar events: %s')
        :format(caps.readdir and 'full' or (caps.filesystem and 'read-only' or 'none'),
                caps.peerStatistics and 'yes' or 'no',
                caps.convarListener and 'yes' or 'no')
    lines[#lines + 1] = ('oxmysql: %s  |  ox_lib: %s')
        :format(caps.oxmysql and 'detected' or 'absent', caps.oxlib and 'detected' or 'absent')

    log.banner(lines)

    if not caps.entityPool then
        log.warn('caps', 'server entity list unavailable. OneSync is "%s". The Entity Sweeper, Distance Culling and entity counts cannot function without OneSync and are disabled.', caps.oneSync)
    end
    if not caps.readdir then
        log.warn('caps', 'io.readdir is not available on this server build. Resource analysis falls back to manifest declarations only, and stream weight cannot be measured.')
    end
end

Dehz.caps = caps
