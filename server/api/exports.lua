local Dehz = Dehz
local state = Dehz.state
local caps = Dehz.caps

local function async(label, fn, ...)
    if coroutine.isyieldable() then
        return fn(...)
    end

    local args = table.pack(...)
    Dehz.util.thread('exports', function()
        fn(table.unpack(args, 1, args.n))
    end)

    return {
        async = true,
        started = true,
        note = ('%s yields, and it was called from a context that cannot yield. It has been started in the background - call it from inside a thread (CreateThread) to receive the result table.'):format(label)
    }
end

exports('getHealthScore', function()
    local score, components = Dehz.health.score()
    return score, components
end)

exports('getMetrics', function()
    return {
        mode = state.mode(),
        framework = Dehz.bridge.name(),
        uptimeMs = state.uptime(),
        entities = Dehz.entities.snapshot(),
        hitches = Dehz.hitch.report().counts,
        stateBagRate = Dehz.statebags.currentRate(),
        network = Dehz.network.latest(),
        sweeper = Dehz.sweeper.status()
    }
end)

exports('getHitchHistory', function(count)
    return Dehz.hitch.history(count or 50)
end)

exports('getHitchPercentiles', function(windowMs)
    return Dehz.hitch.percentiles(windowMs or 60000)
end)

exports('getEntityCounts', function()
    return Dehz.entities.counts()
end)

exports('rescanEntities', function()
    return async('rescanEntities', Dehz.entities.forceScan)
end)

exports('getEntityBreakdown', function()
    return {
        counts = Dehz.entities.counts(),
        topModels = {
            vehicles = Dehz.entities.topModels('vehicles', 20),
            peds = Dehz.entities.topModels('peds', 20),
            objects = Dehz.entities.topModels('objects', 20)
        },
        byResource = Dehz.entities.topScripts(20),
        scan = Dehz.entities.scanInfo()
    }
end)

exports('getAuditFindings', function()
    return Dehz.auditor.report()
end)

exports('getResourceReport', function()
    return Dehz.analyzer.report()
end)

exports('getStateBagReport', function()
    return Dehz.statebags.report()
end)

exports('getNetworkReport', function()
    return Dehz.network.report()
end)

exports('forceSweep', function(category, dryRun)
    return async('forceSweep', Dehz.sweeper.forceSweep, category, dryRun)
end)

exports('getSweepHistory', function(count)
    return Dehz.sweeper.history(count or 25)
end)

exports('protectEntity', function(entity)
    return Dehz.sweeper.protectEntity(entity)
end)

exports('unprotectEntity', function(entity)
    return Dehz.sweeper.unprotectEntity(entity)
end)

exports('isEntityProtected', function(entity)
    return Dehz.sweeper.isEntityProtected(entity)
end)

exports('protectPlate', function(plate)
    return Dehz.bridge.protectPlate(plate)
end)

exports('unprotectPlate', function(plate)
    return Dehz.bridge.unprotectPlate(plate)
end)

exports('isPlateProtected', function(plate)
    return Dehz.bridge.isPlateProtected(plate)
end)

exports('isDryRun', function()
    return state.isDryRun()
end)

exports('getMode', function()
    return state.mode()
end)

exports('getFramework', function()
    return Dehz.bridge.name()
end)

exports('getCapabilities', function()
    return caps.summary()
end)

exports('getPlateProtectionStatus', function()
    return Dehz.bridge.plateStats()
end)

exports('buildHealthReport', function()
    return Dehz.export.build()
end)

exports('exportHealthReport', function(actor)
    return Dehz.export.write(actor or 'export-api')
end)

exports('runConfigAudit', function()
    return Dehz.auditor.run('export-api')
end)

exports('runResourceAnalysis', function()
    return async('runResourceAnalysis', Dehz.analyzer.run, 'export-api')
end)

exports('runProfile', function(frames, actor)
    if not Config.Profiler.enabled then
        return false, 'the profiler module is disabled in config.lua'
    end
    return Dehz.profiler.run(frames, actor or 'export-api')
end)

exports('getProfilerStatus', function()
    return Dehz.profiler.status()
end)

exports('getProfileReport', function()
    return Dehz.profiler.report()
end)

exports('getLogs', function(count, module, level)
    return Dehz.log.recent(count or 100, module, level)
end)

exports('isAdmin', function(source)
    return Dehz.bridge.isAdmin(source)
end)
