local Dehz = Dehz
local log = Dehz.log
local util = Dehz.util

local statebags = {}

local windowCounts = {}
local totalCounts = {}
local bagCounts = {}
local windowStartedAt = 0
local windowTotal = 0
local currentRate = 0
local flagged = {}
local active = false
local handlerCookie = nil
local lastReportAt = 0

local function windowMs()
    return Config.StateBags.window or 10000
end

local function rollWindow(now)
    local elapsed = now - windowStartedAt
    if elapsed < windowMs() then return end

    local seconds = elapsed / 1000
    currentRate = windowTotal / seconds

    local threshold = Config.StateBags.threshold or 20
    local newFlagged = {}

    for key, count in pairs(windowCounts) do
        local rate = count / seconds
        if rate >= threshold then
            newFlagged[#newFlagged + 1] = {
                key = key,
                rate = util.round(rate, 1),
                count = count,
                seconds = util.round(seconds, 1)
            }
        end
    end

    table.sort(newFlagged, function(a, b) return a.rate > b.rate end)
    flagged = newFlagged

    if #flagged > 0 then
        local interval = Config.StateBags.reportInterval or 0
        if interval > 0 and (now - lastReportAt) >= interval then
            lastReportAt = now
            local top = flagged[1]
            log.warn('statebags', 'state bag key "%s" is being written %.1f times per second (%d writes in %.1fs). This module reports spam, it cannot throttle it - the FiveM change handler has no way to reject a write.',
                top.key, top.rate, top.count, top.seconds)

            local fields = {}
            for i = 1, math.min(#flagged, 6) do
                fields[#fields + 1] = {
                    name = flagged[i].key,
                    value = ('`%.1f` writes/s'):format(flagged[i].rate),
                    inline = true
                }
            end
            Dehz.webhook.send('statebags', {
                title = 'State bag write spam',
                description = ('%d keys are above the %d writes/second threshold. This is observation only - state bag writes cannot be blocked or throttled from a resource.')
                    :format(#flagged, threshold),
                severity = 'warning',
                fields = fields
            })
        end
    end

    windowCounts = {}
    windowTotal = 0
    windowStartedAt = now
end

function statebags.currentRate()
    return util.round(currentRate, 2)
end

function statebags.topKeys(n)
    return util.topN(totalCounts, n or Config.StateBags.topKeys or 20, function(item)
        return { key = item.key, writes = item.value }
    end)
end

function statebags.topBags(n)
    return util.topN(bagCounts, n or 10, function(item)
        return { scope = item.key, writes = item.value }
    end)
end

function statebags.report()
    return {
        enabled = Config.StateBags.enabled == true,
        active = active,
        canThrottle = false,
        note = 'Observation only. The FiveM state bag change handler cannot reject or throttle a write - this is a documented engine limitation, not a missing feature.',
        rate = statebags.currentRate(),
        threshold = Config.StateBags.threshold,
        windowMs = windowMs(),
        flagged = flagged,
        topKeys = statebags.topKeys(),
        topBags = statebags.topBags()
    }
end

function statebags.start()
    if not Config.StateBags.enabled then
        log.info('statebags', 'state bag monitor disabled in config')
        return
    end

    windowStartedAt = GetGameTimer()
    active = true

    handlerCookie = AddStateBagChangeHandler(nil, nil, function(bagName, key)
        windowTotal = windowTotal + 1
        windowCounts[key] = (windowCounts[key] or 0) + 1
        totalCounts[key] = (totalCounts[key] or 0) + 1

        local scope = bagName:match('^(%a+):') or bagName
        bagCounts[scope] = (bagCounts[scope] or 0) + 1
    end)

    util.loop('statebags', function()
        return windowMs()
    end, function()
        rollWindow(GetGameTimer())
    end, windowMs())

    log.info('statebags', 'state bag monitor active (reports spam, cannot prevent it)')
end

Dehz.statebags = statebags
