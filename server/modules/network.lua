local Dehz = Dehz
local log = Dehz.log
local util = Dehz.util
local caps = Dehz.caps

local network = {}

local samples
local dropReasons = {}
local dropTotal = 0
local latest = nil
local peakPlayers = 0

local STAT = Dehz.PEER_STAT
local LOSS_SCALE = Dehz.PACKET_LOSS_SCALE

local function categoriseDrop(reason)
    if type(reason) ~= 'string' then return 'unknown' end
    local lowered = reason:lower()

    if lowered:find('timed out', 1, true) or lowered:find('timeout', 1, true) then return 'timeout' end
    if lowered:find('exited', 1, true) or lowered:find('quit', 1, true) or lowered:find('disconnected', 1, true) then return 'player_exit' end
    if lowered:find('kick', 1, true) then return 'kicked' end
    if lowered:find('ban', 1, true) then return 'banned' end
    if lowered:find('crash', 1, true) or lowered:find('game crashed', 1, true) then return 'crash' end
    if lowered:find('sync', 1, true) then return 'sync_failure' end
    if lowered:find('server shut', 1, true) or lowered:find('restart', 1, true) then return 'server_restart' end
    if lowered:find('reconnect', 1, true) then return 'reconnect' end

    return 'other'
end

local function collectPeerStats(players)
    if not caps.peerStatistics or Config.Network.peerStats == false then
        return nil
    end

    local pingTotal, pingCount, pingMax = 0, 0, 0
    local lossTotal, lossMax = 0.0, 0.0
    local worst = nil

    for i = 1, #players do
        local src = players[i]

        local okRtt, rtt = pcall(GetPlayerPeerStatistics, src, STAT.ROUND_TRIP_TIME)
        local okLoss, loss = pcall(GetPlayerPeerStatistics, src, STAT.PACKET_LOSS)

        if okRtt and type(rtt) == 'number' and rtt > 0 then
            pingTotal = pingTotal + rtt
            pingCount = pingCount + 1
            if rtt > pingMax then pingMax = rtt end
        end

        if okLoss and type(loss) == 'number' then
            local pct = (loss / LOSS_SCALE) * 100.0
            lossTotal = lossTotal + pct
            if pct > lossMax then
                lossMax = pct
                worst = { source = src, name = GetPlayerName(src), loss = util.round(pct, 2), ping = okRtt and rtt or nil }
            end
        end
    end

    return {
        avgPing = pingCount > 0 and math.floor(pingTotal / pingCount) or 0,
        maxPing = pingMax,
        avgPacketLoss = #players > 0 and util.round(lossTotal / #players, 2) or 0.0,
        maxPacketLoss = util.round(lossMax, 2),
        worst = worst,
        measured = pingCount
    }
end

local function sample()
    local players = GetPlayers()
    local count = #players
    if count > peakPlayers then peakPlayers = count end

    local counts = Dehz.entities.counts()
    local peer = collectPeerStats(players)

    latest = {
        at = os.time(),
        ms = GetGameTimer(),
        players = count,
        vehicles = counts.vehicles,
        peds = counts.peds,
        objects = counts.objects,
        total = counts.total,
        ratio = Dehz.entities.ratio(),
        avgPing = peer and peer.avgPing or nil,
        maxPing = peer and peer.maxPing or nil,
        avgPacketLoss = peer and peer.avgPacketLoss or nil,
        maxPacketLoss = peer and peer.maxPacketLoss or nil,
        worstPeer = peer and peer.worst or nil
    }

    samples:push(latest)
    Dehz.persist.recordMetric(latest)
end

function network.latest()
    return latest
end

function network.history(count)
    if not samples then return {} end
    return samples:latest(count or 120)
end

function network.report()
    local reasons = util.topN(dropReasons, 12, function(item)
        return { category = item.key, count = item.value }
    end)

    return {
        enabled = Config.Network.enabled == true,
        peerStatsAvailable = caps.peerStatistics,
        latest = latest,
        history = network.history(120),
        peakPlayers = peakPlayers,
        drops = { total = dropTotal, byCategory = reasons },
        sampleInterval = Config.Network.sampleInterval
    }
end

function network.start()
    AddEventHandler('playerDropped', function(reason)
        local category = categoriseDrop(reason)
        dropReasons[category] = (dropReasons[category] or 0) + 1
        dropTotal = dropTotal + 1
    end)

    samples = util.ring(Config.Network.historySize or 240)

    if not Config.Network.enabled then
        log.info('network', 'network monitor disabled in config')
        return
    end

    util.loop('network', function()
        return Config.Network.sampleInterval or 30000
    end, sample, 10000)

    if not caps.peerStatistics then
        log.warn('network', 'GetPlayerPeerStatistics is not available on this build; per-player ping and packet loss will not be collected')
    end

    log.info('network', 'network monitor sampling every %dms', Config.Network.sampleInterval or 30000)
end

Dehz.network = network
