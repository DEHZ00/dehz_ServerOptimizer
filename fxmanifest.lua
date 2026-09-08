fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'Dehz_ServerOptimizer'
author 'Dehz Development'
description 'Server-side performance diagnostic and cleanup suite'
version '1.0.0'

shared_script 'shared/constants.lua'

server_scripts {
    'config.lua',
    'server/core/log.lua',
    'server/core/util.lua',
    'server/core/state.lua',
    'server/core/caps.lua',
    'server/bridge/framework.lua',
    'server/data/convars.lua',
    'server/data/patterns.lua',
    'server/report/webhook.lua',
    'server/report/persist.lua',
    'server/modules/entities.lua',
    'server/modules/sweeper.lua',
    'server/modules/culling.lua',
    'server/modules/auditor.lua',
    'server/modules/hitch.lua',
    'server/modules/analyzer.lua',
    'server/modules/statebags.lua',
    'server/modules/network.lua',
    'server/modules/profiler.lua',
    'server/report/export.lua',
    'server/api/exports.lua',
    'server/nui/server.lua',
    'server/core/diagnose.lua',
    'server/core/boot.lua'
}

client_script 'client/nui.lua'

ui_page 'web/index.html'

files {
    'web/index.html',
    'web/style.css',
    'web/app.js'
}
