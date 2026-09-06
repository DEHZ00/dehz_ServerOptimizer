local Dehz = Dehz
local log = Dehz.log
local util = Dehz.util
local state = Dehz.state
local caps = Dehz.caps

local hitch = {}

local history
local worst = {}
local rawSamples
local secondSamples
local currentSecond, currentSecondMax = 0, 0
local lastWebhookAt = 0
local counts = { minor = 0, major = 0, severe = 0 }
local bySource = { perf = 0, console = 0, timer = 0 }
local byThread = {}
local channelVolume = {}
local scriptErrors = {}
local perfState = {}
local perfLastAt = 0
local timerActive = false

local ENGINE_MAIN_THRESHOLD = 150
local ENGINE_SYNC_THRESHOLD = 100

local function thresholdsFor(thread)
    if thread == 'svSync' then
        return Config.Hitch.syncThresholds or Config.Hitch.thresholds
    end
    return Config.Hitch.thresholds
end

local function severityFor(thread, duration)
    local t = thresholdsFor(thread)
    if duration >= (t.severe or 500) then return 'severe' end
    if duration >= (t.major or 150) then return 'major' end
    if duration >= (t.minor or 90) then return 'minor' end
    return nil
end

local function severityRank(name)
    if name == 'severe' then return 3 end
    if name == 'major' then return 2 end
    if name == 'minor' then return 1 end
    return 0
end

local function snapshot()
    local ents = Dehz.entities.snapshot()
    local net = Dehz.network and Dehz.network.latest() or nil

    return {
        players = ents.players,
        vehicles = ents.vehicles,
        peds = ents.peds,
        objects = ents.objects,
        totalEntities = ents.total,
        ratio = ents.ratio,
        uptime = state.uptime(),
        stateBagRate = Dehz.statebags and Dehz.statebags.currentRate() or 0,
        stateBagTop = Dehz.statebags and Dehz.statebags.topKeys(3) or nil,
        sweepRunning = state.sweepRunning,
        avgPing = net and net.avgPing or nil,
        avgPacketLoss = net and net.avgPacketLoss or nil
    }
end

local function pushWorst(entry)
    worst[#worst + 1] = entry
    table.sort(worst, function(a, b) return a.duration > b.duration end)
    local keep = Config.Hitch.worstCount or 20
    while #worst > keep do table.remove(worst) end
end

local function maybeWebhook(entry)
    local trigger = Config.Hitch.webhookOn
    if not trigger or trigger == false then return end
    if severityRank(entry.severity) < severityRank(trigger) then return end

    local now = GetGameTimer()
    if now - lastWebhookAt < (Config.Hitch.webhookCooldown or 120000) then return end
    lastWebhookAt = now

    local s = entry.context
    Dehz.webhook.send('hitch', {
        title = ('%s hitch on %s - %dms'):format(entry.severity, entry.thread, entry.duration),
        description = ('Detected via %s.'):format(entry.source),
        severity = entry.severity == 'severe' and 'critical' or 'warning',
        fields = {
            { name = 'players', value = ('`%d`'):format(s.players or 0), inline = true },
            { name = 'entities', value = ('`%d` (`%.1f`/player)'):format(s.totalEntities or 0, s.ratio or 0), inline = true },
            { name = 'uptime', value = ('`%.1f` h'):format((s.uptime or 0) / 3600000), inline = true },
            { name = 'vehicles / peds / objects', value = ('`%d` / `%d` / `%d`'):format(s.vehicles or 0, s.peds or 0, s.objects or 0), inline = false },
            { name = 'state bag writes/s', value = ('`%.1f`'):format(s.stateBagRate or 0), inline = true },
            { name = 'sweep running', value = s.sweepRunning and '`yes`' or '`no`', inline = true }
        }
    })
end

local function record(thread, source, duration)
    local severity = severityFor(thread, duration)
    if not severity then return end

    local entry = {
        at = os.time(),
        ms = GetGameTimer(),
        thread = thread,
        source = source,
        duration = duration,
        severity = severity,
        context = snapshot()
    }

    history:push(entry)
    pushWorst(entry)

    counts[severity] = counts[severity] + 1
    bySource[source] = (bySource[source] or 0) + 1
    byThread[thread] = (byThread[thread] or 0) + 1

    Dehz.persist.recordHitch(entry, entry.context)

    if severity ~= 'minor' then
        log.warn('hitch', '%s hitch %dms on %s (via %s) - %d players, %d entities, %.1f state bag writes/s%s',
            severity, duration, thread, source,
            entry.context.players or 0, entry.context.totalEntities or 0,
            entry.context.stateBagRate or 0,
            entry.context.sweepRunning and ', sweep running' or '')
    end

    maybeWebhook(entry)
end

local function parsePrometheus(body)
    local out = {}

    for line in body:gmatch('[^\r\n]+') do
        if line:byte(1) ~= 35 then
            local metric, labelBlock, value = line:match('^([%w_]+)%{(.-)%}%s+(%S+)$')
            if not metric then
                metric, value = line:match('^([%w_]+)%s+(%S+)$')
                labelBlock = ''
            end

            if metric and metric:sub(1, 8) == 'tickTime' then
                local labels = {}
                if labelBlock and labelBlock ~= '' then
                    for k, v in labelBlock:gmatch('([%w_]+)="([^"]*)"') do
                        labels[k] = v
                    end
                end

                local name = labels.name
                if name then
                    out[name] = out[name] or { buckets = {}, order = {} }
                    local numeric = tonumber(value) or 0

                    if metric == 'tickTime_bucket' then
                        local le = labels.le
                        if le then
                            local bound = (le == '+Inf') and math.huge or (tonumber(le) or math.huge)
                            out[name].buckets[bound] = numeric
                            out[name].order[#out[name].order + 1] = bound
                        end
                    elseif metric == 'tickTime_sum' then
                        out[name].sum = numeric
                    elseif metric == 'tickTime_count' then
                        out[name].count = numeric
                    end
                end
            end
        end
    end

    return out
end

local function percentileFromBuckets(bounds, cumulative, total, p)
    if total <= 0 then return 0 end
    local target = total * p
    for i = 1, #bounds do
        local bound = bounds[i]
        if (cumulative[bound] or 0) >= target then
            if bound == math.huge then
                return (bounds[i - 1] or 0) * 1000
            end
            return bound * 1000
        end
    end
    return 0
end

local function processPerf(parsed)
    for name, data in pairs(parsed) do
        local bounds = {}
        for bound in pairs(data.buckets) do bounds[#bounds + 1] = bound end
        table.sort(bounds)

        local previous = perfState[name]
        local deltaCumulative = {}
        local deltaTotal = 0

        if previous then
            local running = 0
            for i = 1, #bounds do
                local bound = bounds[i]
                local diff = (data.buckets[bound] or 0) - (previous.buckets[bound] or 0)
                if diff < 0 then diff = 0 end
                running = diff
                deltaCumulative[bound] = running
            end
            deltaTotal = (data.count or 0) - (previous.count or 0)
        end

        local entry = {
            buckets = data.buckets,
            count = data.count or 0,
            sum = data.sum or 0,
            bounds = bounds
        }

        if previous and deltaTotal > 0 then
            entry.window = {
                ticks = deltaTotal,
                meanMs = (((data.sum or 0) - (previous.sum or 0)) / deltaTotal) * 1000,
                p50 = percentileFromBuckets(bounds, deltaCumulative, deltaTotal, 0.50),
                p95 = percentileFromBuckets(bounds, deltaCumulative, deltaTotal, 0.95),
                p99 = percentileFromBuckets(bounds, deltaCumulative, deltaTotal, 0.99)
            }
        elseif previous then
            entry.window = previous.window
        end

        perfState[name] = entry
    end

    perfLastAt = GetGameTimer()
end

local function scrapePerf()
    PerformHttpRequest(caps.perfUrl(), function(status, body)
        if status ~= 200 or type(body) ~= 'string' then
            if caps.perf then
                log.debug('hitch', 'metrics scrape returned status %s', tostring(status))
            end
            return
        end
        local ok, parsed = pcall(parsePrometheus, body)
        if ok then
            util.guard('hitch', processPerf, parsed)
        end
    end, 'GET', '', caps.perfHeaders())
end

local function startConsoleSource()
    local selfChannel = log.selfChannel

    RegisterConsoleListener(function(channel, message)
        if type(message) ~= 'string' then return end

        if channel and channel == selfChannel then return end

        if message:find('hitch warning', 1, true) then
            local ms = message:match('server thread hitch warning: timer interval of (%d+)')
            if ms then record('svMain', 'console', tonumber(ms)) return end

            ms = message:match('sync thread hitch warning: timer interval of (%d+)')
            if ms then record('svSync', 'console', tonumber(ms)) return end

            ms = message:match('network thread hitch warning: timer interval of (%d+)')
            if ms then record('svNetwork', 'console', tonumber(ms)) return end

            ms = message:match('hitch warning: net frame time of (%d+)')
            if ms then record('svNetwork', 'console', tonumber(ms)) return end

            ms = message:match('hitch warning: frame time of (%d+)')
            if ms then record('svMain', 'console', tonumber(ms)) return end
            return
        end

        if channel and channel:byte(1) == 115 and channel:sub(1, 7) == 'script:' then
            local resource = channel:sub(8)
            channelVolume[resource] = (channelVolume[resource] or 0) + 1
            if message:find('SCRIPT ERROR', 1, true) then
                scriptErrors[resource] = (scriptErrors[resource] or 0) + 1
            end
        end
    end)
end

local function startTimerSource()
    timerActive = true

    util.thread('hitch', function()
        local last = GetGameTimer()

        while true do
            Wait(0)

            local now = GetGameTimer()
            local delta = now - last
            last = now

            rawSamples:push({ t = now, d = delta })

            local second = now // 1000
            if second ~= currentSecond then
                if currentSecond ~= 0 then
                    secondSamples:push({ t = currentSecond * 1000, d = currentSecondMax })
                end
                currentSecond = second
                currentSecondMax = delta
            elseif delta > currentSecondMax then
                currentSecondMax = delta
            end

            if delta >= (Config.Hitch.thresholds.minor or 90) then
                if not (Config.Hitch.sources.console and caps.consoleListener and delta >= ENGINE_MAIN_THRESHOLD) then
                    record('svMain', 'timer', delta)
                end
            end
        end
    end)
end

function hitch.percentiles(windowMs)
    local now = GetGameTimer()
    local values = {}
    local approximate = false
    local source

    if windowMs <= 90000 then
        source = rawSamples:all()
    else
        source = secondSamples:all()
        approximate = true
    end

    for i = 1, #source do
        local item = source[i]
        if now - item.t <= windowMs then
            values[#values + 1] = item.d
        end
    end

    local stats = util.percentiles(values)
    stats.approximate = approximate
    stats.windowMs = windowMs
    return stats
end

function hitch.sparkline(points)
    local wanted = points or 60
    local source = secondSamples:latest(wanted)
    local out = {}
    for i = #source, 1, -1 do
        out[#out + 1] = source[i].d
    end
    return out
end

function hitch.report()
    return {
        enabled = Config.Hitch.enabled == true,
        sources = {
            perf = caps.perf and Config.Hitch.sources.perf == true,
            console = caps.consoleListener and Config.Hitch.sources.console == true,
            timer = timerActive
        },
        counts = counts,
        bySource = bySource,
        byThread = byThread,
        thresholds = Config.Hitch.thresholds,
        syncThresholds = Config.Hitch.syncThresholds,
        thresholdsCalibrated = false,
        baselineMs = Dehz.SERVER_FRAME_MS,
        engineThresholds = { svMain = ENGINE_MAIN_THRESHOLD, svSync = ENGINE_SYNC_THRESHOLD, svNetwork = ENGINE_MAIN_THRESHOLD },
        perf = perfState,
        perfLastAt = perfLastAt,
        windows = {
            ['1m'] = hitch.percentiles(60000),
            ['5m'] = hitch.percentiles(300000),
            ['1h'] = hitch.percentiles(3600000)
        }
    }
end

function hitch.history(count)
    return history:latest(count or 50)
end

function hitch.worst()
    return worst
end

function hitch.consoleVolume(n)
    return {
        volume = util.topN(channelVolume, n or 10, function(item)
            return { resource = item.key, lines = item.value }
        end),
        errors = util.topN(scriptErrors, n or 10, function(item)
            return { resource = item.key, errors = item.value }
        end)
    }
end

function hitch.consoleCounts()
    local lines, errors = {}, {}
    for name, count in pairs(channelVolume) do lines[name] = count end
    for name, count in pairs(scriptErrors) do errors[name] = count end
    return lines, errors
end

function hitch.start()
    history = util.ring(Config.Hitch.historySize or 250)
    rawSamples = util.ring(1500)
    secondSamples = util.ring(3700)

    if not Config.Hitch.enabled then
        log.info('hitch', 'hitch detector disabled in config')
        return
    end

    local enabled = {}

    if Config.Hitch.sources.console then
        if caps.consoleListener then
            startConsoleSource()
            enabled[#enabled + 1] = 'console'
        else
            log.warn('hitch', 'RegisterConsoleListener is not available on this build; the engine hitch warnings cannot be read')
        end
    end

    if Config.Hitch.sources.timer then
        startTimerSource()
        enabled[#enabled + 1] = 'timer'
    end

    if Config.Hitch.sources.perf then
        caps.probePerf(function(available)
            if not available then return end
            util.loop('hitch', function()
                return Config.Hitch.perf.interval or 10000
            end, scrapePerf, 1000)
            log.info('hitch', 'metrics source active at %s', caps.perfUrl())
        end)
        enabled[#enabled + 1] = 'perf(pending)'
    end

    log.info('hitch', 'hitch detector active. sources: %s. Thresholds are UNCALIBRATED placeholders - the server main thread ticks every %dms, so anything at or below that is normal.',
        table.concat(enabled, ', '), Dehz.SERVER_FRAME_MS)
end

Dehz.hitch = hitch
