local Dehz = Dehz
local log = Dehz.log
local util = Dehz.util
local state = Dehz.state
local caps = Dehz.caps

local diagnose = {}

local function ago(ms)
    if not ms or ms == 0 then return 'never' end
    local delta = GetGameTimer() - ms
    if delta < 0 then return 'never' end
    return ('%.0fs ago'):format(delta / 1000)
end

local function agoEpoch(seconds)
    if not seconds or seconds == 0 then return 'never' end
    local delta = os.time() - seconds
    if delta < 0 then return 'just now' end
    return ('%ds ago'):format(delta)
end

local function pending(delayMs)
    local remaining = (delayMs or 0) - state.uptime()
    if remaining <= 0 then return nil end
    return ('%.0fs'):format(remaining / 1000)
end

local function listDirectory(relative)
    local root = GetResourcePath(GetCurrentResourceName())
    if not root or root == '' or not caps.readdir then return nil end

    local ok, handle = pcall(io.readdir, root .. '/' .. relative)
    if not ok or not handle then return nil end

    local names = {}
    pcall(function()
        for name in handle:lines() do
            if name:sub(1, 1) ~= '.' and name:lower() ~= 'readme.txt' then
                names[#names + 1] = name
            end
        end
    end)
    pcall(function() handle:close() end)

    return names
end

function diagnose.report()
    local out = {}
    local function line(fmt, ...)
        out[#out + 1] = select('#', ...) > 0 and fmt:format(...) or fmt
    end

    local resource = GetCurrentResourceName()

    line('')
    line('STATUS  %s v%s', resource, tostring(GetResourceMetadata(resource, 'version', 0)))
    line('  uptime            %.0fs', state.uptime() / 1000)
    line('  operating mode    %s%s', state.mode(),
        state.mode() == 'monitor' and '  (nothing is deleted or changed)' or '  (destructive modules may act)')
    line('  framework         %s', Dehz.bridge.name())
    line('  onesync           %s', caps.oneSync)
    line('  server entity list %s', caps.entityPool and 'available' or 'UNAVAILABLE - the entity modules cannot work')

    line('')
    line('MODULES')

    local scan = Dehz.entities.scanInfo()
    if not Config.Entities.enabled then
        line('  entities    disabled in config')
    elseif not scan.available then
        line('  entities    UNAVAILABLE - OneSync is "%s", so the server keeps no entity list', caps.oneSync)
    else
        local counts = Dehz.entities.counts()
        line('  entities    last scan %s, indexed %d  (vehicles %d / peds %d / objects %d)',
            ago(scan.lastScanAt), scan.indexed, counts.vehicles, counts.peds, counts.objects)
        if scan.indexed == 0 then
            line('              nothing indexed yet - the first scan runs 5s after start, then every %dms',
                Config.Entities.scanInterval or 15000)
        end
    end

    local sweeper = Dehz.sweeper.status()
    if not sweeper.enabled then
        line('  sweeper     disabled in config')
    else
        local wait = pending(Config.Sweeper.startupGrace)
        line('  sweeper     action=%s dryRun=%s  last sweep %s', sweeper.action, tostring(sweeper.dryRun), ago(sweeper.lastSweepAt))
        if wait then
            line('              first sweep in %s (startup grace period)', wait)
        end
        if sweeper.blocked then
            line('              last run skipped: %s', sweeper.blocked)
        end
        if sweeper.liveBlockedByPlates then
            line('              live action blocked: owned-vehicle plate lookup failed')
        end
    end

    local audit = Dehz.auditor.report()
    if not Config.Auditor.enabled then
        line('  auditor     disabled in config')
    elseif audit.lastRunAt == 0 then
        local wait = pending(Config.Auditor.startDelay)
        line('  auditor     not run yet%s', wait and (' - first run in ' .. wait) or '')
    else
        line('  auditor     %d findings (%d critical, %d warning), last run %s',
            audit.counts.total, audit.counts.critical, audit.counts.warning, ago(audit.lastRunAt))
    end

    local analysis = Dehz.analyzer.report()
    local progress = Dehz.analyzer.progress()
    if not Config.Analyzer.enabled then
        line('  analyzer    disabled in config')
    elseif progress.running then
        line('  analyzer    running: %d of %d (%s)', progress.current, progress.total, tostring(progress.resource))
    elseif analysis.generatedAt == 0 then
        local wait = pending(Config.Analyzer.startDelay)
        line('  analyzer    not run yet%s', wait and (' - first run in ' .. wait) or '')
    else
        line('  analyzer    %d resources ranked, %d unscannable, last run %s',
            analysis.scanned or 0, #(analysis.unscannable or {}), agoEpoch(analysis.generatedAt))
    end

    local hitchReport = Dehz.hitch.report()
    if not hitchReport.enabled then
        line('  hitch       disabled in config')
    else
        local sources = {}
        for name, on in pairs(hitchReport.sources) do
            if on then sources[#sources + 1] = name end
        end
        table.sort(sources)
        line('  hitch       sources: %s  |  %d minor, %d major, %d severe recorded',
            #sources > 0 and table.concat(sources, ', ') or 'NONE',
            hitchReport.counts.minor, hitchReport.counts.major, hitchReport.counts.severe)
    end

    local bags = Dehz.statebags.report()
    line('  statebags   %s  |  %.1f writes/s', bags.active and 'active' or 'inactive', bags.rate or 0)

    local net = Dehz.network.report()
    if not net.enabled then
        line('  network     disabled in config')
    else
        line('  network     %s  |  %d disconnects seen',
            net.latest and ('last sample ' .. agoEpoch(net.latest.at)) or 'no sample yet (first at 10s)',
            net.drops.total)
    end

    local prof = Dehz.profiler.status()
    line('  profiler    %s', prof.enabled and (prof.running and ('running: ' .. prof.stage) or 'enabled, idle') or 'disabled in config')

    line('')
    line('OUTPUT FILES')

    local reportDir = (Config.Reporting.export and Config.Reporting.export.directory) or 'reports'
    local reports = listDirectory(reportDir)
    if reports == nil then
        line('  %s/  cannot list (io.readdir unavailable on this build)', reportDir)
    elseif #reports == 0 then
        line('  %s/  empty - this is normal. A health report is written only when you press', reportDir)
        line('            "Export health report" in the dashboard, or call the exportHealthReport export.')
    else
        line('  %s/  %d file(s), newest: %s', reportDir, #reports, reports[#reports])
    end

    local profiles = listDirectory('data')
    if profiles == nil then
        line('  data/     cannot list (io.readdir unavailable on this build)')
    elseif #profiles == 0 then
        line('  data/     empty - normal. Written only when the profiler runs, and it is %s.',
            Config.Profiler.enabled and 'enabled but never run yet' or 'disabled in config')
    else
        line('  data/     %d file(s)', #profiles)
    end

    line('')
    line('DASHBOARD')
    line('  command           /%s', Config.Dashboard.command or 'serveropt')
    line('  enabled           %s', tostring(Config.Dashboard.enabled ~= false))
    line('  access            ACE "%s"%s', Config.Permissions.ace,
        Config.Permissions.allowCommandAce and ' or the built-in "command" ACE' or '')
    line('  IMPORTANT         a player without that ACE gets NO response at all - no error, no')
    line('                    message. If the command seems to do nothing, this is the first')
    line('                    thing to check:  add_ace group.admin %s allow', Config.Permissions.ace)
    line('')

    return out
end

function diagnose.start()
    RegisterCommand('dehz_status', function(source)
        if source ~= 0 and not Dehz.bridge.isAdmin(source) then return end

        local lines = diagnose.report()

        if source == 0 then
            log.banner(lines)
        else
            for i = 1, #lines do
                TriggerClientEvent('chat:addMessage', source, { color = { 200, 16, 46 }, multiline = true, args = { 'Optimizer', lines[i] } })
            end
        end
    end, false)

    RegisterCommand('dehz_export', function(source)
        if source ~= 0 and not Dehz.bridge.isAdmin(source) then return end

        local actor = source == 0 and 'server console' or Dehz.bridge.getPlayerLabel(source)

        util.thread('diagnose', function()
            local written, err = Dehz.export.write(actor)
            if written then
                log.banner({
                    '',
                    'health report written:',
                    '  ' .. written.text,
                    '  ' .. written.json,
                    ''
                })
            else
                log.warn('diagnose', 'export failed: %s', tostring(err))
            end
        end)
    end, false)

    log.info('diagnose', 'console commands: "dehz_status" for a full status and troubleshooting report, "dehz_export" to write a health report now')
end

Dehz.diagnose = diagnose
