Dehz = Dehz or {}

Dehz.RESOURCE = 'Dehz_ServerOptimizer'

Dehz.POP_TYPE = {
    [0] = 'unknown',
    [1] = 'random_permanent',
    [2] = 'random_parked',
    [3] = 'random_patrol',
    [4] = 'random_scenario',
    [5] = 'random_ambient',
    [6] = 'permanent',
    [7] = 'mission',
    [8] = 'replay',
    [9] = 'cache',
    [10] = 'tool'
}

Dehz.ORPHAN_MODE = {
    DELETE_WHEN_NOT_RELEVANT = 0,
    DELETE_ON_OWNER_DISCONNECT = 1,
    KEEP_ENTITY = 2
}

Dehz.SEVERITY = {
    critical = 3,
    warning = 2,
    info = 1
}

Dehz.LOG_LEVEL = {
    error = 4,
    warn = 3,
    info = 2,
    debug = 1
}

Dehz.CATEGORY = { 'vehicles', 'peds', 'objects' }

Dehz.ENTITY_TYPE = {
    peds = 1,
    vehicles = 2,
    objects = 3
}

Dehz.PEER_STAT = {
    PACKET_LOSS = 0,
    PACKET_LOSS_VARIANCE = 1,
    PACKET_LOSS_EPOCH = 2,
    ROUND_TRIP_TIME = 3,
    ROUND_TRIP_TIME_VARIANCE = 4,
    LAST_ROUND_TRIP_TIME = 5,
    LAST_ROUND_TRIP_TIME_VARIANCE = 6,
    PACKET_THROTTLE_EPOCH = 7
}

Dehz.PACKET_LOSS_SCALE = 65536

Dehz.SERVER_FRAME_MS = 50
