local Dehz = Dehz
local log = Dehz.log
local caps = Dehz.caps

local persist = {}

local ready = false
local disabledReason = nil

local function prefix()
    return Config.Database.tablePrefix or 'dehz_so_'
end

local function execute(sql, params)
    if not ready then return false end
    local ok, err = pcall(function()
        exports.oxmysql:query(sql, params or {}, function() end)
    end)
    if not ok then
        log.warn('persist', 'database write failed: %s', tostring(err))
        return false
    end
    return true
end

local function query(sql, params, timeoutMs)
    if not ready then return nil, disabledReason or 'database not ready' end

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
    if type(result) ~= 'table' then return nil, 'no result set' end
    if result.__dehzTimeout then return nil, 'timed out' end
    if result.__dehzError then return nil, result.__dehzError end
    return result
end

local function createTables()
    local p = prefix()

    execute(([[CREATE TABLE IF NOT EXISTS `%shitches` (
        `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `recorded_at` DATETIME NOT NULL,
        `thread` VARCHAR(16) NOT NULL,
        `source` VARCHAR(16) NOT NULL,
        `duration_ms` INT NOT NULL,
        `severity` VARCHAR(16) NOT NULL,
        `players` INT NOT NULL,
        `vehicles` INT NOT NULL,
        `peds` INT NOT NULL,
        `objects` INT NOT NULL,
        `uptime_ms` BIGINT NOT NULL,
        `statebag_rate` FLOAT NOT NULL,
        `sweep_running` TINYINT(1) NOT NULL,
        PRIMARY KEY (`id`),
        KEY `recorded_at` (`recorded_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]]):format(p))

    execute(([[CREATE TABLE IF NOT EXISTS `%smetrics` (
        `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `recorded_at` DATETIME NOT NULL,
        `players` INT NOT NULL,
        `vehicles` INT NOT NULL,
        `peds` INT NOT NULL,
        `objects` INT NOT NULL,
        `entity_ratio` FLOAT NOT NULL,
        `avg_ping` INT NOT NULL,
        `avg_packet_loss` FLOAT NOT NULL,
        PRIMARY KEY (`id`),
        KEY `recorded_at` (`recorded_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]]):format(p))

    execute(([[CREATE TABLE IF NOT EXISTS `%ssweeps` (
        `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `recorded_at` DATETIME NOT NULL,
        `category` VARCHAR(16) NOT NULL,
        `action` VARCHAR(16) NOT NULL,
        `dry_run` TINYINT(1) NOT NULL,
        `scanned` INT NOT NULL,
        `eligible` INT NOT NULL,
        `acted` INT NOT NULL,
        `capped` TINYINT(1) NOT NULL,
        `duration_ms` INT NOT NULL,
        `actor` VARCHAR(128) NOT NULL,
        PRIMARY KEY (`id`),
        KEY `recorded_at` (`recorded_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]]):format(p))
end

local function purgeOld()
    local days = tonumber(Config.Database.retentionDays) or 0
    if days <= 0 then return end
    local p = prefix()
    for _, name in ipairs({ 'hitches', 'metrics', 'sweeps' }) do
        execute(('DELETE FROM `%s%s` WHERE `recorded_at` < DATE_SUB(NOW(), INTERVAL ? DAY)'):format(p, name), { days })
    end
end

function persist.available()
    return ready
end

function persist.reason()
    return disabledReason
end

function persist.init()
    if not Config.Database.enabled then
        disabledReason = 'disabled in config'
        return
    end

    if not caps.oxmysql then
        disabledReason = 'oxmysql is not running'
        log.warn('persist', 'Config.Database.enabled is true but oxmysql is not running. Long-term history is disabled; everything else works from in-memory buffers.')
        return
    end

    ready = true

    if Config.Database.createTables then
        createTables()
    end

    purgeOld()
    log.info('persist', 'database history enabled (table prefix "%s")', prefix())
end

function persist.recordHitch(hitch, snapshot)
    if not ready then return end
    execute(('INSERT INTO `%shitches` (recorded_at, thread, source, duration_ms, severity, players, vehicles, peds, objects, uptime_ms, statebag_rate, sweep_running) VALUES (NOW(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'):format(prefix()), {
        hitch.thread, hitch.source, hitch.duration, hitch.severity,
        snapshot.players or 0, snapshot.vehicles or 0, snapshot.peds or 0, snapshot.objects or 0,
        snapshot.uptime or 0, snapshot.stateBagRate or 0.0, snapshot.sweepRunning and 1 or 0
    })
end

function persist.recordMetric(sample)
    if not ready then return end
    execute(('INSERT INTO `%smetrics` (recorded_at, players, vehicles, peds, objects, entity_ratio, avg_ping, avg_packet_loss) VALUES (NOW(), ?, ?, ?, ?, ?, ?, ?)'):format(prefix()), {
        sample.players or 0, sample.vehicles or 0, sample.peds or 0, sample.objects or 0,
        sample.ratio or 0.0, sample.avgPing or 0, sample.avgPacketLoss or 0.0
    })
end

function persist.recordSweep(result, actor)
    if not ready then return end
    execute(('INSERT INTO `%ssweeps` (recorded_at, category, action, dry_run, scanned, eligible, acted, capped, duration_ms, actor) VALUES (NOW(), ?, ?, ?, ?, ?, ?, ?, ?, ?)'):format(prefix()), {
        result.category, result.action, result.dryRun and 1 or 0,
        result.scanned or 0, result.eligible or 0, result.acted or 0,
        result.capped and 1 or 0, result.durationMs or 0, actor or 'scheduler'
    })
end

function persist.recentHitches(count)
    if not ready then return {} end
    local rows = query(('SELECT * FROM `%shitches` ORDER BY `id` DESC LIMIT ?'):format(prefix()), { count or 50 })
    return rows or {}
end

Dehz.persist = persist
