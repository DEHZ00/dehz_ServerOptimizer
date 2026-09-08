local Dehz = Dehz
local log = Dehz.log
local util = Dehz.util
local state = Dehz.state
local caps = Dehz.caps

local function ensure(parent, key, fallback)
    if type(parent[key]) ~= 'table' then
        parent[key] = fallback
        return true
    end
    return false
end

local function normaliseConfig()
    local repaired = {}

    if type(Config) ~= 'table' then Config = {} end

    if ensure(Config, 'Logging', { level = 'info', colours = true, bufferSize = 400 }) then repaired[#repaired + 1] = 'Config.Logging' end
    if ensure(Config, 'Permissions', { ace = 'dehz.optimizer', allowCommandAce = true }) then repaired[#repaired + 1] = 'Config.Permissions' end
    if ensure(Config, 'FrameworkOptions', {}) then repaired[#repaired + 1] = 'Config.FrameworkOptions' end
    ensure(Config.FrameworkOptions, 'esx', { resource = 'es_extended', vehicleTables = {}, adminGroups = {} })
    ensure(Config.FrameworkOptions, 'qb', { resource = 'qb-core', vehicleTables = {}, adminPermissions = {} })
    ensure(Config.FrameworkOptions, 'alwaysProtectedPlates', {})

    if ensure(Config, 'Dashboard', { enabled = true, command = 'serveropt', refreshInterval = 2000 }) then repaired[#repaired + 1] = 'Config.Dashboard' end
    ensure(Config.Dashboard, 'keybind', { enabled = false, key = 'F7' })

    if ensure(Config, 'Entities', { enabled = true, scanInterval = 15000, entitiesPerTick = 250, topModelCount = 20 }) then repaired[#repaired + 1] = 'Config.Entities' end
    ensure(Config.Entities, 'categories', { vehicles = true, peds = true, objects = true })

    if ensure(Config, 'Sweeper', { enabled = false, dryRun = true, action = 'report' }) then repaired[#repaired + 1] = 'Config.Sweeper' end
    ensure(Config.Sweeper, 'categories', {})
    ensure(Config.Sweeper, 'protect', {})
    ensure(Config.Sweeper.protect, 'zones', {})
    ensure(Config.Sweeper.protect, 'models', {})
    ensure(Config.Sweeper.protect, 'resources', {})
    ensure(Config.Sweeper.protect, 'routingBuckets', {})
    ensure(Config.Sweeper.protect, 'foreignStateKeys', {})

    if ensure(Config, 'Culling', { enabled = false, acknowledgeDeprecated = false }) then repaired[#repaired + 1] = 'Config.Culling' end
    ensure(Config.Culling, 'radii', {})
    ensure(Config.Culling, 'modelOverrides', {})

    if ensure(Config, 'Auditor', { enabled = true, runAtStart = true, allowAutoApply = false }) then repaired[#repaired + 1] = 'Config.Auditor' end
    ensure(Config.Auditor, 'suppress', {})
    ensure(Config.Auditor, 'recommended', {})

    if ensure(Config, 'Hitch', { enabled = true }) then repaired[#repaired + 1] = 'Config.Hitch' end
    ensure(Config.Hitch, 'sources', { perf = true, console = true, timer = true })
    ensure(Config.Hitch, 'perf', { interval = 10000, host = '127.0.0.1', port = 0 })
    ensure(Config.Hitch, 'thresholds', { minor = 90, major = 150, severe = 500 })
    ensure(Config.Hitch, 'syncThresholds', { minor = 60, major = 100, severe = 300 })

    if ensure(Config, 'Analyzer', { enabled = true, runAtStart = true }) then repaired[#repaired + 1] = 'Config.Analyzer' end
    ensure(Config.Analyzer, 'ignoreResources', {})
    ensure(Config.Analyzer, 'ignoreFindings', {})
    ensure(Config.Analyzer, 'ignorePatterns', {})
    ensure(Config.Analyzer, 'extraPatterns', {})
    ensure(Config.Analyzer, 'weights', {})

    if ensure(Config, 'StateBags', { enabled = true, window = 10000, threshold = 20 }) then repaired[#repaired + 1] = 'Config.StateBags' end
    if ensure(Config, 'Network', { enabled = true, sampleInterval = 30000 }) then repaired[#repaired + 1] = 'Config.Network' end
    if ensure(Config, 'Profiler', { enabled = false }) then repaired[#repaired + 1] = 'Config.Profiler' end

    if ensure(Config, 'Reporting', {}) then repaired[#repaired + 1] = 'Config.Reporting' end
    ensure(Config.Reporting, 'webhooks', {})
    ensure(Config.Reporting, 'export', { directory = 'reports', keep = 10 })

    if ensure(Config, 'Database', { enabled = false, tablePrefix = 'dehz_so_' }) then repaired[#repaired + 1] = 'Config.Database' end

    return repaired
end

local function validateConfig()
    local problems = {}

    if Config.Mode ~= 'monitor' and Config.Mode ~= 'active' then
        problems[#problems + 1] = ('Config.Mode is "%s" which is not valid. Falling back to "monitor".'):format(tostring(Config.Mode))
        Config.Mode = 'monitor'
    end

    local action = Config.Sweeper.action
    if action ~= 'report' and action ~= 'orphan' and action ~= 'delete' then
        problems[#problems + 1] = ('Config.Sweeper.action is "%s" which is not valid. Falling back to "report".'):format(tostring(action))
        Config.Sweeper.action = 'report'
    end

    if (Config.Sweeper.maxDeletionsPerSweep or 0) <= 0 then
        problems[#problems + 1] = 'Config.Sweeper.maxDeletionsPerSweep must be greater than 0. Falling back to 50.'
        Config.Sweeper.maxDeletionsPerSweep = 50
    end

    if (Config.Sweeper.graceSweeps or 0) < 1 then
        problems[#problems + 1] = 'Config.Sweeper.graceSweeps must be at least 1. Falling back to 1.'
        Config.Sweeper.graceSweeps = 1
    end

    local frameMs = Dehz.SERVER_FRAME_MS
    if (Config.Hitch.thresholds.minor or 0) <= frameMs then
        problems[#problems + 1] = ('Config.Hitch.thresholds.minor is %s, which is at or below the %dms server tick interval. Every single tick would be reported as a hitch. Raise it.')
            :format(tostring(Config.Hitch.thresholds.minor), frameMs)
    end

    if Config.Mode == 'active' and Config.Sweeper.dryRun == false and Config.Sweeper.action == 'delete' then
        problems[#problems + 1] = 'LIVE DELETION IS ARMED. Config.Mode is "active", dryRun is false and action is "delete". This resource will delete world entities.'
    end

    for i = 1, #problems do
        log.warn('boot', '%s', problems[i])
    end

    return problems
end

local function banner()
    log.banner({
        '',
        'Dehz_ServerOptimizer  v' .. tostring(GetResourceMetadata(GetCurrentResourceName(), 'version', 0)),
        'server-side performance diagnostics and cleanup',
        ''
    })
end

CreateThread(function()
    local repaired = normaliseConfig()
    log.configure()
    banner()

    for i = 1, #repaired do
        log.warn('boot', '%s was missing from config.lua and has been replaced with a safe default. Compare your config against the shipped one.', repaired[i])
    end

    util.guard('boot', caps.probe)
    caps.report()

    validateConfig()

    log.info('boot', 'operating mode: %s%s', state.mode(),
        state.mode() == 'monitor' and ' (nothing will be deleted or changed)' or ' (destructive modules may act, subject to their own dry-run switches)')

    util.guard('boot', Dehz.bridge.start)
    util.guard('boot', Dehz.persist.init)
    util.guard('boot', Dehz.entities.start)
    util.guard('boot', Dehz.sweeper.start)
    util.guard('boot', Dehz.culling.start)
    util.guard('boot', Dehz.auditor.start)
    util.guard('boot', Dehz.hitch.start)
    util.guard('boot', Dehz.analyzer.start)
    util.guard('boot', Dehz.statebags.start)
    util.guard('boot', Dehz.network.start)
    util.guard('boot', Dehz.profiler.start)
    util.guard('boot', Dehz.nui.start)
    util.guard('boot', Dehz.diagnose.start)

    log.info('boot', 'ready')
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    log.info('boot', 'stopping')
end)
