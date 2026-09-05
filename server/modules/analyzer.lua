local Dehz = Dehz
local log = Dehz.log
local util = Dehz.util
local caps = Dehz.caps

local analyzer = {}

local patterns = nil
local report = { resources = {}, unscannable = {}, generatedAt = 0, partial = false }
local running = false
local progress = { current = 0, total = 0, resource = nil }

local function cfg()
    return Config.Analyzer
end

local function ignoredResource(name)
    local list = cfg().ignoreResources or {}
    for i = 1, #list do
        if list[i] == name then return true end
    end
    return false
end

local function ignoredFinding(kind)
    local list = cfg().ignoreFindings or {}
    for i = 1, #list do
        if list[i] == kind then return true end
    end
    return false
end

local function ignoredPattern(id)
    local list = cfg().ignorePatterns or {}
    for i = 1, #list do
        if list[i] == id then return true end
    end
    return false
end

local function deprecatedList()
    local out = {}
    for i = 1, #patterns.deprecated do
        local entry = patterns.deprecated[i]
        if not ignoredPattern(entry.id) then out[#out + 1] = entry end
    end
    local extra = cfg().extraPatterns or {}
    for i = 1, #extra do
        local entry = extra[i]
        if entry.match and not ignoredPattern(entry.id or '') then out[#out + 1] = entry end
    end
    return out
end

local function globToPattern(glob)
    local escaped = glob:gsub('([%^%$%(%)%%%.%[%]%+%-])', '%%%1')
    escaped = escaped:gsub('%*%*/', '\1')
    escaped = escaped:gsub('%*%*', '\1')
    escaped = escaped:gsub('%*', '[^/]*')
    escaped = escaped:gsub('%?', '.')
    escaped = escaped:gsub('\1', '.*')
    return '^' .. escaped .. '$'
end

local function metadataList(resource, key)
    local out = {}
    local count = GetNumResourceMetadata(resource, key) or 0
    for i = 0, count - 1 do
        local value = GetResourceMetadata(resource, key, i)
        if value then out[#out + 1] = value end
    end
    return out
end

local function classifiers(resource)
    local map = {}
    for _, key in ipairs({ 'client_script', 'server_script', 'shared_script', 'client_scripts', 'server_scripts', 'shared_scripts' }) do
        local list = metadataList(resource, key)
        local side = key:match('^(%w+)')
        for i = 1, #list do
            map[#map + 1] = { side = side, pattern = globToPattern(list[i]) }
        end
    end
    return map
end

local function sideOf(map, relativePath)
    for i = 1, #map do
        if relativePath:match(map[i].pattern) then return map[i].side end
    end
    return 'unknown'
end

local function extensionOf(name)
    return name:match('(%.[%w]+)$')
end

local function readDirectory(path)
    if not caps.readdir then return nil end
    local ok, handle = pcall(io.readdir, path)
    if not ok or not handle then return nil end

    local names = {}
    local iterOk = pcall(function()
        for name in handle:lines() do
            names[#names + 1] = name
        end
    end)
    pcall(function() handle:close() end)

    if not iterOk then return nil end
    return names
end

local function fileSize(path)
    local ok, handle = pcall(io.open, path, 'rb')
    if not ok or not handle then return 0 end
    local size = 0
    pcall(function()
        size = handle:seek('end') or 0
    end)
    pcall(function() handle:close() end)
    return size
end

local walkBudget = 0

local function walk(root, relative, out, depth)
    if depth > 8 then return end

    walkBudget = walkBudget + 1
    if walkBudget >= 25 then
        walkBudget = 0
        Wait(0)
    end

    local names = readDirectory(root .. (relative == '' and '' or ('/' .. relative)))
    if not names then
        if relative ~= '' then
            out[#out + 1] = relative
        end
        return
    end

    if #names == 0 then return end

    for i = 1, #names do
        local name = names[i]
        local childRelative = (relative == '') and name or (relative .. '/' .. name)
        local lowered = name:lower()

        if not patterns.skipDirectories[lowered] or lowered == 'stream' then
            local ext = extensionOf(lowered)
            if ext then
                out[#out + 1] = childRelative
            else
                walk(root, childRelative, out, depth + 1)
            end
        end
    end
end

local function listFiles(resource, path)
    if not caps.readdir or not path or path == '' then return nil end
    local out = {}
    walk(path, '', out, 0)
    return out
end

local function manifestFallbackFiles(resource)
    local out = {}
    local seen = {}
    local unexpanded = 0

    for _, key in ipairs({ 'client_script', 'server_script', 'shared_script' }) do
        local list = metadataList(resource, key)
        for i = 1, #list do
            local entry = list[i]
            if entry:find('*', 1, true) then
                unexpanded = unexpanded + 1
            elseif not entry:find('@', 1, true) and not seen[entry] then
                seen[entry] = true
                out[#out + 1] = entry
            end
        end
    end

    return out, unexpanded
end

local function countKeyword(line, keyword)
    local count = 0
    local init = 1
    while true do
        local s, e = line:find(keyword, init, true)
        if not s then break end
        local before = s > 1 and line:sub(s - 1, s - 1) or ' '
        local after = line:sub(e + 1, e + 1)
        if not before:match('[%w_]') and not after:match('[%w_]') then
            count = count + 1
        end
        init = e + 1
    end
    return count
end

local function hasYield(line)
    for i = 1, #patterns.yieldTokens do
        if line:find(patterns.yieldTokens[i], 1, true) then return true end
    end
    return false
end

local function analyseLua(lines, relativePath, side, findings, stats, deprecated)
    local scanWindow = cfg().blockScanLines or 250
    local total = #lines
    local budget = 0

    for n = 1, total do
        local line = lines[n]

        budget = budget + 1
        if budget >= 400 then
            budget = 0
            Wait(0)
        end

        if line:find('Wait(0)', 1, true) or line:find('Wait( 0 )', 1, true) then
            stats.waitZero = stats.waitZero + 1
            if not ignoredFinding('wait_zero') then
                findings[#findings + 1] = {
                    kind = 'wait_zero', file = relativePath, line = n, side = side,
                    label = 'Wait(0) loop', heuristic = false
                }
            end
        end

        for i = 1, #patterns.threadTokens do
            if line:find(patterns.threadTokens[i], 1, true) then
                stats.threads = stats.threads + 1
                break
            end
        end

        local loopStart = line:find('while true do', 1, true) or line:find('while (true) do', 1, true)
        if loopStart then
            local depth = 1
            local yields = hasYield(line:sub(loopStart))
            local limit = math.min(total, n + scanWindow)

            for m = n + 1, limit do
                if yields then break end
                local inner = lines[m]
                if hasYield(inner) then yields = true; break end
                depth = depth + countKeyword(inner, 'do') + countKeyword(inner, 'then') + countKeyword(inner, 'function')
                depth = depth - countKeyword(inner, 'end')
                if depth <= 0 then break end
            end

            if not yields and not ignoredFinding('busy_wait') then
                stats.busyWait = stats.busyWait + 1
                findings[#findings + 1] = {
                    kind = 'busy_wait', file = relativePath, line = n, side = side,
                    label = 'loop with no yield in body', heuristic = true
                }
            end
        end

        if line:find('TriggerClientEvent', 1, true) and line:find('-1', 1, true) then
            if line:match(',%s*%-1%s*[,%)]') and not ignoredFinding('broadcast_event') then
                stats.broadcasts = stats.broadcasts + 1
                findings[#findings + 1] = {
                    kind = 'broadcast_event', file = relativePath, line = n, side = side,
                    label = 'event broadcast to all clients', heuristic = true
                }
            end
        end

        if (side == 'server' or side == 'shared') and line:find('RegisterNetEvent', 1, true) and line:find('function', 1, true) then
            local usesSource = false
            local limit = math.min(total, n + scanWindow)
            local depth = 1

            for m = n, limit do
                local inner = lines[m]
                if inner:find('source', 1, true) then usesSource = true; break end
                if m > n then
                    depth = depth + countKeyword(inner, 'function') - countKeyword(inner, 'end')
                    if depth <= 0 then break end
                end
            end

            if not usesSource and not ignoredFinding('netevent_no_source') then
                stats.unsafeEvents = stats.unsafeEvents + 1
                findings[#findings + 1] = {
                    kind = 'netevent_no_source', file = relativePath, line = n, side = side,
                    label = 'net event handler never references source', heuristic = true
                }
            end
        end

        if not ignoredFinding('deprecated_native') then
            for i = 1, #deprecated do
                local entry = deprecated[i]
                if line:find(entry.match, 1, true) then
                    stats.deprecated = stats.deprecated + 1
                    findings[#findings + 1] = {
                        kind = 'deprecated_native', file = relativePath, line = n, side = side,
                        label = entry.label or 'deprecated usage', patternId = entry.id, note = entry.note,
                        heuristic = false
                    }
                end
            end
        end
    end
end

local function splitLines(content)
    local lines = {}
    local start = 1
    local length = #content
    while start <= length do
        local finish = content:find('\n', start, true)
        if not finish then
            lines[#lines + 1] = content:sub(start)
            break
        end
        lines[#lines + 1] = content:sub(start, finish - 1)
        start = finish + 1
    end
    return lines
end

local function looksBinary(content)
    local sample = content:sub(1, 512)
    if sample:find('\0', 1, true) then return true end
    local printable = 0
    for i = 1, #sample do
        local byte = sample:byte(i)
        if byte == 9 or byte == 10 or byte == 13 or (byte >= 32 and byte < 127) then
            printable = printable + 1
        end
    end
    if #sample == 0 then return false end
    return (printable / #sample) < 0.85
end

local function manifestFindings(resource, findings, stats, isEscrowed)
    if ignoredFinding('manifest') then return end

    local version = (metadataList(resource, 'fx_version')[1] or ''):lower()
    if version == '' then
        findings[#findings + 1] = { kind = 'manifest', file = 'fxmanifest.lua', line = 0, label = 'no fx_version declared', heuristic = false }
        stats.manifest = stats.manifest + 1
    else
        local rank = patterns.manifestVersions[version]
        local latest = patterns.manifestVersions[patterns.latestManifestVersion]
        if rank and latest and rank < latest then
            findings[#findings + 1] = {
                kind = 'manifest', file = 'fxmanifest.lua', line = 0,
                label = ('fx_version is "%s"; current is "%s"'):format(version, patterns.latestManifestVersion),
                heuristic = false
            }
            stats.manifest = stats.manifest + 1
        end
    end

    if #metadataList(resource, 'game') == 0 and #metadataList(resource, 'games') == 0 then
        findings[#findings + 1] = { kind = 'manifest', file = 'fxmanifest.lua', line = 0, label = 'no game declared', heuristic = false }
        stats.manifest = stats.manifest + 1
    end

    if isEscrowed then
        findings[#findings + 1] = {
            kind = 'manifest', file = 'fxmanifest.lua', line = 0,
            label = 'escrow protected resource', heuristic = false,
            note = 'Encrypted resources cannot be analysed. This is not a fault in the resource.'
        }
    end
end

local function riskScore(stats)
    local w = cfg().weights or {}
    local score = 0
    score = score + stats.busyWait * (w.busy_wait or 30)
    score = score + stats.waitZero * (w.wait_zero or 1)
    score = score + stats.threads * (w.thread_count or 2)
    score = score + stats.broadcasts * (w.broadcast_event or 4)
    score = score + stats.unsafeEvents * (w.netevent_no_source or 8)
    score = score + stats.deprecated * (w.deprecated_native or 2)
    score = score + stats.manifest * (w.manifest or 3)
    score = score + math.floor(stats.streamBytes / 52428800) * (w.stream_weight or 1)
    return score
end

local function analyseResource(resource)
    local path = GetResourcePath(resource) or ''
    local state = GetResourceState(resource)

    local stats = {
        files = 0, lines = 0, waitZero = 0, threads = 0, busyWait = 0,
        broadcasts = 0, unsafeEvents = 0, deprecated = 0, manifest = 0,
        streamFiles = 0, streamBytes = 0, skippedFiles = 0, unreadable = 0
    }

    local findings = {}
    local deprecated = deprecatedList()
    local map = classifiers(resource)

    local escrowMarkers = metadataList(resource, 'escrow_ignore')
    local isEscrowed = #escrowMarkers > 0

    local files = listFiles(resource, path)
    local partial = false
    local unexpandedGlobs = 0

    if not files then
        files, unexpandedGlobs = manifestFallbackFiles(resource)
        stats.unexpandedGlobs = unexpandedGlobs
        partial = true
    else
        for i = 1, #files do
            if files[i]:lower() == '.fxap' then isEscrowed = true end
        end
    end

    local maxSize = cfg().maxFileSize or 524288
    local perTick = cfg().filesPerTick or 3
    local processed = 0

    for i = 1, #files do
        local relative = files[i]
        local lowered = relative:lower()
        local ext = extensionOf(lowered)

        if ext and patterns.streamExtensions[ext] then
            stats.streamFiles = stats.streamFiles + 1
            if path ~= '' then
                stats.streamBytes = stats.streamBytes + fileSize(path .. '/' .. relative)
            end
        elseif ext and patterns.scanExtensions[ext] then
            local content = LoadResourceFile(resource, relative)

            if type(content) ~= 'string' or content == '' then
                stats.unreadable = stats.unreadable + 1
            elseif #content > maxSize then
                stats.skippedFiles = stats.skippedFiles + 1
            elseif looksBinary(content) then
                stats.unreadable = stats.unreadable + 1
                isEscrowed = true
            else
                local lines = splitLines(content)
                stats.files = stats.files + 1
                stats.lines = stats.lines + #lines
                if ext == '.lua' then
                    analyseLua(lines, relative, sideOf(map, relative), findings, stats, deprecated)
                end
                lines = nil
            end

            content = nil
        end

        processed = processed + 1
        if processed >= perTick then
            processed = 0
            Wait(0)
        end
    end

    manifestFindings(resource, findings, stats, isEscrowed)

    if stats.files == 0 then
        local reason

        if isEscrowed then
            reason = 'escrow protected - source is encrypted and cannot be read'
        elseif partial and unexpandedGlobs > 0 then
            reason = ('no readable script files could be located - io.readdir is unavailable on this build and this resource declares its scripts with %d wildcard pattern(s) that cannot be expanded')
                :format(unexpandedGlobs)
        elseif stats.unreadable > 0 then
            reason = ('%d script files could not be read'):format(stats.unreadable)
        end

        if reason then
            return {
                name = resource,
                state = state,
                unscannable = true,
                escrowed = isEscrowed,
                reason = reason,
                streamFiles = stats.streamFiles,
                streamBytes = stats.streamBytes,
                findings = {},
                stats = stats
            }
        end
    end

    return {
        name = resource,
        state = state,
        unscannable = false,
        escrowed = isEscrowed,
        partial = partial,
        score = riskScore(stats),
        stats = stats,
        findings = findings,
        streamFiles = stats.streamFiles,
        streamBytes = stats.streamBytes
    }
end

function analyzer.run(actor)
    if running then return report end
    if not cfg().enabled then return report end

    running = true
    local started = GetGameTimer()

    local names = {}
    local count = GetNumResources() or 0
    for i = 0, count - 1 do
        local name = GetResourceByFindIndex(i)
        if name and name ~= '' and not ignoredResource(name) then
            local state = GetResourceState(name)
            if state ~= 'missing' and state ~= 'unknown' then
                names[#names + 1] = name
            end
        end
    end

    progress = { current = 0, total = #names, resource = nil }

    local results = {}
    local unscannable = {}
    local partial = false

    for i = 1, #names do
        progress.current = i
        progress.resource = names[i]

        local ok, result = pcall(analyseResource, names[i])
        if ok and result then
            if result.unscannable then
                unscannable[#unscannable + 1] = result
            else
                if result.partial then partial = true end
                results[#results + 1] = result
            end
        else
            log.warn('analyzer', 'failed to analyse resource "%s": %s', names[i], tostring(result))
        end

        Wait(0)
    end

    table.sort(results, function(a, b)
        if a.score == b.score then return a.name < b.name end
        return a.score > b.score
    end)

    table.sort(unscannable, function(a, b) return a.name < b.name end)

    local totalStream = 0
    for i = 1, #results do totalStream = totalStream + results[i].streamBytes end
    for i = 1, #unscannable do totalStream = totalStream + unscannable[i].streamBytes end

    report = {
        resources = results,
        unscannable = unscannable,
        generatedAt = os.time(),
        durationMs = GetGameTimer() - started,
        partial = partial,
        scanned = #results,
        streamMeasured = caps.readdir == true,
        totalStreamBytes = totalStream,
        estimateOnly = true,
        actor = actor or 'startup'
    }

    progress = { current = 0, total = 0, resource = nil }
    running = false

    log.info('analyzer', 'resource analysis complete: %d resources scanned, %d unscannable (escrow), %d total in %dms%s',
        #results, #unscannable, count, report.durationMs,
        caps.readdir and (', ' .. util.formatBytes(totalStream) .. ' of streamable assets') or '')

    if #results > 0 then
        local fields = {}
        for i = 1, math.min(#results, 5) do
            local r = results[i]
            fields[#fields + 1] = {
                name = ('%d. %s'):format(i, r.name),
                value = ('estimated risk `%d` - %d findings across %d files'):format(r.score, #r.findings, r.stats.files),
                inline = false
            }
        end
        Dehz.webhook.send('analyzer', {
            title = 'Resource analysis',
            description = 'Risk scores are ESTIMATED from static code patterns. They are not measured CPU time.',
            severity = 'info',
            fields = fields
        })
    end

    return report
end

function analyzer.report()
    return report
end

function analyzer.progress()
    return { running = running, current = progress.current, total = progress.total, resource = progress.resource }
end

function analyzer.start()
    patterns = Dehz.data.patterns

    if not cfg().enabled then
        log.info('analyzer', 'resource analyzer disabled in config')
        return
    end

    if not cfg().runAtStart then return end

    util.thread('analyzer', function()
        Wait(cfg().startDelay or 45000)
        analyzer.run('startup')
    end)
end

Dehz.analyzer = analyzer
