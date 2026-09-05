local Dehz = Dehz

Dehz.data = Dehz.data or {}

local entries = {
    {
        key = 'onesync',
        kind = 'enum',
        values = { 'off', 'legacy', 'on' },
        engineDefault = 'on',
        recommended = 'on',
        runtimeSettable = false,
        verb = 'set',
        severity = 'critical',
        impact = 'OneSync Infinity is required for more than 32 players and is the only mode where the server tracks entities at all. With it off or on legacy, this resource cannot see your world.'
    },
    {
        key = 'onesync_population',
        kind = 'bool',
        engineDefault = 'true',
        runtimeSettable = false,
        verb = 'set',
        advisory = true,
        severity = 'info',
        impact = 'Controls server-driven AI population. Turning it off removes ambient traffic and pedestrians entirely, which cuts entity count dramatically but changes how your city feels. This is a design decision, not a bug.'
    },
    {
        key = 'onesync_distanceCulling',
        kind = 'bool',
        engineDefault = 'true',
        recommended = 'true',
        runtimeSettable = true,
        verb = 'set',
        severity = 'critical',
        impact = 'Master switch for OneSync distance culling. With this off, every client is sent state for the entire world instead of only what is near them.'
    },
    {
        key = 'onesync_distanceCullVehicles',
        kind = 'bool',
        engineDefault = 'false',
        recommended = 'true',
        runtimeSettable = true,
        verb = 'set',
        severity = 'info',
        scaleWithPlayers = 48,
        impact = 'Also culls distant vehicles per player. A large reduction in sync load on busy servers. The trade-off is that far-away vehicles may not exist for spectators, aircraft and long-range sniping.'
    },
    {
        key = 'onesync_forceMigration',
        kind = 'bool',
        engineDefault = 'true',
        recommended = 'true',
        runtimeSettable = true,
        verb = 'set',
        severity = 'warning',
        impact = 'Moves ownership of an entity to another player when its owner leaves or moves away. Disabling it leaves entities stranded with no one simulating them.'
    },
    {
        key = 'onesync_radiusFrequency',
        kind = 'bool',
        engineDefault = 'true',
        recommended = 'true',
        runtimeSettable = true,
        verb = 'set',
        severity = 'info',
        impact = 'Sends updates for distant entities less often than for nearby ones. Almost always want this on.'
    },
    {
        key = 'onesync_automaticResend',
        kind = 'bool',
        engineDefault = 'false',
        runtimeSettable = true,
        verb = 'set',
        advisory = true,
        severity = 'info',
        impact = 'Resends sync packets that were not acknowledged. Helps players on poor connections at the cost of extra bandwidth. Only enable if you have a measured packet loss problem.'
    },
    {
        key = 'onesync_workaround763185',
        kind = 'bool',
        engineDefault = 'false',
        runtimeSettable = true,
        verb = 'set',
        advisory = true,
        severity = 'info',
        impact = 'A workaround for one specific vehicle sync bug. Only turn it on if you are actually hitting that bug.'
    },
    {
        key = 'onesync_logFile',
        kind = 'string',
        engineDefault = '',
        recommended = '',
        runtimeSettable = true,
        verb = 'set',
        severity = 'warning',
        emptyIsGood = true,
        impact = 'OneSync sync logging is writing every sync event to disk. This is a debugging tool and is expensive. Clear it unless you are actively debugging with Cfx.re.'
    },
    {
        key = 'sv_entityLockdown',
        kind = 'enum',
        values = { 'inactive', 'relaxed', 'strict' },
        engineDefault = 'inactive',
        recommended = 'relaxed',
        runtimeSettable = true,
        verb = 'set',
        severity = 'critical',
        impact = 'With lockdown inactive, any connected client can create unlimited entities on your server. "relaxed" blocks clients creating entities no script asked for. "strict" is stronger but breaks resources that create entities client-side.'
    },
    {
        key = 'sv_filterRequestControl',
        kind = 'int',
        engineDefault = '0',
        recommended = '2',
        runtimeSettable = true,
        verb = 'set',
        severity = 'warning',
        impact = 'Controls who may take ownership of an entity another player is using. 0 allows anything. 1 filters settled player entities, 2 filters all player-controlled entities, 3 adds settled non-player entities, 4 blocks every request. 2 stops most vehicle-stealing and ragdoll griefing.'
    },
    {
        key = 'sv_filterRequestControlSettleTimer',
        kind = 'int',
        engineDefault = '30000',
        runtimeSettable = true,
        verb = 'set',
        advisory = true,
        severity = 'info',
        impact = 'How long (ms) an entity must sit still before it counts as "settled" for the filter above. Only matters if sv_filterRequestControl is 1 or 3.'
    },
    {
        key = 'sv_protectServerEntities',
        kind = 'bool',
        engineDefault = 'false',
        recommended = 'true',
        runtimeSettable = true,
        verb = 'set',
        severity = 'warning',
        impact = 'Stops clients deleting entities that your server scripts created. Directly relevant if you are running a cleanup tool: without it a client can remove things the server owns.'
    },
    {
        key = 'sv_stateBagStrictMode',
        kind = 'bool',
        engineDefault = 'false',
        recommended = 'true',
        runtimeSettable = true,
        verb = 'set',
        severity = 'info',
        impact = 'Rejects state bag writes from clients for entities they do not own. Reduces one avenue of state bag spam. Some older resources rely on the loose behaviour, so test it.'
    },
    {
        key = 'sv_enableNetworkedSounds',
        kind = 'bool',
        engineDefault = 'true',
        recommended = 'false',
        runtimeSettable = true,
        verb = 'set',
        severity = 'info',
        impact = 'Lets clients trigger sounds on other clients over the network. A common spam and griefing vector. Turning it off is safe for most servers but will break resources that rely on networked sound events.'
    },
    {
        key = 'sv_enableNetworkedPhoneExplosions',
        kind = 'bool',
        engineDefault = 'false',
        recommended = 'false',
        runtimeSettable = true,
        verb = 'set',
        severity = 'critical',
        impact = 'Allows clients to trigger explosions through the in-game phone. This is an exploit vector with no legitimate use on a roleplay server.'
    },
    {
        key = 'sv_enableNetworkedScriptEntityStates',
        kind = 'bool',
        engineDefault = 'true',
        runtimeSettable = true,
        verb = 'set',
        advisory = true,
        severity = 'info',
        impact = 'Networks script-set entity states such as invincibility and collision. Turning it off reduces traffic but breaks resources that set these states client-side.'
    },
    {
        key = 'sv_scriptHookAllowed',
        kind = 'bool',
        engineDefault = 'false',
        recommended = 'false',
        runtimeSettable = true,
        verb = 'set',
        severity = 'critical',
        impact = 'Allows ScriptHook and therefore trainers and menus on your server. If this is on, every other setting in this list is decoration.'
    },
    {
        key = 'sv_lan',
        kind = 'bool',
        engineDefault = 'false',
        recommended = 'false',
        runtimeSettable = false,
        verb = 'set',
        severity = 'critical',
        impact = 'LAN mode disables player authentication entirely and treats everyone as trusted. It should never be on for a public server.'
    },
    {
        key = 'sv_enforceGameBuild',
        kind = 'string',
        runtimeSettable = false,
        verb = 'set',
        advisory = true,
        severity = 'info',
        impact = 'The game build every player is forced onto. Reported here for context when comparing crash and hitch reports across servers. This cannot be changed while the server is running.'
    },
    {
        key = 'sv_maxClients',
        kind = 'int',
        engineDefault = '30',
        runtimeSettable = false,
        verb = 'set',
        severity = 'warning',
        maxClientsCheck = true,
        impact = 'Player slot count. Above 32 slots you must be on OneSync Infinity, and above roughly 48 you should expect to tune culling and population.'
    },
    {
        key = 'sv_requestParanoia',
        kind = 'int',
        engineDefault = '0',
        runtimeSettable = true,
        verb = 'set',
        advisory = true,
        severity = 'info',
        impact = 'How strictly the server treats clients making unusual info requests. 0 is off; higher levels drop clients that probe the server endpoints. Raise it if you are being scraped, not for performance.'
    },
    {
        key = 'sv_useAccurateSends',
        kind = 'bool',
        engineDefault = 'true',
        runtimeSettable = true,
        verb = 'set',
        advisory = true,
        severity = 'info',
        impact = 'More precise packet pacing. Leave on unless Cfx.re support has told you otherwise.'
    },
    {
        key = 'sv_poolSizesIncrease',
        kind = 'string',
        engineDefault = '',
        runtimeSettable = false,
        verb = 'set',
        advisory = true,
        severity = 'info',
        impact = 'Client-side pool size increases. Reported for context: if you are seeing pool-full crashes on clients this is where the fix lives.'
    },
    {
        key = 'sv_pureLevel',
        kind = 'int',
        engineDefault = '0',
        runtimeSettable = false,
        verb = 'set',
        advisory = true,
        severity = 'info',
        impact = 'Client file verification level. 1 blocks modified game files, 2 also blocks added ones. Anti-cheat, not performance, and it will lock out players using graphics mods.'
    },
    {
        key = 'sv_endpointPrivacy',
        deprecated = true,
        kind = 'bool',
        runtimeSettable = true,
        verb = 'set',
        severity = 'info',
        impact = 'This ConVar has been removed from FXServer. Player endpoint addresses are no longer exposed on any HTTP endpoint regardless of this setting. Delete the line from your server.cfg.'
    },
    {
        key = 'sv_exposePlayerIdentifiersInHttpEndpoint',
        deprecated = true,
        kind = 'bool',
        runtimeSettable = true,
        verb = 'set',
        severity = 'info',
        impact = 'This ConVar has been removed from FXServer. Delete the line from your server.cfg.'
    }
}

Dehz.data.convars = entries
