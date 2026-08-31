local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local DownloadMgr = require("ui/downloadmgr")
local Dispatcher = require("dispatcher")
local NetworkMgr = require("ui/network/manager")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
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

-- Used when neither the UI settings nor config.lua provide a value
local DEFAULT_EXTENSIONS = {"epub"}
-- Extensions always offered in the menu; anything configured elsewhere is added on top
local MENU_EXTENSIONS = {"epub", "acsm", "pdf", "mobi", "cbz"}

local plugin = WidgetContainer:extend{
    name = "Email to KOReader",
    is_doc_only = false,
}

function plugin:init()
    -- Lives in KOReader's settings dir, so it survives plugin updates
    self.settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/emailtokoreader.lua"
    )
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

-- Makes "Check Inbox" assignable to gestures, keys, profiles and the QuickMenu
function plugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("emailtokoreader_check_inbox", {
        category = "none",
        event = "EmailToKOReaderCheckInbox",
        title = _("Email to KOReader: check inbox"),
        general = true,
    })
end

function plugin:onEmailToKOReaderCheckInbox()
    self:checkInbox()
    return true
end

-- Precedence for both settings: menu choice > config.lua > built-in default
function plugin:getDownloadPath()
    return self.settings:readSetting("download_path")
        or config.download_path
        or "/mnt/us/documents/"
end

function plugin:getAllowedExtensions()
    return self.settings:readSetting("allowed_extensions")
        or config.allowed_extensions
        or DEFAULT_EXTENSIONS
end

local function normalize_extension(ext)
    return tostring(ext):lower():match("^%.?(.+)$")
end

function plugin:isExtensionEnabled(ext)
    for _, e in ipairs(self:getAllowedExtensions()) do
        if normalize_extension(e) == ext then return true end
    end
    return false
end

function plugin:toggleExtension(ext)
    local updated = {}
    local was_enabled = false

    for _, e in ipairs(self:getAllowedExtensions()) do
        if normalize_extension(e) == ext then
            was_enabled = true
        else
            table.insert(updated, normalize_extension(e))
        end
    end

    if not was_enabled then
        table.insert(updated, ext)
    end

    self.settings:saveSetting("allowed_extensions", updated)
    self.settings:flush()
end

function plugin:genExtensionMenu()
    local items = {}
    local seen = {}

    local function add(raw_ext)
        local ext = normalize_extension(raw_ext)
        if ext and not seen[ext] then
            seen[ext] = true
            table.insert(items, {
                text = "." .. ext,
                keep_menu_open = true,
                checked_func = function()
                    return self:isExtensionEnabled(ext)
                end,
                callback = function()
                    self:toggleExtension(ext)
                end,
            })
        end
    end

    for _, ext in ipairs(MENU_EXTENSIONS) do add(ext) end
    -- Show extensions that only exist in config.lua so they can be switched off too
    for _, ext in ipairs(self:getAllowedExtensions()) do add(ext) end

    return items
end

function plugin:chooseDownloadFolder()
    local start_path = self:getDownloadPath()
    -- PathChooser falls back to the last used directory when given nil
    if not lfs.attributes(start_path, "mode") then
        start_path = nil
    end

    DownloadMgr:new{
        title = _("Choose download folder"),
        onConfirm = function(path)
            self.settings:saveSetting("download_path", path)
            self.settings:flush()
            UIManager:show(InfoMessage:new{
                text = _("Download folder set to:\n") .. path,
                timeout = 3,
            })
        end,
    }:chooseDir(start_path)
end

function plugin:addToMainMenu(menu_items)
    menu_items.emailtokoreader = {
        text = _("Email to KOReader"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Check Inbox"),
                separator = true,
                callback = function()
                    self:checkInbox()
                end,
            },
            {
                text_func = function()
                    return _("Download folder: ") .. self:getDownloadPath()
                end,
                keep_menu_open = true,
                callback = function()
                    self:chooseDownloadFolder()
                end,
            },
            {
                text = _("File extensions"),
                sub_item_table = self:genExtensionMenu(),
            },
        },
    }
end

function plugin:checkInbox()
    if #self:getAllowedExtensions() == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No file extensions selected."),
            timeout = 4,
        })
        return
    end

    -- Offer to turn Wi-Fi on instead of failing with a DNS error later.
    -- Returns true while still offline; we then re-enter once the device is online.
    if NetworkMgr:willRerunWhenOnline(function() self:checkInbox() end) then
        return
    end

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

    local download_path = self:getDownloadPath()
    local allowed_extensions = self:getAllowedExtensions()

    local success, result = pcall(function()
        local ids = imap.search_unseen(conn)
        local total_downloaded = 0

        local function tick_callback()
            UIManager:forceRePaint()
        end

        for _, id in ipairs(ids) do
            local stream_iter = imap.fetch_stream(conn, id)
            local downloaded = attachment.process_stream(stream_iter, download_path, tick_callback,
                allowed_extensions)
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