local Dehz = Dehz
local log = Dehz.log

local util = {}

local floor = math.floor
local sqrt = math.sqrt
local sort = table.sort
local upper = string.upper
local gsub = string.gsub

function util.now()
    return GetGameTimer()
end

function util.trim(value)
    if type(value) ~= 'string' then return nil end
    return (value:gsub('^%s*(.-)%s*$', '%1'))
end

function util.normalisePlate(value)
    if type(value) ~= 'string' then return nil end
    local cleaned = gsub(upper(value), '%s', '')
    if cleaned == '' then return nil end
    return cleaned
end

function util.round(value, places)
    local mult = 10 ^ (places or 0)
    return floor(value * mult + 0.5) / mult
end

function util.dist2(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return dx * dx + dy * dy + dz * dz
end

function util.dist(ax, ay, az, bx, by, bz)
    return sqrt(util.dist2(ax, ay, az, bx, by, bz))
end

function util.formatBytes(bytes)
    if bytes < 1024 then return ('%d B'):format(bytes) end
    if bytes < 1048576 then return ('%.1f KB'):format(bytes / 1024) end
    if bytes < 1073741824 then return ('%.1f MB'):format(bytes / 1048576) end
    return ('%.2f GB'):format(bytes / 1073741824)
end

function util.setFromList(list, transform)
    local set = {}
    if type(list) ~= 'table' then return set end
    for i = 1, #list do
        local value = list[i]
        if transform then value = transform(value) end
        if value ~= nil then set[value] = true end
    end
    return set
end

function util.modelHash(value)
    if type(value) == 'number' then return value end
    if type(value) == 'string' then return GetHashKey(value) end
    return nil
end

function util.ring(size)
    local ring = {
        size = size,
        head = 0,
        count = 0,
        items = {}
    }

    function ring:push(item)
        self.head = (self.head % self.size) + 1
        self.items[self.head] = item
        if self.count < self.size then
            self.count = self.count + 1
        end
        return item
    end

    function ring:latest(count)
        local wanted = count or self.count
        if wanted > self.count then wanted = self.count end
        local out = {}
        local index = self.head
        for _ = 1, wanted do
            local item = self.items[index]
            if item ~= nil then out[#out + 1] = item end
            index = index - 1
            if index < 1 then index = self.size end
        end
        return out
    end

    function ring:all()
        return self:latest(self.count)
    end

    function ring:clear()
        self.head = 0
        self.count = 0
        self.items = {}
    end

    return ring
end

function util.percentile(values, p)
    local n = #values
    if n == 0 then return 0 end
    if n == 1 then return values[1] end
    local rank = (n - 1) * p + 1
    local low = floor(rank)
    local high = low + 1
    if high > n then return values[n] end
    local weight = rank - low
    return values[low] + (values[high] - values[low]) * weight
end

function util.percentiles(unsorted)
    local copy = {}
    for i = 1, #unsorted do copy[i] = unsorted[i] end
    sort(copy)
    return {
        count = #copy,
        min = copy[1] or 0,
        max = copy[#copy] or 0,
        p50 = util.percentile(copy, 0.50),
        p95 = util.percentile(copy, 0.95),
        p99 = util.percentile(copy, 0.99)
    }
end

function util.topN(counts, n, mapper)
    local list = {}
    for key, value in pairs(counts) do
        list[#list + 1] = { key = key, value = value }
    end
    sort(list, function(a, b)
        if a.value == b.value then return tostring(a.key) < tostring(b.key) end
        return a.value > b.value
    end)
    local out = {}
    for i = 1, math.min(n, #list) do
        out[i] = mapper and mapper(list[i]) or list[i]
    end
    return out
end

function util.guard(module, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        log.error(module, 'internal error: %s', tostring(err))
    end
    return ok, err
end

function util.thread(module, fn)
    CreateThread(function()
        while true do
            local ok, err = pcall(fn)
            if ok then return end
            log.error(module, 'thread crashed, restarting in 10s: %s', tostring(err))
            Wait(10000)
        end
    end)
end

function util.loop(module, intervalFn, fn, initialDelay)
    util.thread(module, function()
        if initialDelay and initialDelay > 0 then
            Wait(initialDelay)
        end
        while true do
            fn()
            local interval = intervalFn()
            if not interval or interval <= 0 then
                Wait(5000)
            else
                Wait(interval)
            end
        end
    end)
end

function util.pointInZones(zones, x, y, z)
    if type(zones) ~= 'table' then return nil end
    for i = 1, #zones do
        local zone = zones[i]
        local coords = zone.coords
        if coords then
            local radius = zone.radius or 50.0
            if util.dist2(x, y, z, coords.x, coords.y, coords.z) <= radius * radius then
                return zone.name or ('zone#' .. i)
            end
        end
    end
    return nil
end

function util.count(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
end

function util.clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

function util.base64(input)
    if type(input) ~= 'string' then return nil end
    local out = {}
    local length = #input
    local index = 1

    while index <= length do
        local a = input:byte(index) or 0
        local b = input:byte(index + 1)
        local c = input:byte(index + 2)

        local n = a * 65536 + (b or 0) * 256 + (c or 0)

        out[#out + 1] = b64chars:sub(floor(n / 262144) % 64 + 1, floor(n / 262144) % 64 + 1)
        out[#out + 1] = b64chars:sub(floor(n / 4096) % 64 + 1, floor(n / 4096) % 64 + 1)
        out[#out + 1] = b and b64chars:sub(floor(n / 64) % 64 + 1, floor(n / 64) % 64 + 1) or '='
        out[#out + 1] = c and b64chars:sub(n % 64 + 1, n % 64 + 1) or '='

        index = index + 3
    end

    return table.concat(out)
end

Dehz.util = util
