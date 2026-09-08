local Dehz = Dehz
local log = Dehz.log
local util = Dehz.util
local caps = Dehz.caps

local auditor = {}

local SENTINEL = '\1dehz-convar-absent\1'

local findings = {}
local advisories = {}
local missing = {}
local lastRunAt = 0
local applied = {}
local pendingRerun = false
local lastFingerprint = nil
local lastRerunAt = 0

local function readConvar(key)
    local value = GetConvar(key, SENTINEL)
    if value == SENTINEL then return nil end
    return value
end

local function normaliseBool(value)
    if value == nil then return nil end
    local lowered = tostring(value):lower()
    if lowered == 'true' or lowered == '1' or lowered == 'yes' then return 'true' end
    if lowered == 'false' or lowered == '0' or lowered == 'no' then return 'false' end
    return lowered
end

local function normalise(entry, value)
    if entry.kind == 'bool' then return normaliseBool(value) end
    if entry.kind == 'int' then
        local n = tonumber(value)
        return n and tostring(math.floor(n)) or tostring(value)
    end
    if entry.kind == 'enum' then return tostring(value):lower() end
    return tostring(value)
end

local function recommendedFor(entry)
    local override = Config.Auditor.recommended and Config.Auditor.recommended[entry.key]
    if override ~= nil then return normalise(entry, override) end
    if entry.recommended == nil then return nil end
    return normalise(entry, entry.recommended)
end

local function cfgLine(entry, value)
    return ('%s %s %s'):format(entry.verb or 'set', entry.key, value)
end

local function suppressed(key)
    local list = Config.Auditor.suppress or {}
    for i = 1, #list do
        if list[i] == key then return true end
    end
    return false
end

local function severityFor(entry, current, context)
    if entry.scaleWithPlayers and context.maxClients and context.maxClients > entry.scaleWithPlayers then
        return 'warning'
    end
    return entry.severity or 'info'
end

local function evaluate(entry, context)
    local raw = readConvar(entry.key)

    if raw == nil then
        missing[#missing + 1] = entry.key
        return nil
    end

    local current = normalise(entry, raw)

    if entry.deprecated then
        if current == 'true' then
            return {
                key = entry.key,
                severity = entry.severity or 'info',
                current = current,
                recommended = 'remove the line',
                line = ('# remove: %s %s'):format(entry.verb or 'set', entry.key),
                impact = entry.impact,
                runtimeSettable = entry.runtimeSettable == true,
                deprecated = true
            }
        end
        return nil
    end

    if entry.maxClientsCheck then
        local slots = tonumber(current) or 0
        context.maxClients = slots
        local oneSync = context.oneSync
        if slots > 32 and oneSync ~= 'on' then
            return {
                key = entry.key,
                severity = 'critical',
                current = current,
                recommended = 'onesync on',
                line = 'set onesync on',
                impact = ('%d slots are configured but OneSync is "%s". Above 32 players you must be on OneSync Infinity.'):format(slots, tostring(oneSync)),
                runtimeSettable = false
            }
        end
        advisories[#advisories + 1] = {
            key = entry.key,
            current = current,
            impact = entry.impact,
            runtimeSettable = false
        }
        return nil
    end

    if entry.emptyIsGood then
        if current ~= '' then
            return {
                key = entry.key,
                severity = entry.severity or 'warning',
                current = current,
                recommended = '(empty)',
                line = cfgLine(entry, '""'),
                impact = entry.impact,
                runtimeSettable = entry.runtimeSettable == true
            }
        end
        return nil
    end

    if entry.advisory then
        advisories[#advisories + 1] = {
            key = entry.key,
            current = current,
            impact = entry.impact,
            runtimeSettable = entry.runtimeSettable == true
        }
        return nil
    end

    local recommended = recommendedFor(entry)
    if recommended == nil then return nil end

    if current == recommended then return nil end

    return {
        key = entry.key,
        severity = severityFor(entry, current, context),
        current = current,
        recommended = recommended,
        line = cfgLine(entry, recommended),
        impact = entry.impact,
        runtimeSettable = entry.runtimeSettable == true
    }
end

local function autoApply(finding)
    if not Config.Auditor.allowAutoApply then return false end
    if not finding.runtimeSettable then return false end
    if finding.deprecated then return false end

    local ok = pcall(SetConvar, finding.key, finding.recommended)
    if ok then
        applied[#applied + 1] = { key = finding.key, value = finding.recommended, at = os.time() }
        log.warn('auditor', 'auto-applied %s = %s (Config.Auditor.allowAutoApply is true). This is a runtime change only - it will not survive a restart unless you also add "%s" to server.cfg.',
            finding.key, finding.recommended, finding.line)
        return true
    end
    return false
end

function auditor.run(actor)
    findings = {}
    advisories = {}
    missing = {}

    local context = {
        oneSync = tostring(GetConvar('onesync', 'off')):lower(),
        maxClients = tonumber(GetConvar('sv_maxClients', GetConvar('sv_maxclients', '30'))) or 30
    }

    local entries = Dehz.data.convars

    for i = 1, #entries do
        local entry = entries[i]
        if not suppressed(entry.key) then
            local ok, finding = pcall(evaluate, entry, context)
            if ok and finding then
                findings[#findings + 1] = finding
                autoApply(finding)
            elseif not ok then
                log.warn('auditor', 'failed to evaluate convar "%s": %s', entry.key, tostring(finding))
            end
        end
    end

    table.sort(findings, function(a, b)
        local sa = Dehz.SEVERITY[a.severity] or 0
        local sb = Dehz.SEVERITY[b.severity] or 0
        if sa == sb then return a.key < b.key end
        return sa > sb
    end)

    lastRunAt = GetGameTimer()

    local critical, warning = 0, 0
    for i = 1, #findings do
        if findings[i].severity == 'critical' then critical = critical + 1
        elseif findings[i].severity == 'warning' then warning = warning + 1 end
    end

    local fingerprint = {}
    for i = 1, #findings do
        fingerprint[#fingerprint + 1] = findings[i].key .. '=' .. tostring(findings[i].current)
    end
    fingerprint = table.concat(fingerprint, ';')

    local changed = fingerprint ~= lastFingerprint
    lastFingerprint = fingerprint

    if changed then
        log.info('auditor', 'config audit: %d critical, %d warning, %d total findings (%d convars not present on this build were skipped)',
            critical, warning, #findings, #missing)
    else
        log.debug('auditor', 'config audit re-ran, findings unchanged')
    end

    if critical > 0 and changed then
        local fields = {}
        for i = 1, math.min(#findings, 8) do
            local f = findings[i]
            fields[#fields + 1] = {
                name = ('[%s] %s'):format(f.severity, f.key),
                value = ('current `%s` -> recommended `%s`\n%s'):format(f.current, f.recommended, f.impact or ''),
                inline = false
            }
        end
        Dehz.webhook.send('auditor', {
            title = 'Server configuration audit',
            description = ('%d critical and %d warning findings.'):format(critical, warning),
            severity = 'critical',
            fields = fields
        })
    end

    return auditor.report(actor)
end

function auditor.report()
    local critical, warning, info = 0, 0, 0
    for i = 1, #findings do
        local s = findings[i].severity
        if s == 'critical' then critical = critical + 1
        elseif s == 'warning' then warning = warning + 1
        else info = info + 1 end
    end

    return {
        findings = findings,
        advisories = advisories,
        missing = missing,
        counts = { critical = critical, warning = warning, info = info, total = #findings },
        lastRunAt = lastRunAt,
        autoApplyEnabled = Config.Auditor.allowAutoApply == true,
        applied = applied
    }
end

function auditor.score()
    local report = auditor.report()
    local penalty = report.counts.critical * 18 + report.counts.warning * 7 + report.counts.info * 1
    return util.clamp(100 - penalty, 0, 100)
end

function auditor.start()
    if not Config.Auditor.enabled then
        log.info('auditor', 'config auditor disabled in config')
        return
    end

    Dehz.util.thread('auditor', function()
        Wait(Config.Auditor.startDelay or 20000)
        if Config.Auditor.runAtStart then
            auditor.run('startup')
        end
    end)

    if Config.Auditor.reactToConvarChanges and caps.convarListener then
        local entries = Dehz.data.convars
        local registered = 0

        local function onChange()
            if pendingRerun then return end

            local minGap = Config.Auditor.minRerunInterval or 60000
            local since = GetGameTimer() - lastRerunAt
            local delay = math.max(5000, minGap - since)

            pendingRerun = true
            SetTimeout(delay, function()
                lastRerunAt = GetGameTimer()
                pendingRerun = false
                util.guard('auditor', auditor.run, 'convar-change')
            end)
        end

        for i = 1, #entries do
            local ok = pcall(AddConvarChangeListener, entries[i].key, onChange)
            if ok then registered = registered + 1 end
        end

        log.debug('auditor', 'listening for changes on %d audited convars (a change elsewhere on the server is ignored)', registered)
    elseif Config.Auditor.reactToConvarChanges then
        log.debug('auditor', 'AddConvarChangeListener is not available on this build; audit runs at start and on demand only')
    end
end

Dehz.auditor = auditor
