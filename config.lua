-- =====================================================================
--  Dehz_ServerOptimizer - configuration
-- =====================================================================
--  This is the only file you need to edit. Everything below is written
--  for server owners, not developers. Read the comments before you
--  change a value - a few of these settings can delete things.
--
--  Nothing in this resource deletes anything until you deliberately
--  turn two separate safety catches off. Those are marked clearly.
-- =====================================================================

Config = {}

-- ---------------------------------------------------------------------
--  GLOBAL OPERATING MODE
-- ---------------------------------------------------------------------
--  'monitor'  Everything watches, scores, logs and reports. Nothing on
--             your server is ever changed or deleted. This is the safe
--             default and it is where you should stay until you have
--             read a few days of reports.
--
--  'active'   Allows the Entity Sweeper and Distance Culling to
--             actually do something - but they STILL obey their own
--             dryRun / enabled switches further down.
--
--  Setting this back to 'monitor' instantly disables every destructive
--  behaviour in the resource, no matter what anything else says.
-- ---------------------------------------------------------------------
Config.Mode = 'monitor'

-- ---------------------------------------------------------------------
--  FRAMEWORK
-- ---------------------------------------------------------------------
--  'auto'        Look for ESX Legacy, then QBCore, then run standalone.
--  'standalone'  Ignore frameworks entirely.
--  'esx'         Force ESX Legacy.
--  'qb'          Force QBCore.
--
--  IMPORTANT: this resource works fully on a server with no framework.
--  A framework only adds two things: better permission checks, and the
--  ability to look up player-owned vehicle plates so the sweeper never
--  touches someone's garage car.
--
--  The framework that was actually detected is printed to your console
--  once at startup. Check it says what you expect.
-- ---------------------------------------------------------------------
Config.Framework = 'auto'

Config.FrameworkOptions = {

    -- How often (ms) to refresh the list of player-owned plates from the
    -- database. 10 minutes is fine for almost everyone. This is never
    -- queried per entity or per sweep tick - only on this timer.
    plateRefreshInterval = 600000,

    -- Plates you always want protected, whatever the database says.
    -- Useful for staff vehicles, event props, tow trucks, and so on.
    -- Case and spaces do not matter.
    alwaysProtectedPlates = {
        -- 'STAFF01',
    },

    esx = {
        resource = 'es_extended',

        -- Which tables and columns hold owned vehicle plates.
        -- These are the ESX Legacy defaults as shipped. If you renamed a
        -- table, or your fork uses a different column, change it here.
        -- NEVER assume the default is right for your server - open your
        -- database and check.
        vehicleTables = {
            { table = 'owned_vehicles',  column = 'plate' },
            { table = 'rented_vehicles', column = 'plate' }
        },

        -- ESX groups treated as admin, on top of the ACE check below.
        adminGroups = { 'admin', 'superadmin' }
    },

    qb = {
        resource = 'qb-core',

        -- QBCore defaults. Note that current qb-core does NOT ship a
        -- player_vehicles table itself - it comes from qb-garages or
        -- qb-vehicleshop - so double check yours actually exists.
        -- 'fakeplate' is included because a car wearing a fake plate
        -- would otherwise look unowned to the sweeper.
        vehicleTables = {
            { table = 'player_vehicles', column = 'plate' },
            { table = 'player_vehicles', column = 'fakeplate' }
        },

        -- QBCore permission levels treated as admin.
        adminPermissions = { 'god', 'admin' }
    }
}

-- ---------------------------------------------------------------------
--  PERMISSIONS
-- ---------------------------------------------------------------------
--  ACE is checked first and ACE always wins. If a player has this ACE
--  object they are an admin here, and no framework check happens.
--
--  Add to your server.cfg:
--     add_ace group.admin dehz.optimizer allow
-- ---------------------------------------------------------------------
Config.Permissions = {
    ace = 'dehz.optimizer',

    -- Treat anyone with the built in 'command' ACE as an admin too.
    -- This is what most servers already give their staff. Set to false
    -- if you want the dedicated ACE above to be the only way in.
    allowCommandAce = true
}

-- ---------------------------------------------------------------------
--  CONSOLE OUTPUT
-- ---------------------------------------------------------------------
Config.Logging = {

    -- 'error' | 'warn' | 'info' | 'debug'
    -- 'info' is the right level for normal running. 'debug' is loud.
    level = 'info',

    -- Colour codes in console output. txAdmin renders these properly.
    -- Turn off if your log viewer shows ^1 ^2 as literal text.
    colours = true,

    -- How many recent log lines the dashboard's Logs tab keeps.
    bufferSize = 400
}

-- ---------------------------------------------------------------------
--  DASHBOARD
-- ---------------------------------------------------------------------
Config.Dashboard = {
    enabled = true,

    -- Chat command that opens the dashboard. Players without permission
    -- get no reply at all - no error, no notification, nothing.
    command = 'serveropt',

    keybind = {
        enabled = false,

        -- Only used the first time a player runs the resource. After
        -- that they can rebind it themselves in the FiveM key settings.
        key = 'F7'
    },

    -- How often (ms) the dashboard refreshes while it is OPEN. It costs
    -- nothing while closed. Do not set this below 1000.
    refreshInterval = 2000
}

-- ---------------------------------------------------------------------
--  ENTITY INDEX  (feeds the sweeper, the dashboard and hitch snapshots)
-- ---------------------------------------------------------------------
--  This is the only thing that runs on a regular timer by default. It
--  reads the server's entity list, notes what is out there and how long
--  it has been there, and does nothing else.
--
--  NOTE: this needs OneSync. On a server with OneSync off there is no
--  server-side entity list at all, and the resource will tell you so in
--  the console instead of quietly reporting zero entities.
-- ---------------------------------------------------------------------
Config.Entities = {
    enabled = true,

    -- How often (ms) to take a full inventory of world entities.
    scanInterval = 15000,

    -- How many entities to process per server frame. The server frame is
    -- 50ms, so 250 here means roughly 5000 entities per second. Lower
    -- this if you see the scan itself showing up in hitch reports.
    entitiesPerTick = 250,

    -- How many models to list in the dashboard's "top models" table.
    topModelCount = 20,

    categories = {
        vehicles = true,
        peds = true,
        objects = true
    }
}

-- ---------------------------------------------------------------------
--  MODULE 1 - ENTITY SWEEPER
-- ---------------------------------------------------------------------
--  Finds abandoned world entities and, if you let it, removes them.
--
--  READ THIS BEFORE CHANGING ANYTHING HERE.
--
--  There are three separate safety catches, and all three must be off
--  before a single entity is touched:
--     1. Config.Mode must be 'active'
--     2. Config.Sweeper.dryRun must be false
--     3. Config.Sweeper.action must be 'orphan' or 'delete'
--
--  Leave it on the shipped settings for at least a week. Read the dry
--  run reports. Only then decide.
-- ---------------------------------------------------------------------
Config.Sweeper = {
    enabled = true,

    -- SAFETY CATCH 2.
    -- true  = run every single check, log exactly what it WOULD have
    --         done and why, and touch nothing.
    -- false = allow the action below to actually happen.
    dryRun = true,

    -- SAFETY CATCH 3. What to do with an entity that fails every check.
    --
    --  'report'  Write it to the log and the dashboard. Do nothing else.
    --            This is what you want first.
    --
    --  'orphan'  Ask the SERVER to clean it up when its original owner
    --            disconnects, using the engine's own orphan handling.
    --            Nothing is deleted by this resource. This is reversible,
    --            it is far safer than deleting, and for most servers it
    --            is enough. This is the recommended first real step.
    --
    --  'delete'  Delete the entity outright. Last resort.
    action = 'report',

    -- How often (ms) a sweep runs. Five minutes. There is no good reason
    -- to make this aggressive - abandoned entities are not an emergency.
    interval = 300000,

    -- Do not sweep for this long (ms) after the server starts. Entities
    -- are still streaming in and respawning during a restart, and they
    -- will look abandoned when they are not.
    startupGrace = 180000,

    -- Do not sweep unless at least this many players are connected.
    -- Set to 0 to sweep an empty server (not recommended - an empty
    -- server has no players near anything, so everything looks orphaned).
    minPlayersOnline = 1,

    -- Hard cap on how many entities one sweep may act on. If a sweep
    -- wants to exceed this it will stop at the cap and shout loudly in
    -- your console, because hitting this almost always means a setting
    -- below is wrong rather than that your server is really that dirty.
    maxDeletionsPerSweep = 50,

    -- An entity must fail its checks this many sweeps IN A ROW before it
    -- is eligible. With the 5 minute interval above, 3 means an entity
    -- must look abandoned for 15 minutes straight. This exists so a
    -- momentary streaming gap can never cause a deletion.
    graceSweeps = 3,

    -- If a framework is detected but the owned-vehicle plate lookup
    -- fails (wrong table name, oxmysql missing, database down), refuse
    -- to run in live mode at all. Leave this true. Turning it off means
    -- a broken database query silently widens what may be deleted.
    -- On a standalone server there are no owned vehicles to look up, so
    -- this setting does nothing.
    requirePlateLookup = true,

    -- After acting, check on the next sweep whether the entity is
    -- actually gone. Server-side deletion does not always stick, and
    -- knowing that is more useful than assuming it worked.
    verifyDeletions = true,

    -- When another resource marks an entity protected through our
    -- export, also tell the SERVER to never clean it up itself. Without
    -- this you are only protecting it from us, not from the engine.
    setKeepEntityOnProtect = true,

    -- Replicate the protection flag to clients so other resources can
    -- see it client-side too. Harmless either way.
    replicateProtectionState = true,

    -- How the sweeper works out whether an entity is near a player.
    --
    --  false  Work it out from the entity index we already hold, in Lua.
    --         Predictable, spread across frames, always available.
    --
    --  true   Ask the server for the entities near each player instead.
    --         Faster per entity, but the server walks its entire entity
    --         list once PER PLAYER PER CATEGORY, so it gets worse as your
    --         player count rises. Only worth it on a small server.
    useRadiusQuery = false,

    -- How many seats to check when deciding whether a vehicle is empty.
    -- There is no server native for a model's real seat count, so this
    -- is a fixed depth. 8 covers everything in the base game.
    seatScanDepth = 8,

    -- Per category rules. Distances are in game units (roughly metres).
    categories = {

        vehicles = {
            enabled = true,

            -- Minimum age (ms) since WE first saw this entity. This is
            -- tracked by us, not read from anywhere that might lie.
            minAgeMs = 900000,

            -- Must be at least this far from every connected player.
            minDistance = 400.0,

            -- Which population types may be swept. See the list below.
            -- The safe default is ambient traffic only. 'mission' and
            -- 'permanent' entities belong to scripts and are excluded.
            --   random_permanent, random_parked, random_patrol,
            --   random_scenario, random_ambient, unknown, permanent,
            --   mission, replay, cache, tool
            sweepablePopulationTypes = {
                'random_parked', 'random_patrol',
                'random_scenario', 'random_ambient'
            },

            -- Only consider entities with no current network owner
            -- (nobody is simulating them). Recommended true.
            requireNoOwner = true
        },

        peds = {
            enabled = true,
            minAgeMs = 600000,
            minDistance = 300.0,
            sweepablePopulationTypes = {
                'random_patrol', 'random_scenario', 'random_ambient'
            },
            requireNoOwner = true
        },

        objects = {
            enabled = true,
            minAgeMs = 1800000,
            minDistance = 300.0,

            -- Objects are the most dangerous category to sweep. Props
            -- placed by scripts often report 'unknown'. The default here
            -- deliberately sweeps nothing until you widen it yourself
            -- after reading your dry run reports.
            sweepablePopulationTypes = {},
            requireNoOwner = true
        }
    },

    -- -----------------------------------------------------------------
    --  PROTECTION LAYERS
    --  Anything matched here is skipped unconditionally - regardless of
    --  age, distance, occupancy or population type.
    -- -----------------------------------------------------------------
    protect = {

        -- The state bag key other resources set to protect an entity:
        --     Entity(veh).state.dehz_protected = true
        -- This is the main integration point for other scripts.
        stateKey = 'dehz_protected',

        -- Other resources' own persistence flags. If any of these keys
        -- is set truthy on an entity we leave it alone. Add whatever
        -- your persistence or garage script uses.
        foreignStateKeys = {
            'persistent',
            'keepEntity',
            'dontDelete'
        },

        -- Never touch anything created by these resources. This is the
        -- single most useful protection layer - it needs no cooperation
        -- from the resource itself. Names are case sensitive.
        resources = {
            -- 'esx_garage',
            -- 'qb-garages',
        },

        -- Model names or hashes that are never swept.
        models = {
            -- 'flatbed',
        },

        -- Entities in a routing bucket other than 0 are usually part of
        -- instanced content (apartments, heists, minigames). Leave true.
        protectNonZeroBuckets = true,

        -- Specific routing buckets that are always protected, even if
        -- the setting above is false.
        routingBuckets = {
            -- 5, 12
        },

        -- Circular safe zones. Nothing inside one is ever swept.
        -- Put your dealerships, garages, impounds, job spawns and any
        -- prop-heavy MLO exterior in here.
        zones = {
            -- { name = 'PDM Dealership', coords = vector3(-56.7, -1096.6, 26.4), radius = 90.0 },
            -- { name = 'Legion Garage',  coords = vector3(215.9, -810.0, 30.7),  radius = 60.0 },
        },

        -- Entities that another resource has explicitly asked the server
        -- to keep permanently are treated as protected. Leave true.
        respectKeepEntityOrphanMode = true,

        -- Never sweep an entity that is attached to something else
        -- (trailers, props carried by peds). Leave true.
        skipAttached = true,

        -- Entities reporting exactly 0,0,0 have not finished syncing
        -- yet. They are not really at the origin and they are not really
        -- far from your players. Leave true.
        skipUnsyncedOrigin = true
    }
}

-- ---------------------------------------------------------------------
--  MODULE 2 - DISTANCE CULLING            *** DEPRECATED BY CFX.RE ***
-- ---------------------------------------------------------------------
--  This module uses SetEntityDistanceCullingRadius. The FiveM native
--  documentation states, in these words:
--
--      "Culling natives are deprecated and have known, unfixable issues"
--
--  The known problem: an entity that is far from one player but close to
--  another can be culled wrongly. We did not write that warning and we
--  cannot fix it.
--
--  The supported way to get the same result is the two OneSync convars
--  onesync_distanceCulling and onesync_distanceCullVehicles, which the
--  Config Auditor below will report on for you. Use those first.
--
--  This module ships disabled and requires a second explicit opt-in.
-- ---------------------------------------------------------------------
Config.Culling = {
    enabled = false,

    -- You must set this to true as well. It exists so that nobody turns
    -- culling on without having read the paragraph above.
    acknowledgeDeprecated = false,

    -- How often (ms) to apply radii to newly seen entities.
    interval = 60000,

    -- Radius per category, in game units.
    radii = {
        vehicles = 400.0,
        peds = 300.0,
        objects = 250.0
    },

    -- Models that legitimately need to be visible from further away.
    -- Aircraft, boats and very large props.
    modelOverrides = {
        -- ['titan'] = 1500.0,
        -- ['dinghy'] = 800.0,
    }
}

-- ---------------------------------------------------------------------
--  MODULE 3 - CONFIG AUDITOR
-- ---------------------------------------------------------------------
--  Reads your server's convars and scores them against known-good
--  values. It never writes anything unless you explicitly allow it.
-- ---------------------------------------------------------------------
Config.Auditor = {
    enabled = true,
    runAtStart = true,

    -- Wait this long (ms) after start before the first audit, so your
    -- server.cfg has definitely finished executing.
    startDelay = 20000,

    -- Re-run the audit automatically when one of the convars it actually
    -- audits changes at runtime. Changes to any other convar on your
    -- server are ignored. This is event driven and costs nothing while
    -- nothing changes.
    reactToConvarChanges = true,

    -- Minimum gap (ms) between automatic re-runs. Busy servers change
    -- convars constantly; without this the audit would re-run every few
    -- seconds. A re-run whose findings are identical to the last one is
    -- logged at debug level only, so your console stays quiet.
    minRerunInterval = 60000,

    -- DANGER. Allows the auditor to apply recommended values itself.
    -- Ships false and should stay false.
    --
    -- Note that even with this on, the three most important convars
    -- (onesync, onesync_population, sv_enforceGameBuild) CANNOT be
    -- changed at runtime by any script - the server engine marks them
    -- read-only or internal. Those will always be reported as
    -- "edit server.cfg yourself".
    allowAutoApply = false,

    -- Findings you have reviewed and are happy with. Use the key shown
    -- in the dashboard, which is normally just the convar name.
    suppress = {
        -- 'sv_scriptHookAllowed',
    },

    -- Override the recommended value for any convar. Whatever you put
    -- here wins over our recommendation.
    recommended = {
        -- ['sv_entityLockdown'] = 'strict',
    }
}

-- ---------------------------------------------------------------------
--  MODULE 4 - HITCH DETECTOR
-- ---------------------------------------------------------------------
--  Measures server stalls and records what was happening when they hit.
--
--  It draws on up to three sources, best first:
--    perf     - the server's own /perf metrics endpoint. Real measured
--               tick time for all three server threads. Most accurate.
--    console  - the server engine prints its own hitch warnings above
--               150ms (main thread) and 100ms (sync thread). We read
--               those. This is the only way to see sync thread stalls.
--    timer    - our own timer. Fills in smaller stalls the engine does
--               not report. Resolution is limited to 50ms, see below.
-- ---------------------------------------------------------------------
Config.Hitch = {
    enabled = true,

    sources = {
        perf = true,
        console = true,
        timer = true
    },

    perf = {
        -- How often (ms) to read the metrics endpoint.
        interval = 10000,

        -- Leave port at 0 to use your server's own port automatically.
        host = '127.0.0.1',
        port = 0
    },

    -- >>> THESE NUMBERS ARE PLACEHOLDERS. <<<
    -- They have NOT been calibrated against a live production server.
    -- They are starting points only. Watch your own hitch history for a
    -- week and then set them to something that means something on YOUR
    -- server, otherwise you will either get spammed or hear nothing.
    --
    -- Important context for choosing these: the FiveM server main thread
    -- runs at 20 ticks per second, so a healthy baseline gap between
    -- ticks is 50ms, not 16ms. Anything at or under about 60 is normal.
    thresholds = {
        minor = 90,
        major = 150,
        severe = 500
    },

    -- The sync thread runs at 120 ticks per second and is where OneSync
    -- entity work happens. A stall here is more serious than the same
    -- number on the main thread.
    syncThresholds = {
        minor = 60,
        major = 100,
        severe = 300
    },

    -- How many recent hitches to keep in memory.
    historySize = 250,

    -- How many all-time worst hitches to keep.
    worstCount = 20,

    -- Send a webhook at this severity and above. 'minor', 'major',
    -- 'severe', or false to never send one.
    webhookOn = 'severe',

    -- Minimum gap (ms) between hitch webhooks, so one bad minute does
    -- not send you fifty messages.
    webhookCooldown = 120000
}

-- ---------------------------------------------------------------------
--  MODULE 5 - RESOURCE ANALYZER
-- ---------------------------------------------------------------------
--  Reads the code of every installed resource looking for patterns that
--  commonly cause performance problems.
--
--  Two things this does NOT do:
--   * It never outputs, logs, webhooks or displays anyone's source code.
--     You get a file name, a line number and a pattern name. Never code.
--   * The risk score is an ESTIMATE from code patterns. It is not
--     measured CPU time. Nothing on the server can measure that live.
--     If you want real measured numbers, see Config.Profiler below.
--
--  Runs at startup and on demand only. Never on a loop.
-- ---------------------------------------------------------------------
Config.Analyzer = {
    enabled = true,
    runAtStart = true,

    -- Wait this long (ms) after start. Scanning every file on the server
    -- during boot is exactly the wrong moment to do it.
    startDelay = 45000,

    -- How many SCRIPT files to read per server frame. Keep this low -
    -- reading and scanning a Lua file is the expensive part, and the scan
    -- is slow on purpose so it never becomes the problem it is looking
    -- for.
    filesPerTick = 3,

    -- How many STREAM files to measure per server frame. These are far
    -- cheaper than script files - we only read the file size, never the
    -- contents - so this can be much higher. Without a separate budget a
    -- server with a lot of MLOs would take an hour to finish scanning.
    streamFilesPerTick = 250,

    -- Skip files larger than this many bytes. Minified bundles and
    -- generated data files produce noise, not findings.
    maxFileSize = 524288,

    -- Measure the size and file count of each resource's stream folder.
    -- On most struggling servers this is a top three finding.
    scanStreamWeight = true,

    -- Resources to skip entirely.
    ignoreResources = {
        'Dehz_ServerOptimizer'
    },

    -- Finding types to never report, anywhere. Valid names:
    --   busy_wait, wait_zero, thread_count, broadcast_event,
    --   netevent_no_source, deprecated_native, manifest
    ignoreFindings = {
        -- 'wait_zero',
    },

    -- How much each finding contributes to a resource's risk score.
    -- wait_zero is deliberately weighted low: on the SERVER a Wait(0)
    -- loop simply runs once per 50ms frame, and a Wait(0) loop that does
    -- nothing is cheaper than a Wait(500) loop that runs a database
    -- query. Counting them ranks code style, not cost.
    weights = {
        busy_wait = 30,
        wait_zero = 1,
        thread_count = 2,
        broadcast_event = 4,
        netevent_no_source = 8,
        deprecated_native = 2,
        manifest = 3,
        stream_weight = 1
    },

    -- How many lines to look ahead when checking whether a loop yields
    -- or whether an event handler uses 'source'. This is a heuristic and
    -- the dashboard labels it as one.
    blockScanLines = 250,

    -- Extra "this native is deprecated or superseded" patterns to look
    -- for, on top of the built in list. Plain text match, not a Lua
    -- pattern - what you type is what is searched for.
    extraPatterns = {
        -- { id = 'my_check', match = 'SomeOldNative(', label = 'superseded native', note = 'Use SomeNewNative instead.' },
    },

    -- Built in pattern ids you never want reported. The id is shown next
    -- to every finding in the dashboard.
    ignorePatterns = {
        -- 'get_player_ped_minus_one',
    }
}

-- ---------------------------------------------------------------------
--  MODULE 6 - STATE BAG MONITOR
-- ---------------------------------------------------------------------
--  Counts how often state bag keys are written to and flags the noisy
--  ones.
--
--  BE CLEAR ON WHAT THIS IS: it REPORTS spam, it does not PREVENT it.
--  The FiveM state bag change handler cannot reject or throttle a write.
--  That is a documented engine limitation, not a missing feature here.
--
--  This handler fires for every state bag write on your entire server.
--  It does almost nothing per call, but on a very busy server that is
--  still work. Turn it off once you have found your offender.
-- ---------------------------------------------------------------------
Config.StateBags = {
    enabled = true,

    -- Rolling window (ms) used to work out writes per second.
    window = 10000,

    -- Flag any key averaging more than this many writes per second.
    threshold = 20,

    -- How many keys to show in the dashboard.
    topKeys = 20,

    -- How often (ms) to evaluate the window and log anything over the
    -- threshold. Set to 0 to only report in the dashboard, never in
    -- console.
    reportInterval = 120000
}

-- ---------------------------------------------------------------------
--  MODULE 7 - NETWORK AND PLAYER MONITOR
-- ---------------------------------------------------------------------
Config.Network = {
    enabled = true,

    -- How often (ms) to sample. Per-player packet loss and ping only
    -- update every 10 seconds inside the engine, so there is no point
    -- sampling faster than that.
    sampleInterval = 30000,

    -- How many samples to keep. 240 at 30s is two hours.
    historySize = 240,

    -- Collect per-player packet loss and round trip time.
    peerStats = true
}

-- ---------------------------------------------------------------------
--  PROFILER  (optional, off by default)
-- ---------------------------------------------------------------------
--  This is the only part of the resource that produces REAL measured
--  per-resource millisecond figures on the server. It works by driving
--  the FiveM server's own built in profiler for a few seconds, then
--  reading the result back.
--
--  Understand the trade-off before enabling it:
--   * While recording, the server does extra work for every resource
--     tick and every event. It is a short sample, not a live monitor.
--   * Parsing the result is real work too. It is done in small chunks
--     to avoid causing a hitch, which means it takes a few seconds.
--   * Never run it during peak hours the first time. Test it on a quiet
--     server so you know what it costs you.
--
--  Everything here is deliberately conservative.
-- ---------------------------------------------------------------------
Config.Profiler = {
    enabled = false,

    -- How many server frames to record when no number is given.
    -- 60 frames at 20 ticks per second is 3 seconds.
    defaultFrames = 60,

    -- Refuse to record more than this many frames, ever.
    maxFrames = 200,

    -- Minimum gap (ms) between profile runs.
    cooldown = 300000,

    -- Refuse to run at all if more than this many players are online.
    -- Set to 0 to remove the limit (not advised).
    maxPlayersOnline = 32,

    -- Where the raw recording is written inside this resource.
    outputFile = 'data/profile.json',

    -- How many trace events to aggregate per server frame.
    parseChunk = 500,

    -- Refuse to read a recording larger than this many bytes. Decoding
    -- the JSON is one unavoidable blocking step, so a huge recording
    -- would itself cause the stall you are trying to measure. If you hit
    -- this, record fewer frames.
    maxFileBytes = 25165824
}

-- ---------------------------------------------------------------------
--  MODULE 9 - REPORTING
-- ---------------------------------------------------------------------
Config.Reporting = {

    -- Discord webhooks. Each module can go to its own channel. Leave a
    -- URL empty to send nothing for that module.
    webhooks = {
        general  = '',
        sweeper  = '',
        hitch    = '',
        auditor  = '',
        analyzer = '',
        statebags = ''
    },

    -- Name shown on the Discord messages.
    username = 'Dehz Optimizer',

    -- Left hand bar colour on the embeds, as a decimal number.
    -- Crimson (#C8102E).
    colour = 13111342,

    -- Minimum gap (ms) between any two webhook sends, across all
    -- modules. Protects you from Discord rate limits.
    minInterval = 2000,

    export = {
        -- Folder inside this resource where exported health reports go.
        directory = 'reports',

        -- How many exported reports to keep before the oldest is
        -- overwritten in the dashboard listing.
        keep = 10
    }
}

-- ---------------------------------------------------------------------
--  DATABASE  (optional)
-- ---------------------------------------------------------------------
--  Long term history. Everything works without this using in-memory
--  buffers - you just lose history across restarts.
--
--  Requires oxmysql. It is detected automatically; if it is not running
--  this whole section is ignored and the resource tells you once.
-- ---------------------------------------------------------------------
Config.Database = {
    enabled = false,

    -- Prefix for the tables this resource creates.
    tablePrefix = 'dehz_so_',

    -- Create the tables on first start if they do not exist.
    createTables = true,

    -- Delete stored rows older than this many days. 0 keeps forever.
    retentionDays = 14
}
