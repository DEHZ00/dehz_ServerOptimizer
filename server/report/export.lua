local Dehz = Dehz
local log = Dehz.log
local util = Dehz.util
local state = Dehz.state
local caps = Dehz.caps

local health = {}
local export = {}

local function hitchesInWindow(windowMs)
    local list = Dehz.hitch.history(500)
    local now = GetGameTimer()
    local severe, major, minor = 0, 0, 0

    for i = 1, #list do
        local entry = list[i]
        if now - entry.ms <= windowMs then
            if entry.severity == 'severe' then severe = severe + 1
            elseif entry.severity == 'major' then major = major + 1
            else minor = minor + 1 end
        end
    end

    return severe, major, minor
end

function health.components()
    local audit = Dehz.auditor.score()

    local severe, major = hitchesInWindow(3600000)
    local hitchScore = util.clamp(100 - (severe * 20 + major * 5), 0, 100)

    local ratio = Dehz.entities.ratio()
    local entityScore = util.clamp(100 - math.floor(util.clamp((ratio - 40) * 2, 0, 100)), 0, 100)

    local report = Dehz.analyzer.report()
    local topRisk = (report.resources and report.resources[1] and report.resources[1].score) or 0
    local resourceScore = util.clamp(100 - math.floor(topRisk / 4), 0, 100)

    return {
        audit = audit,
        hitches = hitchScore,
        entities = entityScore,
        resources = resourceScore,
        ratio = ratio,
        severeLastHour = severe,
        majorLastHour = major,
        topRisk = topRisk
    }
end

function health.score()
    local c = health.components()
    local overall = (c.audit * 0.30) + (c.hitches * 0.30) + (c.entities * 0.20) + (c.resources * 0.20)
    return math.floor(overall + 0.5), c
end

local function buildReport()
    local score, components = health.score()
    local audit = Dehz.auditor.report()
    local analysis = Dehz.analyzer.report()
    local hitchReport = Dehz.hitch.report()
    local sweeperStatus = Dehz.sweeper.status()

    local topResources = {}
    for i = 1, math.min(#(analysis.resources or {}), 15) do
        local r = analysis.resources[i]
        topResources[i] = {
            name = r.name,
            estimatedRiskScore = r.score,
            findings = #r.findings,
            files = r.stats.files,
            lines = r.stats.lines,
            busyWaitLoops = r.stats.busyWait,
            waitZeroLoops = r.stats.waitZero,
            broadcastEvents = r.stats.broadcasts,
            netEventsWithoutSource = r.stats.unsafeEvents,
            streamBytes = r.streamBytes,
            partial = r.partial
        }
    end

    local unscannable = {}
    for i = 1, #(analysis.unscannable or {}) do
        unscannable[i] = { name = analysis.unscannable[i].name, reason = analysis.unscannable[i].reason }
    end

    return {
        generatedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        resource = 'Dehz_ServerOptimizer',
        version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0),
        server = {
            version = caps.serverVersion,
            oneSync = caps.oneSync,
            gameBuild = GetConvar('sv_enforceGameBuild', 'unknown'),
            maxClients = GetConvar('sv_maxClients', GetConvar('sv_maxclients', 'unknown')),
            uptimeMs = state.uptime(),
            hostname = GetConvar('sv_hostname', 'unknown')
        },
        mode = state.mode(),
        framework = Dehz.bridge.name(),
        capabilities = caps.summary(),
        health = { score = score, components = components },
        entities = Dehz.entities.snapshot(),
        entityScan = Dehz.entities.scanInfo(),
        topModels = {
            vehicles = Dehz.entities.topModels('vehicles', 10),
            peds = Dehz.entities.topModels('peds', 10),
            objects = Dehz.entities.topModels('objects', 10)
        },
        topCreatingResources = Dehz.entities.topScripts(10),
        sweeper = sweeperStatus,
        sweepHistory = Dehz.sweeper.history(10),
        configAudit = {
            counts = audit.counts,
            findings = audit.findings,
            advisories = audit.advisories,
            convarsNotPresentOnThisBuild = audit.missing
        },
        resourceAnalysis = {
            note = 'Risk scores are ESTIMATED from static code patterns. They are not measured CPU time. Nothing on a FiveM server exposes live per-resource CPU cost.',
            streamMeasured = analysis.streamMeasured,
            totalStreamBytes = analysis.totalStreamBytes,
            ranked = topResources,
            unscannable = unscannable
        },
        hitches = {
            note = 'The server main thread ticks every 50ms, so a gap at or below that is normal. Thresholds ship uncalibrated.',
            sources = hitchReport.sources,
            counts = hitchReport.counts,
            byThread = hitchReport.byThread,
            windows = hitchReport.windows,
            perf = hitchReport.perf,
            worst = Dehz.hitch.worst()
        },
        stateBags = Dehz.statebags.report(),
        network = Dehz.network.report(),
        profiler = Dehz.profiler.report(),
        consoleActivity = Dehz.hitch.consoleVolume(10)
    }
end

local function toText(report)
    local out = {}
    local function line(fmt, ...)
        out[#out + 1] = select('#', ...) > 0 and fmt:format(...) or fmt
    end

    line('DEHZ SERVER OPTIMIZER - HEALTH REPORT')
    line('generated %s', report.generatedAt)
    line('')
    line('SERVER')
    line('  build          %s', tostring(report.server.gameBuild))
    line('  fxserver       %s', tostring(report.server.version))
    line('  onesync        %s', tostring(report.server.oneSync))
    line('  slots          %s', tostring(report.server.maxClients))
    line('  uptime         %.1f hours', report.server.uptimeMs / 3600000)
    line('  framework      %s', report.framework)
    line('  operating mode %s', report.mode)
    line('')
    line('HEALTH SCORE     %d / 100', report.health.score)
    line('  config audit   %d', report.health.components.audit)
    line('  hitches        %d', report.health.components.hitches)
    line('  entity load    %d', report.health.components.entities)
    line('  resources      %d', report.health.components.resources)
    line('')
    line('ENTITIES')
    line('  vehicles %d   peds %d   objects %d   total %d',
        report.entities.vehicles, report.entities.peds, report.entities.objects, report.entities.total)
    line('  players %d   entities per player %.1f', report.entities.players, report.entities.ratio)
    line('')

    if #report.topCreatingResources > 0 then
        line('ENTITIES BY CREATING RESOURCE')
        for i = 1, #report.topCreatingResources do
            local item = report.topCreatingResources[i]
            line('  %-40s %d', item.resource, item.count)
        end
        line('')
    end

    line('CONFIG AUDIT  (%d critical, %d warning, %d info)',
        report.configAudit.counts.critical, report.configAudit.counts.warning, report.configAudit.counts.info)
    for i = 1, #report.configAudit.findings do
        local f = report.configAudit.findings[i]
        line('  [%-8s] %s', f.severity, f.key)
        line('             current: %s   recommended: %s', tostring(f.current), tostring(f.recommended))
        line('             %s', tostring(f.impact))
        line('             server.cfg: %s', tostring(f.line))
        if not f.runtimeSettable then
            line('             (cannot be changed while the server is running)')
        end
    end
    if #report.configAudit.convarsNotPresentOnThisBuild > 0 then
        line('  skipped (not present on this build): %s',
            table.concat(report.configAudit.convarsNotPresentOnThisBuild, ', '))
    end
    line('')

    line('RESOURCE ANALYSIS')
    line('  %s', report.resourceAnalysis.note)
    for i = 1, #report.resourceAnalysis.ranked do
        local r = report.resourceAnalysis.ranked[i]
        line('  %2d. %-32s risk %-5d %d findings  %d files  %d lines%s',
            i, r.name, r.estimatedRiskScore, r.findings, r.files, r.lines,
            r.partial and '  (manifest-only scan)' or '')
    end
    if #report.resourceAnalysis.unscannable > 0 then
        line('  unscannable (escrow protected):')
        for i = 1, #report.resourceAnalysis.unscannable do
            line('    %s', report.resourceAnalysis.unscannable[i].name)
        end
    end
    line('')

    line('HITCHES')
    line('  %s', report.hitches.note)
    line('  minor %d   major %d   severe %d',
        report.hitches.counts.minor, report.hitches.counts.major, report.hitches.counts.severe)
    for name, stats in pairs(report.hitches.windows) do
        line('  %-4s p50 %.0fms  p95 %.0fms  p99 %.0fms  (%d samples%s)',
            name, stats.p50, stats.p95, stats.p99, stats.count, stats.approximate and ', approximate' or '')
    end
    line('')

    line('STATE BAGS')
    line('  %s', report.stateBags.note)
    line('  current rate %.1f writes/second', report.stateBags.rate or 0)
    for i = 1, #(report.stateBags.flagged or {}) do
        local f = report.stateBags.flagged[i]
        line('  over threshold: %-32s %.1f writes/s', f.key, f.rate)
    end
    line('')

    line('NETWORK')
    if report.network.latest then
        line('  players %d   avg ping %s ms   avg packet loss %s%%',
            report.network.latest.players,
            tostring(report.network.latest.avgPing or 'n/a'),
            tostring(report.network.latest.avgPacketLoss or 'n/a'))
    end
    line('  disconnects %d', report.network.drops.total)
    for i = 1, #report.network.drops.byCategory do
        local d = report.network.drops.byCategory[i]
        line('    %-16s %d', d.category, d.count)
    end
    line('')

    line('CAPABILITIES ON THIS BUILD')
    for key, value in pairs(report.capabilities) do
        line('  %-20s %s', key, tostring(value))
    end

    return table.concat(out, '\n')
end

function export.build()
    return buildReport()
end

function export.write(actor)
    local report = buildReport()
    report.requestedBy = actor

    local directory = (Config.Reporting.export and Config.Reporting.export.directory) or 'reports'
    local stamp = os.date('%Y%m%d-%H%M%S')
    local jsonName = ('%s/health-%s.json'):format(directory, stamp)
    local textName = ('%s/health-%s.txt'):format(directory, stamp)

    local resource = GetCurrentResourceName()

    local encoded = json.encode(report)
    local text = toText(report)

    local jsonOk = SaveResourceFile(resource, jsonName, encoded, #encoded)
    local textOk = SaveResourceFile(resource, textName, text, #text)

    if not jsonOk or not textOk then
        log.warn('export', 'could not write the health report to %s/%s. Check the resource folder is writable.', resource, directory)
        return nil, 'could not write the report files'
    end

    log.info('export', 'health report written to %s/%s and %s (requested by %s)', resource, jsonName, textName, actor or 'unknown')

    return { json = jsonName, text = textName, report = report, textBody = text }
end

Dehz.health = health
Dehz.export = export
