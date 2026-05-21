local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")
local DataStorage = require("datastorage")

-- 1. Safely load the config bypassing KOReader's internal require() paths
local config_path = require("ffi/util").joinPath(
    DataStorage:getDataDir(), 
    "plugins/emailtokoreader.koplugin/config.lua"
)

local config = {}
local config_ok, loaded_config = pcall(dofile, config_path)
if config_ok and loaded_config then
    config = loaded_config
else
    -- Safe fallbacks so the plugin doesn't crash if config.lua is missing
    config = {
        imap_server = "imap.gmail.com",
        imap_port = 993,
        use_ssl = true,
        download_path = "/mnt/us/documents/"
    }
end

-- 2. Load our local modules
local imap = require("imap")
local attachment = require("attachment")

local plugin = WidgetContainer:extend{
    name = "Email to KOReader",
    is_doc_only = false,
}

function plugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function plugin:addToMainMenu(menu_items)
    menu_items.emailtokoreader = {
        text = _("Email to KOReader"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Check Inbox"),
                callback = function()
                    self:checkInbox()
                end,
            },
        },
    }
end

function plugin:checkInbox()
    UIManager:show(InfoMessage:new{
        text = _("Checking inbox..."),
        timeout = 2,
    })

    UIManager:scheduleIn(0.5, function()
        local ok, result = pcall(function()
            return self:run_download()
        end)

        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("Error: ") .. tostring(result),
                timeout = 5,
            })
            return
        end

        UIManager:show(InfoMessage:new{
            text = _("Downloaded ") .. tostring(result) .. _(" book(s)"),
            timeout = 4,
        })
    end)
end

function plugin:run_download()
    local conn, err = imap.connect(config)
    if not conn then
        error("Connection failed: " .. tostring(err))
    end

    local ok = imap.login(conn, config.email, config.password)
    if not ok then
        pcall(function()
            conn:close()
        end)
        error("Login failed")
    end

    local success, result = pcall(function()
        local ids = imap.search_unseen(conn)
        local total_downloaded = 0

        local function tick_callback()
            UIManager:forceRePaint()
        end

        for _, id in ipairs(ids) do
            local stream_iter = imap.fetch_stream(conn, id)
            local downloaded = attachment.process_stream(stream_iter, config.download_path, tick_callback)
            total_downloaded = total_downloaded + downloaded
        end

        return total_downloaded
    end)

    pcall(function()
        imap.logout(conn)
    end)

    if not success then
        error(result)
    end

    return result
end

return plugin