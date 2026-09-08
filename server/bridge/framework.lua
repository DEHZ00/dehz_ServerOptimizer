local Dehz = Dehz
local log = Dehz.log
local util = Dehz.util
local state = Dehz.state
local caps = Dehz.caps

local bridge = {}

local impl
local plateSet = {}
local plateCount = 0
local manualPlates = {}
local plateFetchedAt = 0
local lastRefreshCount = -1

local IDENTIFIER_PATTERN = '^[A-Za-z0-9_]+$'

local function safeIdentifier(value)
    if type(value) ~= 'string' then return nil end
    if not value:match(IDENTIFIER_PATTERN) then return nil end
    return value
end

local function dbQuery(sql, params, timeoutMs)
    if not caps.oxmysql then return nil, 'oxmysql is not running' end

    local p = promise.new()
    local settled = false

    SetTimeout(timeoutMs or 15000, function()
        if not settled then
            settled = true
            p:resolve({ __dehzTimeout = true })
        end
    end)

    local dispatched, err = pcall(function()
        exports.oxmysql:query(sql, params or {}, function(result)
            if not settled then
                settled = true
                p:resolve(result)
            end
        end)
    end)

    if not dispatched and not settled then
        settled = true
        p:resolve({ __dehzError = tostring(err) })
    end

    local result = Citizen.Await(p)

    if type(result) ~= 'table' then return nil, 'query returned no result set' end
    if result.__dehzTimeout then return nil, 'query timed out' end
    if result.__dehzError then return nil, result.__dehzError end

    return result
end

local function aceAllows(source)
    local src = tostring(source)
    if IsPlayerAceAllowed(src, Config.Permissions.ace) then return true end
    if Config.Permissions.allowCommandAce and IsPlayerAceAllowed(src, 'command') then return true end
    return false
end

local function chatFallback(source, message)
    TriggerClientEvent('chat:addMessage', source, {
        color = { 200, 16, 46 },
        multiline = true,
        args = { 'Optimizer', message }
    })
end

local function baseLabel(source)
    local name = GetPlayerName(source) or 'unknown'
    local license = GetPlayerIdentifierByType(source, 'license') or 'no-license'
    return ('%s [%s]'):format(name, license)
end

local warnedAbsent = {}

local function columnExists(tableName, columnName)
    local rows, err = dbQuery(
        'SELECT COUNT(*) AS n FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?',
        { tableName, columnName }, 10000)

    if not rows then return nil, err end

    local row = rows[1]
    if not row then return false end

    local count = tonumber(row.n) or 0
    return count > 0
end

local function fetchPlatesFrom(entries)
    local collected = {}
    local allOk = true
    local lastError
    local absent = 0

    for i = 1, #entries do
        local entry = entries[i]
        local tableName = safeIdentifier(entry.table)
        local columnName = safeIdentifier(entry.column)

        if not tableName or not columnName then
            allOk = false
            lastError = ('invalid table or column name in config (table="%s" column="%s")')
                :format(tostring(entry.table), tostring(entry.column))
            log.error('bridge', 'owned-vehicle lookup skipped: %s', lastError)
        else
            local key = tableName .. '.' .. columnName
            local exists, checkError = columnExists(tableName, columnName)

            if exists == nil then
                allOk = false
                lastError = checkError
                log.warn('bridge', 'could not check whether `%s`.`%s` exists: %s. Treating the plate lookup as failed.',
                    tableName, columnName, tostring(checkError))
            elseif exists == false then
                absent = absent + 1
                if not warnedAbsent[key] then
                    warnedAbsent[key] = true
                    log.warn('bridge', '`%s`.`%s` does not exist in this database, so it is being skipped. This is a config mismatch, not a database failure - remove that entry from Config.FrameworkOptions.%s.vehicleTables to silence this.',
                        tableName, columnName, bridge.name())
                end
            else
                local sql = ('SELECT `%s` AS plate FROM `%s` WHERE `%s` IS NOT NULL AND `%s` <> \'\'')
                    :format(columnName, tableName, columnName, columnName)

                local rows, err = dbQuery(sql)

                if not rows then
                    allOk = false
                    lastError = err
                    log.warn('bridge', 'owned-vehicle plate lookup failed for `%s`.`%s`: %s. The table exists, so this is a real database problem - check the oxmysql error printed above this line.',
                        tableName, columnName, tostring(err))
                else
                    for j = 1, #rows do
                        local plate = util.normalisePlate(rows[j].plate)
                        if plate then collected[plate] = true end
                    end
                    log.debug('bridge', 'loaded %d plates from `%s`.`%s`', #rows, tableName, columnName)
                end
            end
        end
    end

    return collected, allOk, lastError, absent
end

local standalone = {
    name = 'standalone',
    isAdmin = function(source)
        return aceAllows(source)
    end,
    notify = function(source, message)
        chatFallback(source, message)
    end,
    getPlayerLabel = function(source)
        return baseLabel(source)
    end,
    fetchPlates = function()
        return {}, true, nil
    end
}

local esx
esx = {
    name = 'esx',
    object = nil,
    isAdmin = function(source)
        if aceAllows(source) then return true end
        local core = esx.object
        if not core then return false end
        local ok, allowed = pcall(function()
            local xPlayer = core.GetPlayerFromId(source)
            if not xPlayer then return false end
            local group = xPlayer.getGroup and xPlayer.getGroup() or nil
            if not group then return false end
            local groups = Config.FrameworkOptions.esx.adminGroups or {}
            for i = 1, #groups do
                if groups[i] == group then return true end
            end
            return false
        end)
        return ok and allowed or false
    end,
    notify = function(source, message)
        local core = esx.object
        if core then
            local ok = pcall(function()
                local xPlayer = core.GetPlayerFromId(source)
                if xPlayer and xPlayer.showNotification then
                    xPlayer.showNotification(message)
                    return true
                end
                error('no notification function')
            end)
            if ok then return end
        end
        chatFallback(source, message)
    end,
    getPlayerLabel = function(source)
        local core = esx.object
        if core then
            local ok, label = pcall(function()
                local xPlayer = core.GetPlayerFromId(source)
                if xPlayer and xPlayer.getName then
                    return ('%s (%s)'):format(xPlayer.getName(), xPlayer.identifier or 'no-identifier')
                end
                return nil
            end)
            if ok and label then return label end
        end
        return baseLabel(source)
    end,
    fetchPlates = function()
        return fetchPlatesFrom(Config.FrameworkOptions.esx.vehicleTables or {})
    end
}

local qb
qb = {
    name = 'qb',
    object = nil,
    isAdmin = function(source)
        if aceAllows(source) then return true end
        local core = qb.object
        if not core then return false end
        local permissions = Config.FrameworkOptions.qb.adminPermissions or {}
        local ok, allowed = pcall(function()
            if not core.Functions or not core.Functions.HasPermission then return false end
            for i = 1, #permissions do
                if core.Functions.HasPermission(source, permissions[i]) then return true end
            end
            return false
        end)
        return ok and allowed or false
    end,
    notify = function(source, message, kind)
        local mapped = (kind == 'error' and 'error') or (kind == 'success' and 'success') or 'primary'
        local ok = pcall(function()
            TriggerClientEvent('QBCore:Notify', source, message, mapped)
        end)
        if not ok then chatFallback(source, message) end
    end,
    getPlayerLabel = function(source)
        local core = qb.object
        if core then
            local ok, label = pcall(function()
                local player = core.Functions and core.Functions.GetPlayer and core.Functions.GetPlayer(source)
                if player and player.PlayerData then
                    local info = player.PlayerData.charinfo
                    if info then
                        return ('%s %s (%s)'):format(info.firstname or '?', info.lastname or '?',
                            player.PlayerData.citizenid or 'no-citizenid')
                    end
                end
                return nil
            end)
            if ok and label then return label end
        end
        return baseLabel(source)
    end,
    fetchPlates = function()
        return fetchPlatesFrom(Config.FrameworkOptions.qb.vehicleTables or {})
    end
}

local function resolve()
    local want = Config.Framework or 'auto'

    if want == 'standalone' then return standalone end

    local esxResource = Config.FrameworkOptions.esx.resource or 'es_extended'
    local qbResource = Config.FrameworkOptions.qb.resource or 'qb-core'

    if want == 'auto' or want == 'esx' then
        if GetResourceState(esxResource) == 'started' then
            local ok, object = pcall(function()
                return exports[esxResource]:getSharedObject()
            end)
            if ok and type(object) == 'table' then
                esx.object = object
                return esx
            end
            log.warn('bridge', 'resource "%s" is running but getSharedObject() did not return an object', esxResource)
        elseif want == 'esx' then
            log.warn('bridge', 'Config.Framework is "esx" but resource "%s" is not started', esxResource)
        end
    end

    if want == 'auto' or want == 'qb' then
        if GetResourceState(qbResource) == 'started' then
            local ok, object = pcall(function()
                return exports[qbResource]:GetCoreObject()
            end)
            if ok and type(object) == 'table' then
                qb.object = object
                return qb
            end
            log.warn('bridge', 'resource "%s" is running but GetCoreObject() did not return an object', qbResource)
        elseif want == 'qb' then
            log.warn('bridge', 'Config.Framework is "qb" but resource "%s" is not started', qbResource)
        end
    end

    return standalone
end

function bridge.init()
    impl = resolve()
    state.framework = impl.name
    state.frameworkObject = impl.object

    if impl.name == 'standalone' then
        log.info('bridge', 'framework resolved: standalone (no framework detected or standalone forced) - all features remain available')
    else
        log.info('bridge', 'framework resolved: %s', impl.name)
    end
end

function bridge.name()
    return impl and impl.name or 'standalone'
end

function bridge.isAdmin(source)
    if not source or source == 0 then return true end
    if not impl then return false end
    local ok, result = pcall(impl.isAdmin, source)
    return ok and result == true
end

function bridge.notify(source, message, kind)
    if not source or source == 0 then return end
    kind = kind or 'inform'

    if caps.oxlib then
        local typeMap = { inform = 'inform', info = 'inform', error = 'error', success = 'success', warning = 'warning', warn = 'warning' }
        TriggerClientEvent('ox_lib:notify', source, {
            title = 'Server Optimizer',
            description = message,
            type = typeMap[kind] or 'inform'
        })
        return
    end

    if impl then
        local ok = pcall(impl.notify, source, message, kind)
        if ok then return end
    end

    chatFallback(source, message)
end

function bridge.getPlayerLabel(source)
    if not source or source == 0 then return 'console' end
    if impl then
        local ok, label = pcall(impl.getPlayerLabel, source)
        if ok and label then return label end
    end
    return baseLabel(source)
end

function bridge.refreshPlates()
    if not impl then return false end

    local collected, allOk, lastError, absent = impl.fetchPlates()

    local extra = Config.FrameworkOptions.alwaysProtectedPlates or {}
    for i = 1, #extra do
        local plate = util.normalisePlate(extra[i])
        if plate then collected[plate] = true end
    end

    for plate in pairs(manualPlates) do
        collected[plate] = true
    end

    plateSet = collected
    plateCount = util.count(collected)
    plateFetchedAt = GetGameTimer()

    state.plateLookupOk = allOk
    state.plateLookupError = allOk and nil or lastError

    if impl.name == 'standalone' then
        log.debug('bridge', 'standalone: no owned-vehicle plates to protect (%d manual entries)', plateCount)
    elseif allOk then
        if lastRefreshCount ~= plateCount then
            log.info('bridge', 'protected plate cache: %d plates%s', plateCount,
                (absent or 0) > 0 and (', ' .. absent .. ' configured table(s) not present in this database and skipped') or '')
        else
            log.debug('bridge', 'protected plate cache refreshed: %d plates', plateCount)
        end
    else
        log.warn('bridge', 'protected plate cache refreshed WITH ERRORS: %d plates loaded, last error: %s', plateCount, tostring(lastError))
    end

    lastRefreshCount = plateCount

    return allOk
end

function bridge.isPlateProtected(plate)
    local normalised = util.normalisePlate(plate)
    if not normalised then return false end
    return plateSet[normalised] == true
end

function bridge.protectPlate(plate)
    local normalised = util.normalisePlate(plate)
    if not normalised then return false end
    manualPlates[normalised] = true
    if not plateSet[normalised] then
        plateSet[normalised] = true
        plateCount = plateCount + 1
    end
    return true
end

function bridge.unprotectPlate(plate)
    local normalised = util.normalisePlate(plate)
    if not normalised then return false end
    manualPlates[normalised] = nil
    return true
end

function bridge.plateStats()
    return {
        framework = bridge.name(),
        count = plateCount,
        ok = state.plateLookupOk,
        error = state.plateLookupError,
        fetchedAt = plateFetchedAt,
        required = Config.Sweeper.requirePlateLookup == true,
        applicable = bridge.name() ~= 'standalone'
    }
end

function bridge.plateLookupBlocksLiveSweep()
    if bridge.name() == 'standalone' then return false end
    if Config.Sweeper.requirePlateLookup ~= true then return false end
    return state.plateLookupOk ~= true
end

function bridge.start()
    bridge.init()

    Dehz.util.loop('bridge', function()
        return Config.FrameworkOptions.plateRefreshInterval or 600000
    end, function()
        bridge.refreshPlates()
    end, 3000)
end

Dehz.bridge = bridge
