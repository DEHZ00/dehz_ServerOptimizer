local Dehz = Dehz

local state = {
    startedAt = GetGameTimer(),
    bootedAt = os.time(),
    framework = 'standalone',
    frameworkObject = nil,
    plateLookupOk = nil,
    plateLookupError = nil,
    sweepRunning = false,
    lastSweepAt = 0,
    counters = {
        sweeps = 0,
        reported = 0,
        orphaned = 0,
        deleted = 0,
        resurrections = 0
    }
}

function state.uptime()
    return GetGameTimer() - state.startedAt
end

function state.mode()
    local mode = Config and Config.Mode or 'monitor'
    if mode ~= 'active' then return 'monitor' end
    return 'active'
end

function state.isActive()
    return state.mode() == 'active'
end

function state.playerCount()
    return #GetPlayers()
end

function state.sweeperAction()
    if not state.isActive() then return 'report' end
    if Config.Sweeper.dryRun ~= false then return 'report' end
    local action = Config.Sweeper.action
    if action == 'delete' or action == 'orphan' then return action end
    return 'report'
end

function state.isDryRun()
    return state.sweeperAction() == 'report'
end

Dehz.state = state
