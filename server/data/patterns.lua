local Dehz = Dehz

Dehz.data = Dehz.data or {}

local deprecated = {
    {
        id = 'culling_natives',
        match = 'SetEntityDistanceCullingRadius',
        label = 'deprecated culling native',
        note = 'Cfx.re documents the culling natives as deprecated with known, unfixable issues.'
    },
    {
        id = 'culling_natives_player',
        match = 'SetPlayerCullingRadius',
        label = 'deprecated culling native',
        note = 'Cfx.re documents the culling natives as deprecated with known, unfixable issues.'
    },
    {
        id = 'register_server_event',
        match = 'RegisterServerEvent(',
        label = 'superseded event registration',
        note = 'RegisterServerEvent is the old name for RegisterNetEvent.'
    },
    {
        id = 'mysql_async_sync',
        match = 'MySQL.Sync.',
        label = 'legacy synchronous database call',
        note = 'mysql-async synchronous calls block the server thread. The oxmysql promise API does not.'
    },
    {
        id = 'mysql_async_async',
        match = 'MySQL.Async.',
        label = 'legacy database API',
        note = 'mysql-async is superseded by oxmysql.'
    },
    {
        id = 'ghmattimysql',
        match = 'ghmattimysql',
        label = 'legacy database library',
        note = 'ghmattimysql is no longer maintained.'
    },
    {
        id = 'get_player_ped_minus_one',
        match = 'GetPlayerPed(-1)',
        label = 'superseded native',
        note = 'PlayerPedId() replaced GetPlayerPed(-1) and is considerably cheaper.'
    }
}

local yieldTokens = {
    'Wait(',
    'Citizen.Wait(',
    'Citizen.Await(',
    'coroutine.yield'
}

local threadTokens = {
    'CreateThread(',
    'Citizen.CreateThread(',
    'Citizen.CreateThreadNow('
}

local eventHandlerTokens = {
    'AddEventHandler(',
    'RegisterNetEvent('
}

local scanExtensions = {
    ['.lua'] = true,
    ['.js'] = true,
    ['.ts'] = true
}

local skipDirectories = {
    ['stream'] = true,
    ['node_modules'] = true,
    ['.git'] = true,
    ['web'] = true,
    ['dist'] = true,
    ['build'] = true,
    ['html'] = true,
    ['ui'] = true,
    ['nui'] = true
}

local streamExtensions = {
    ['.ytd'] = true, ['.ydr'] = true, ['.yft'] = true, ['.ycd'] = true,
    ['.ymap'] = true, ['.ytyp'] = true, ['.ynv'] = true, ['.ybn'] = true,
    ['.ydd'] = true, ['.awc'] = true, ['.rpf'] = true, ['.ymt'] = true,
    ['.ymf'] = true, ['.gxt2'] = true, ['.dat'] = true, ['.ipl'] = true
}

local manifestVersions = {
    adamant = 1,
    bodacious = 2,
    cerulean = 3
}

Dehz.data.patterns = {
    deprecated = deprecated,
    yieldTokens = yieldTokens,
    threadTokens = threadTokens,
    eventHandlerTokens = eventHandlerTokens,
    scanExtensions = scanExtensions,
    skipDirectories = skipDirectories,
    streamExtensions = streamExtensions,
    manifestVersions = manifestVersions,
    latestManifestVersion = 'cerulean'
}
