local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. package.path

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local ButtonDialog      = require("ui/widget/buttondialog")
local ConfirmBox        = require("ui/widget/confirmbox")
local InputDialog       = require("ui/widget/inputdialog")
local NetworkMgr        = require("ui/network/manager")
local UIManager         = require("ui/uimanager")
local WidgetContainer   = require("ui/widget/container/widgetcontainer")
local logger            = require("logger")
local _                 = require("i18n")

require("i18n").extend(lrequire("i18n_fr"))

local OpdsDirPlugin = WidgetContainer:extend{
    name        = "opdsdir",
    is_doc_only = false,
}

-- Decrypt path in-place using openssl. Key is written to a temp file to
-- avoid shell injection. Returns true on success.
local function decrypt_inplace(path, key)
    local key_file = os.tmpname()
    local f = io.open(key_file, "w")
    if not f then return false end
    f:write(key)
    f:close()

    local tmp = path .. ".dec"
    local cmd = string.format(
        "openssl enc -aes-256-cbc -pbkdf2 -d -pass file:'%s' -in '%s' -out '%s' 2>/dev/null",
        key_file, path, tmp
    )
    local ok = os.execute(cmd) == 0
    os.remove(key_file)

    if ok then
        os.execute(string.format("mv '%s' '%s'", tmp, path))
        logger.info("opdsdir: decrypted", path)
    else
        os.execute(string.format("rm -f '%s'", tmp))
        logger.warn("opdsdir: decryption failed for", path)
    end
    return ok
end

function OpdsDirPlugin:init()
    local ok, OPDSBrowser = pcall(require, "plugins/opds.koplugin/opdsbrowser")
    if not ok then
        OPDSBrowser = package.loaded["plugins/opds.koplugin/opdsbrowser"]
            or package.loaded["opdsbrowser"]
        if not OPDSBrowser then
            logger.warn("opdsdir: opdsbrowser not found, skipping patch")
            return
        end
    end

    -- 1. Prioritise per-catalog download_dir over the global setting
    local orig_getDir = OPDSBrowser.getCurrentDownloadDir
    OPDSBrowser.getCurrentDownloadDir = function(self)
        if self.root_catalog_download_dir and self.root_catalog_download_dir ~= "" then
            return self.root_catalog_download_dir
        end
        return orig_getDir(self)
    end

    -- 2. Capture per-catalog settings when the user taps a root catalog
    local orig_onMenuSelect = OPDSBrowser.onMenuSelect
    OPDSBrowser.onMenuSelect = function(self, item)
        if #self.paths == 0
            and item.idx ~= 1
            and not (item.acquisitions and item.acquisitions[1])
        then
            local server = self.servers[item.idx - 1]
            self.root_catalog_download_dir  = server and server.download_dir  or nil
            self.root_catalog_encrypt_key   = server and server.encrypt_key   or nil
        end
        return orig_onMenuSelect(self, item)
    end

    -- 3. Decrypt encrypted OPDS catalog (catalog.xml.enc) before parsing
    local orig_fetchFeed = OPDSBrowser.fetchFeed
    OPDSBrowser.fetchFeed = function(self, item_url, headers_only)
        local data = orig_fetchFeed(self, item_url, headers_only)
        local key = self.root_catalog_encrypt_key
        if data and key and key ~= "" and item_url:match("%.enc$") then
            local enc_file = os.tmpname()
            local dec_file = os.tmpname()
            local key_file = os.tmpname()

            local fe = io.open(enc_file, "wb")
            if fe then
                fe:write(data)
                fe:close()
                local fk = io.open(key_file, "w")
                if fk then
                    fk:write(key)
                    fk:close()
                    local cmd = string.format(
                        "openssl enc -aes-256-cbc -pbkdf2 -d -pass file:'%s' -in '%s' -out '%s' 2>/dev/null",
                        key_file, enc_file, dec_file
                    )
                    if os.execute(cmd) == 0 then
                        local fd = io.open(dec_file, "r")
                        if fd then
                            data = fd:read("*all")
                            fd:close()
                            logger.info("opdsdir: catalog decrypted")
                        end
                    else
                        logger.warn("opdsdir: catalog decryption failed")
                    end
                    os.remove(key_file)
                end
                os.remove(enc_file)
                os.remove(dec_file)
            end
        end
        return data
    end

    -- 4. Decrypt downloaded file if catalog has an encryption key
    local orig_downloadFile = OPDSBrowser.downloadFile
    OPDSBrowser.downloadFile = function(self, local_path, remote_url, username, password, caller_callback)
        local key = self.root_catalog_encrypt_key
        if key and key ~= "" then
            local wrapped = function(path)
                decrypt_inplace(path, key)
                if caller_callback then caller_callback(path) end
            end
            return orig_downloadFile(self, local_path, remote_url, username, password, wrapped)
        end
        return orig_downloadFile(self, local_path, remote_url, username, password, caller_callback)
    end

    -- 4. Long-press context menu: Download directory + Encryption key buttons.
    --    NOTE: replaces onMenuHold — sync manually if KOReader adds buttons there.
    OPDSBrowser.onMenuHold = function(self, item)
        if #self.paths > 0 or item.idx == 1 then return true end

        local server      = self.servers[item.idx - 1]
        local current_dir = server and server.download_dir or nil
        local has_key     = server and server.encrypt_key and server.encrypt_key ~= ""

        local dir_label = current_dir
            and ("\u{f07b} " .. current_dir)
            or  _("Set download directory")
        local key_label = has_key
            and ("\u{f084} " .. string.rep("•", 8))
            or  _("Set encryption key")

        local function pick_dir()
            require("ui/downloadmgr"):new{
                onConfirm = function(path)
                    if server then
                        server.download_dir = path
                        self._manager.updated = true
                    end
                end,
            }:chooseDir()
        end

        local function pick_key()
            local key_dialog
            key_dialog = InputDialog:new{
                title       = _("Encryption key"),
                description = _("Passphrase used to decrypt downloaded EPUBs."),
                input       = (server and server.encrypt_key) or "",
                text_type   = "password",
                buttons     = {{
                    {
                        text = _("Cancel"),
                        id   = "close",
                        callback = function() UIManager:close(key_dialog) end,
                    },
                    {
                        text = _("Clear"),
                        callback = function()
                            if server then
                                server.encrypt_key = nil
                                self._manager.updated = true
                            end
                            UIManager:close(key_dialog)
                        end,
                    },
                    {
                        text             = _("Save"),
                        is_enter_default = true,
                        callback         = function()
                            local k = key_dialog:getInputText()
                            if server then
                                server.encrypt_key = k ~= "" and k or nil
                                self._manager.updated = true
                            end
                            UIManager:close(key_dialog)
                        end,
                    },
                }},
            }
            UIManager:show(key_dialog)
            key_dialog:onShowKeyboard()
        end

        local dialog
        dialog = ButtonDialog:new{
            title       = item.text,
            title_align = "center",
            buttons = {
                {
                    {
                        text = _("Force sync"),
                        callback = function()
                            UIManager:close(dialog)
                            NetworkMgr:runWhenConnected(function()
                                self.sync_force = true
                                self:checkSyncDownload(item.idx)
                            end)
                        end,
                    },
                    {
                        text = _("Sync"),
                        callback = function()
                            UIManager:close(dialog)
                            NetworkMgr:runWhenConnected(function()
                                self.sync_force = false
                                self:checkSyncDownload(item.idx)
                            end)
                        end,
                    },
                },
                {
                    {
                        text = dir_label,
                        callback = function()
                            UIManager:close(dialog)
                            pick_dir()
                        end,
                    },
                    {
                        text = key_label,
                        callback = function()
                            UIManager:close(dialog)
                            pick_key()
                        end,
                    },
                },
                {},
                {
                    {
                        text = _("Delete"),
                        callback = function()
                            UIManager:show(ConfirmBox:new{
                                text        = _("Delete OPDS catalog?"),
                                ok_text     = _("Delete"),
                                ok_callback = function()
                                    UIManager:close(dialog)
                                    self:deleteCatalog(item)
                                end,
                            })
                        end,
                    },
                    {
                        text = _("Edit"),
                        callback = function()
                            UIManager:close(dialog)
                            self:addEditCatalog(item)
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
        return true
    end

    logger.info("opdsdir: patch applied (download directory + full encryption)")
end

return OpdsDirPlugin
