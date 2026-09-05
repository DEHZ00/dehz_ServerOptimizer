local Dehz = Dehz
local log = Dehz.log

local webhook = {}

local queue = {}
local draining = false
local lastSendAt = 0
local sentCount = 0
local failedCount = 0

local severityColour = {
    critical = 13111342,
    warning = 15105570,
    info = 3447003,
    success = 3066993
}

local function urlFor(channel)
    local hooks = Config.Reporting and Config.Reporting.webhooks or {}
    local url = hooks[channel]
    if type(url) == 'string' and url ~= '' then return url end
    local general = hooks.general
    if type(general) == 'string' and general ~= '' then return general end
    return nil
end

local function drain()
    while #queue > 0 do
        local item = table.remove(queue, 1)
        local wait = (Config.Reporting.minInterval or 2000) - (GetGameTimer() - lastSendAt)
        if wait > 0 then Wait(wait) end

        lastSendAt = GetGameTimer()

        PerformHttpRequest(item.url, function(status)
            if status and status >= 200 and status < 300 then
                sentCount = sentCount + 1
            else
                failedCount = failedCount + 1
                log.warn('webhook', 'discord webhook for "%s" returned status %s', item.channel, tostring(status))
            end
        end, 'POST', item.body, { ['Content-Type'] = 'application/json' })
    end
    draining = false
end

function webhook.send(channel, embed)
    local url = urlFor(channel)
    if not url then return false end

    local payload = {
        username = Config.Reporting.username or 'Dehz Optimizer',
        embeds = { {
            title = embed.title,
            description = embed.description,
            color = embed.colour or severityColour[embed.severity or 'info'] or (Config.Reporting.colour or 13111342),
            fields = embed.fields,
            footer = { text = ('Dehz_ServerOptimizer  |  mode: %s'):format(Dehz.state.mode()) },
            timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ')
        } }
    }

    local ok, body = pcall(json.encode, payload)
    if not ok then
        log.warn('webhook', 'failed to encode webhook payload for "%s"', channel)
        return false
    end

    queue[#queue + 1] = { url = url, body = body, channel = channel }

    if not draining then
        draining = true
        Dehz.util.thread('webhook', drain)
    end

    return true
end

function webhook.stats()
    return { sent = sentCount, failed = failedCount, queued = #queue }
end

Dehz.webhook = webhook
