local open = false
local settings = nil
local registered = false

local function setOpen(value)
    open = value
    SetNuiFocus(value, value)
    SendNUIMessage({ type = value and 'open' or 'close' })
end

RegisterNetEvent('dehz_so:client:init', function(data)
    if type(data) ~= 'table' then return end
    settings = data

    if registered then return end
    registered = true

    RegisterCommand('dehz_optimizer_open', function()
        TriggerServerEvent('dehz_so:request:open')
    end, false)

    if settings.keybind and settings.keybind.enabled then
        RegisterKeyMapping('dehz_optimizer_open', 'Open Server Optimizer', 'keyboard', settings.keybind.key or 'F7')
    end
end)

RegisterNetEvent('dehz_so:client:open', function(payload)
    if type(payload) ~= 'table' then return end
    setOpen(true)
    SendNUIMessage({ type = 'data', payload = payload })
end)

RegisterNetEvent('dehz_so:client:data', function(payload)
    if not open then return end
    if type(payload) ~= 'table' then return end
    SendNUIMessage({ type = 'data', payload = payload })
end)

RegisterNetEvent('dehz_so:client:action', function(result)
    if not open then return end
    SendNUIMessage({ type = 'action', payload = result })
end)

RegisterNUICallback('close', function(_, cb)
    setOpen(false)
    cb({ ok = true })
end)

RegisterNUICallback('refresh', function(data, cb)
    TriggerServerEvent('dehz_so:request:refresh', data and data.tab or 'overview', data and data.filters or nil)
    cb({ ok = true })
end)

RegisterNUICallback('action', function(data, cb)
    if type(data) == 'table' and type(data.action) == 'string' then
        TriggerServerEvent('dehz_so:action', data.action, data.params)
    end
    cb({ ok = true })
end)

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    TriggerServerEvent('dehz_so:client:ready')
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if open then setOpen(false) end
end)
