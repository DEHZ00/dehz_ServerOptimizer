local Dehz = Dehz
local log = Dehz.log
local util = Dehz.util
local state = Dehz.state

local profiler = {}

local running = false
local lastRunAt = 0
local lastResult = nil
local lastError = nil
local stage = 'idle'

local function acePrincipal()
    return 'resource.' .. GetCurrentResourceName()
end

local REQUIRED_COMMANDS = { 'profiler', 'record', 'saveJSON' }

local function missingAces()
    if type(IsPrincipalAceAllowed) ~= 'function' then return {} end

    local principal = acePrincipal()
    local missing = {}

    for i = 1, #REQUIRED_COMMANDS do
        local object = 'command.' .. REQUIRED_COMMANDS[i]
        local ok, allowed = pcall(IsPrincipalAceAllowed, principal, object)
        if ok and allowed ~= true then
            missing[#missing + 1] = object
        end
    end

    return missing
end

local function aceLines()
    local principal = acePrincipal()
    local lines = {}
    for i = 1, #REQUIRED_COMMANDS do
        lines[#lines + 1] = ('add_ace %s command.%s allow'):format(principal, REQUIRED_COMMANDS[i])
    end
    return lines
end

local function aceLine()
    return table.concat(aceLines(), '  |  ')
end

local function hasProfilerAce()
    return #missingAces() == 0
end

local function outputPath()
    local root = GetResourcePath(GetCurrentResourceName())
    if not root or root == '' then return nil end
    return root .. '/' .. (Config.Profiler.outputFile or 'data/profile.json')
end

local function canRun()
    if not Config.Profiler.enabled then return false, 'profiler is disabled in config' end
    if running then return false, 'a profile is already running' end

    local cooldown = Config.Profiler.cooldown or 300000
    if lastRunAt > 0 and (GetGameTimer() - lastRunAt) < cooldown then
        return false, ('cooldown active, %.0fs remaining'):format((cooldown - (GetGameTimer() - lastRunAt)) / 1000)
    end

    local maxPlayers = Config.Profiler.maxPlayersOnline or 0
    if maxPlayers > 0 then
        local online = #GetPlayers()
        if online > maxPlayers then
            return false, ('%d players online, limit is %d'):format(online, maxPlayers)
        end
    end

    if state.sweepRunning then return false, 'an entity sweep is running' end

    if not outputPath() then return false, 'could not resolve this resource path' end

    local missing = missingAces()
    if #missing > 0 then
        return false, ('the server denies this resource %d console command(s) it needs (%s). Add these to server.cfg and restart:  %s')
            :format(#missing, table.concat(missing, ', '), aceLine())
    end

    return true
end

local function readRecording(path)
    local ok, handle = pcall(io.open, path, 'r')
    if not ok or not handle then return nil, 'could not open the recording file' end

    local size = 0
    pcall(function() size = handle:seek('end') or 0 end)

    local limit = Config.Profiler.maxFileBytes or 25165824
    if size > limit then
        pcall(function() handle:close() end)
        return nil, ('recording is %s, above the %s limit - record fewer frames')
            :format(util.formatBytes(size), util.formatBytes(limit))
    end

    if size == 0 then
        pcall(function() handle:close() end)
        return nil, 'recording file is empty'
    end

    pcall(function() handle:seek('set', 0) end)

    local content
    local readOk = pcall(function() content = handle:read('a') end)
    pcall(function() handle:close() end)

    if not readOk or type(content) ~= 'string' or content == '' then
        return nil, 'could not read the recording file'
    end

    return content, nil, size
end

local function aggregate(traceEvents)
    local stacks = {}
    local perResource = {}
    local perCause = {}
    local firstTs, lastTs = nil, nil
    local unpaired = 0

    local chunk = Config.Profiler.parseChunk or 500
    local processed = 0

    for i = 1, #traceEvents do
        local event = traceEvents[i]
        local ph = event.ph

        if ph == 'B' or ph == 'E' then
            local tid = event.tid or 0
            local ts = tonumber(event.ts) or 0

            if not firstTs or ts < firstTs then firstTs = ts end
            if not lastTs or ts > lastTs then lastTs = ts end

            stacks[tid] = stacks[tid] or {}
            local stack = stacks[tid]

            if ph == 'B' then
                stack[#stack + 1] = { name = event.name, ts = ts }
            else
                local top = stack[#stack]
                if top then
                    stack[#stack] = nil
                    local duration = ts - top.ts
                    if duration >= 0 then
                        local cause, resource = tostring(top.name):match('^(.-) %((.+)%)$')
                        if resource then
                            local bucket = perResource[resource]
                            if not bucket then
                                bucket = { resource = resource, micros = 0, calls = 0, ticks = 0, events = 0 }
                                perResource[resource] = bucket
                            end
                            bucket.micros = bucket.micros + duration
                            bucket.calls = bucket.calls + 1
                            if cause == 'tick' then
                                bucket.ticks = bucket.ticks + 1
                            else
                                bucket.events = bucket.events + 1
                                local eventName = cause:match('^event:(.+)$') or cause
                                perCause[eventName] = (perCause[eventName] or 0) + duration
                            end
                        end
                    end
                else
                    unpaired = unpaired + 1
                end
            end
        end

        processed = processed + 1
        if processed >= chunk then
            processed = 0
            Wait(0)
        end
    end

    local list = {}
    for _, bucket in pairs(perResource) do
        list[#list + 1] = bucket
    end

    table.sort(list, function(a, b) return a.micros > b.micros end)

    local wallMicros = (firstTs and lastTs) and (lastTs - firstTs) or 0

    for i = 1, #list do
        local bucket = list[i]
        bucket.ms = util.round(bucket.micros / 1000, 3)
        bucket.msPerCall = bucket.calls > 0 and util.round((bucket.micros / bucket.calls) / 1000, 4) or 0
        bucket.share = wallMicros > 0 and util.round((bucket.micros / wallMicros) * 100, 2) or 0
    end

    local events = util.topN(perCause, 15, function(item)
        return { event = item.key, ms = util.round(item.value / 1000, 3) }
    end)

    return {
        resources = list,
        events = events,
        wallMs = util.round(wallMicros / 1000, 1),
        unpaired = unpaired,
        measured = true
    }
end

local function execute(frames, actor)
    local path = outputPath()
    stage = 'recording'

    log.warn('profiler', 'starting a %d frame profiler recording requested by %s. The server does extra work for every resource tick while this runs.', frames, actor or 'unknown')

    ExecuteCommand(('profiler record %d'):format(frames))

    local recordWaitMs = (frames * Dehz.SERVER_FRAME_MS) + 3000
    Wait(recordWaitMs)

    stage = 'saving'
    ExecuteCommand(('profiler saveJSON "%s"'):format(path))
    Wait(3000)

    stage = 'reading'
    local content, err, size = readRecording(path)
    if not content then
        local stillMissing = missingAces()
        if #stillMissing > 0 then
            err = ('the server denied this resource %s, so nothing was recorded. Add these to server.cfg and restart:  %s')
                :format(table.concat(stillMissing, ' and '), aceLine())
        elseif err == 'could not open the recording file' then
            err = ('no recording file was produced at %s. The most common cause is the server denying this resource the "profiler" console command - look for "Access denied for command profiler" above. Fix with:  %s')
                :format(path, aceLine())
        end
        lastError = err
        log.warn('profiler', 'profile failed: %s', tostring(err))
        return nil
    end

    stage = 'decoding'
    local decodeStart = GetGameTimer()
    local ok, decoded = pcall(json.decode, content)
    local decodeMs = GetGameTimer() - decodeStart
    content = nil

    if not ok or type(decoded) ~= 'table' or type(decoded.traceEvents) ~= 'table' then
        lastError = 'the recording could not be decoded'
        log.warn('profiler', 'profile failed: the recording could not be decoded')
        return nil
    end

    stage = 'aggregating'
    local result = aggregate(decoded.traceEvents)
    decoded = nil

    result.frames = frames
    result.at = os.time()
    result.actor = actor
    result.fileBytes = size
    result.decodeMs = decodeMs
    result.eventCount = nil

    log.info('profiler', 'profile complete: %d frames, %s recording, JSON decode took %dms, %d resources measured over %.1fms of server time',
        frames, util.formatBytes(size), decodeMs, #result.resources, result.wallMs)

    if decodeMs > 120 then
        log.warn('profiler', 'decoding the recording took %dms and will have shown up as a hitch. Record fewer frames next time.', decodeMs)
    end

    return result
end

function profiler.run(frames, actor, onDone)
    local allowed, reason = canRun()
    if not allowed then
        lastError = reason
        return false, reason
    end

    frames = tonumber(frames) or Config.Profiler.defaultFrames or 60
    local maxFrames = Config.Profiler.maxFrames or 200
    if frames < 10 then frames = 10 end
    if frames > maxFrames then frames = maxFrames end

    running = true
    lastError = nil
    lastRunAt = GetGameTimer()

    util.thread('profiler', function()
        local result = execute(frames, actor)
        if result then
            lastResult = result
        end
        stage = 'idle'
        running = false

        if not result then
            local retryIn = 15000
            local cooldown = Config.Profiler.cooldown or 300000
            if cooldown > retryIn then
                lastRunAt = GetGameTimer() - (cooldown - retryIn)
            end
        end

        if onDone then
            util.guard('profiler', onDone, result, lastError)
        end
    end)

    return true, ('recording %d frames'):format(frames)
end

function profiler.aceStatus()
    return { granted = hasProfilerAce(), principal = acePrincipal(), line = aceLine() }
end

function profiler.status()
    return {
        enabled = Config.Profiler.enabled == true,
        aceGranted = hasProfilerAce(),
        aceMissing = missingAces(),
        aceLines = aceLines(),
        running = running,
        stage = stage,
        lastRunAt = lastRunAt,
        lastError = lastError,
        cooldown = Config.Profiler.cooldown,
        maxFrames = Config.Profiler.maxFrames,
        defaultFrames = Config.Profiler.defaultFrames
    }
end

function profiler.report()
    return lastResult
end

function profiler.start()
    if not Config.Profiler.enabled then return end

    log.warn('profiler', 'the optional profiler module is ENABLED. It is never automatic - it only runs when an admin asks for it - but while it records, the server does extra work for every resource tick and event.')

    local missing = missingAces()
    if #missing > 0 then
        log.error('profiler', 'the profiler cannot run: this server denies the resource %d console command(s) it needs. Add these lines to server.cfg and restart, or every run will fail:', #missing)
        local lines = aceLines()
        for i = 1, #lines do
            log.error('profiler', '    %s', lines[i])
        end
    end
end

Dehz.profiler = profiler
