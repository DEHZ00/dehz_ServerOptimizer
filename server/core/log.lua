local Dehz = Dehz
local levels = Dehz.LOG_LEVEL

local resourceName = GetCurrentResourceName()
local selfChannel = 'script:' .. resourceName
local prefix = '[Dehz_ServerOptimizer]'

local colourFor = {
    error = '^1',
    warn = '^3',
    info = '^5',
    debug = '^8'
}

local buffer = {}
local bufferHead = 0
local bufferSize = 0
local bufferMax = 400
local threshold = 2
local useColours = true
local sequence = 0

local log = {}

log.selfChannel = selfChannel
log.prefix = prefix

local function push(module, level, message)
    sequence = sequence + 1
    bufferHead = (bufferHead % bufferMax) + 1
    buffer[bufferHead] = {
        id = sequence,
        at = os.time(),
        ms = GetGameTimer(),
        module = module,
        level = level,
        message = message
    }
    if bufferSize < bufferMax then
        bufferSize = bufferSize + 1
    end
end

function log.configure()
    local cfg = Config and Config.Logging or nil
    if not cfg then return end
    threshold = levels[cfg.level] or 2
    useColours = cfg.colours ~= false
    local newMax = tonumber(cfg.bufferSize) or 400
    if newMax < 50 then newMax = 50 end
    if newMax ~= bufferMax then
        bufferMax = newMax
        buffer = {}
        bufferHead = 0
        bufferSize = 0
    end
end

function log.write(module, level, message, ...)
    local value = levels[level] or 2
    if value < threshold then return end

    local text = message
    if select('#', ...) > 0 then
        local ok, formatted = pcall(string.format, message, ...)
        text = ok and formatted or message
    end

    push(module, level, text)

    if useColours then
        print(('%s%s [%s] %s^7'):format(colourFor[level] or '^7', prefix, module, text))
    else
        print(('%s [%s] %s'):format(prefix, module, text))
    end
end

function log.error(module, message, ...) log.write(module, 'error', message, ...) end
function log.warn(module, message, ...) log.write(module, 'warn', message, ...) end
function log.info(module, message, ...) log.write(module, 'info', message, ...) end
function log.debug(module, message, ...) log.write(module, 'debug', message, ...) end

function log.banner(lines)
    for i = 1, #lines do
        if useColours then
            print(('^5%s^7 %s'):format(prefix, lines[i]))
        else
            print(('%s %s'):format(prefix, lines[i]))
        end
    end
end

function log.recent(count, moduleFilter, levelFilter)
    local out = {}
    local wanted = count or bufferSize
    if wanted > bufferSize then wanted = bufferSize end
    local minLevel = levelFilter and levels[levelFilter] or 0

    local index = bufferHead
    local seen = 0
    while seen < bufferSize and #out < wanted do
        local entry = buffer[index]
        if entry then
            local levelOk = (levels[entry.level] or 0) >= minLevel
            local moduleOk = (not moduleFilter) or moduleFilter == '' or entry.module == moduleFilter
            if levelOk and moduleOk then
                out[#out + 1] = entry
            end
        end
        index = index - 1
        if index < 1 then index = bufferMax end
        seen = seen + 1
    end

    return out
end

function log.modules()
    local set, out = {}, {}
    for i = 1, bufferSize do
        local entry = buffer[i]
        if entry and not set[entry.module] then
            set[entry.module] = true
            out[#out + 1] = entry.module
        end
    end
    table.sort(out)
    return out
end

Dehz.log = log
