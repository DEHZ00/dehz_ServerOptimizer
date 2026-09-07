local Dehz = Dehz
local log = Dehz.log
local util = Dehz.util
local state = Dehz.state
local caps = Dehz.caps
local bridge = Dehz.bridge

local nui = {}

local lastRequestAt = {}
local MAX_FINDINGS_PER_RESOURCE = 100
local MAX_RESOURCES = 60

local function throttled(source)
    local now = GetGameTimer()
    local last = lastRequestAt[source] or 0
    if now - last < 750 then return true end
    lastRequestAt[source] = now
    return false
end

local function meta()
    local score, components = Dehz.health.score()
    return {
        mode = state.mode(),
        framework = bridge.name(),
        health = score,
        components = components,
        uptimeMs = state.uptime(),
        players = #GetPlayers(),
        dryRun = state.isDryRun(),
        sweeperAction = state.sweeperAction(),
        capabilities = caps.summary(),
        serverName = GetConvar('sv_hostname', 'FiveM Server'),
        refreshInterval = Config.Dashboard.refreshInterval or 2000
    }
end

local function overviewPayload()
    local hitchReport = Dehz.hitch.report()
    local audit = Dehz.auditor.report()

    return {
        entities = Dehz.entities.snapshot(),
        scan = Dehz.entities.scanInfo(),
        sparkline = Dehz.hitch.sparkline(60),
        windows = hitchReport.windows,
        perf = hitchReport.perf,
        hitchCounts = hitchReport.counts,
        hitchSources = hitchReport.sources,
        baselineMs = hitchReport.baselineMs,
        unresolvedCritical = audit.counts.critical,
        unresolvedWarning = audit.counts.warning,
        stateBagRate = Dehz.statebags.currentRate(),
        network = Dehz.network.latest(),
        sweeper = Dehz.sweeper.status(),
        culling = Dehz.culling.status(),
        profiler = Dehz.profiler.status()
    }
end

local function entitiesPayload()
    return {
        counts = Dehz.entities.counts(),
        ratio = Dehz.entities.ratio(),
        scan = Dehz.entities.scanInfo(),
        topModels = {
            vehicles = Dehz.entities.topModels('vehicles', Config.Entities.topModelCount or 20),
            peds = Dehz.entities.topModels('peds', Config.Entities.topModelCount or 20),
            objects = Dehz.entities.topModels('objects', Config.Entities.topModelCount or 20)
        },
        byResource = Dehz.entities.topScripts(20),
        history = Dehz.sweeper.history(20),
        status = Dehz.sweeper.status(),
        plates = bridge.plateStats()
    }
end

local function resourcesPayload()
    local report = Dehz.analyzer.report()
    local trimmed = {}

    for i = 1, math.min(#(report.resources or {}), MAX_RESOURCES) do
        local r = report.resources[i]
        local findings = {}
        for j = 1, math.min(#r.findings, MAX_FINDINGS_PER_RESOURCE) do
            findings[j] = r.findings[j]
        end

        trimmed[i] = {
            name = r.name,
            state = r.state,
            score = r.score,
            partial = r.partial,
            escrowed = r.escrowed,
            stats = r.stats,
            observed = r.observed,
            streamBytes = r.streamBytes,
            streamFiles = r.streamFiles,
            findingCount = #r.findings,
            findingsTruncated = #r.findings > MAX_FINDINGS_PER_RESOURCE,
            findings = findings
        }
    end

    return {
        estimateOnly = true,
        note = 'Risk scores are ESTIMATED from static code patterns. They are not measured CPU time.',
        observedNote = 'The entities, errors and stream columns are OBSERVED behaviour, not static analysis. They work on escrow-protected resources too, because escrow hides source, not what a resource does at runtime.',
        generatedAt = report.generatedAt,
        durationMs = report.durationMs,
        streamMeasured = report.streamMeasured,
        totalStreamBytes = report.totalStreamBytes,
        scanned = report.scanned,
        resources = trimmed,
        unscannable = report.unscannable,
        progress = Dehz.analyzer.progress(),
        profiler = {
            status = Dehz.profiler.status(),
            report = Dehz.profiler.report()
        }
    }
end

local function auditPayload()
    return Dehz.auditor.report()
end

local function hitchesPayload()
    local report = Dehz.hitch.report()
    return {
        report = report,
        history = Dehz.hitch.history(80),
        worst = Dehz.hitch.worst(),
        console = Dehz.hitch.consoleVolume(10),
        sparkline = Dehz.hitch.sparkline(120)
    }
end

local function logsPayload(filters)
    filters = filters or {}
    return {
        entries = log.recent(200, filters.module, filters.level),
        modules = log.modules(),
        webhook = Dehz.webhook.stats(),
        database = { available = Dehz.persist.available(), reason = Dehz.persist.reason() }
    }
end

local builders = {
    overview = overviewPayload,
    entities = entitiesPayload,
    resources = resourcesPayload,
    audit = auditPayload,
    hitches = hitchesPayload,
    logs = logsPayload
}

local function buildPayload(tab, filters)
    local builder = builders[tab] or overviewPayload
    local ok, data = pcall(builder, filters)
    if not ok then
        log.error('nui', 'failed to build payload for tab "%s": %s', tostring(tab), tostring(data))
        data = {}
    end
    return { tab = tab, meta = meta(), data = data }
end

local function audit(source, message, ...)
    log.warn('nui', '%s by %s: ' .. message, 'dashboard action', bridge.getPlayerLabel(source), ...)
end

RegisterNetEvent('dehz_so:client:ready', function()
    local source = source
    TriggerClientEvent('dehz_so:client:init', source, {
        command = Config.Dashboard.command or 'serveropt',
        keybind = Config.Dashboard.keybind or { enabled = false }
    })
end)

RegisterNetEvent('dehz_so:request:open', function()
    local source = source
    if not Config.Dashboard.enabled then return end
    if not bridge.isAdmin(source) then return end
    if throttled(source) then return end

    log.info('nui', 'dashboard opened by %s', bridge.getPlayerLabel(source))
    TriggerClientEvent('dehz_so:client:open', source, buildPayload('overview'))
end)

RegisterNetEvent('dehz_so:request:refresh', function(tab, filters)
    local source = source
    if not Config.Dashboard.enabled then return end
    if not bridge.isAdmin(source) then return end
    if throttled(source) then return end
    if type(tab) ~= 'string' then return end

    TriggerClientEvent('dehz_so:client:data', source, buildPayload(tab, type(filters) == 'table' and filters or nil))
end)

RegisterNetEvent('dehz_so:action', function(action, params)
    local source = source
    if not Config.Dashboard.enabled then return end
    if not bridge.isAdmin(source) then return end
    if type(action) ~= 'string' then return end

    params = type(params) == 'table' and params or {}

    if action == 'sweep' then
        local category = type(params.category) == 'string' and params.category or 'all'
        local dryRun = params.dryRun ~= false

        audit(source, 'entity sweep requested (category=%s, dryRun=%s)', category, tostring(dryRun))

        util.thread('nui', function()
            local result = Dehz.sweeper.forceSweep(category, dryRun)
            TriggerClientEvent('dehz_so:client:action', source, {
                action = 'sweep',
                ok = result.blocked == nil,
                blocked = result.blocked,
                result = result
            })
            TriggerClientEvent('dehz_so:client:data', source, buildPayload('entities'))
        end)
        return
    end

    if action == 'audit' then
        audit(source, 'config audit re-run requested')
        util.thread('nui', function()
            Dehz.auditor.run(bridge.getPlayerLabel(source))
            TriggerClientEvent('dehz_so:client:data', source, buildPayload('audit'))
        end)
        return
    end

    if action == 'analyze' then
        audit(source, 'resource analysis re-run requested')
        util.thread('nui', function()
            Dehz.analyzer.run(bridge.getPlayerLabel(source))
            TriggerClientEvent('dehz_so:client:data', source, buildPayload('resources'))
        end)
        return
    end

    if action == 'export' then
        audit(source, 'health report export requested')
        util.thread('nui', function()
            local written, err = Dehz.export.write(bridge.getPlayerLabel(source))
            TriggerClientEvent('dehz_so:client:action', source, {
                action = 'export',
                ok = written ~= nil,
                error = err,
                files = written and { json = written.json, text = written.text } or nil,
                text = written and written.textBody or nil
            })
        end)
        return
    end

    if action == 'profile' then
        if not Config.Profiler.enabled then
            TriggerClientEvent('dehz_so:client:action', source, {
                action = 'profile', ok = false,
                error = 'The profiler module is disabled in config.lua.'
            })
            return
        end

        audit(source, 'profiler run requested (frames=%s)', tostring(params.frames))
        local started, reason = Dehz.profiler.run(params.frames, bridge.getPlayerLabel(source))
        TriggerClientEvent('dehz_so:client:action', source, {
            action = 'profile', ok = started, error = started and nil or reason, message = started and reason or nil
        })
        return
    end

    if action == 'rescanEntities' then
        util.thread('nui', function()
            Dehz.entities.forceScan()
            TriggerClientEvent('dehz_so:client:data', source, buildPayload('entities'))
        end)
        return
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    lastRequestAt[src] = nil
end)

function nui.start()
    if not Config.Dashboard.enabled then
        log.info('nui', 'dashboard disabled in config')
        return
    end

    RegisterCommand(Config.Dashboard.command or 'serveropt', function(source)
        if source == 0 then
            log.info('nui', 'the dashboard is an in-game interface and cannot be opened from the server console. Use the exports or the exported health report instead.')
            return
        end
        if not bridge.isAdmin(source) then return end
        TriggerClientEvent('dehz_so:client:open', source, buildPayload('overview'))
    end, false)

    log.info('nui', 'dashboard command "/%s" registered', Config.Dashboard.command or 'serveropt')
end

Dehz.nui = nui
