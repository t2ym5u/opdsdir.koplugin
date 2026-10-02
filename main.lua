local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. package.path

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local BD                = require("ui/bidi")
local ButtonDialog      = require("ui/widget/buttondialog")
local ConfirmBox        = require("ui/widget/confirmbox")
local InfoMessage       = require("ui/widget/infomessage")
local InputDialog       = require("ui/widget/inputdialog")
local NetworkMgr        = require("ui/network/manager")
local UIManager         = require("ui/uimanager")
local WidgetContainer   = require("ui/widget/container/widgetcontainer")
local logger            = require("logger")
local T                 = require("ffi/util").template

-- lrequire, not require: `package.loaded["i18n"]` is a single slot shared by
-- every plugin on the device, and the first one loaded wins it. This plugin
-- is not part of the game-common family, so taking that slot -- or being
-- handed someone else's module and merging our strings into their table --
-- is how our "Clear" ends up overwriting theirs.
local Decrypt = lrequire("decrypt")
local i18n    = lrequire("i18n")
local _       = i18n

i18n.extend(lrequire("i18n_fr"))

local OpdsDirPlugin = WidgetContainer:extend{
    name        = "opdsdir",
    is_doc_only = false,
}

-- ReaderUI and FileManager each build their own plugin instance, and they are
-- rebuilt every time a document is opened or closed. Without this the patches
-- below wrap the already-wrapped functions again on every single one.
local patched = false

local function warn(text)
    UIManager:show(InfoMessage:new{ text = text, icon = "notice-warning" })
end

function OpdsDirPlugin:init()
    if patched then return end

    local ok, OPDSBrowser = pcall(require, "plugins/opds.koplugin/opdsbrowser")
    if not ok then
        OPDSBrowser = package.loaded["plugins/opds.koplugin/opdsbrowser"]
            or package.loaded["opdsbrowser"]
        if not OPDSBrowser then
            logger.warn("opdsdir: opdsbrowser not found, skipping patch")
            return -- leave `patched` false so a later instance can retry
        end
    end

    -- 1. Prioritise the per-catalog download_dir over the global setting.
    --    This deliberately wins over the sync folder too: a catalog with a
    --    folder of its own should sync into it. Catalogs without one keep
    --    falling through to sync_dir, because patch 5 clears the field.
    local orig_getDir = OPDSBrowser.getCurrentDownloadDir
    OPDSBrowser.getCurrentDownloadDir = function(self)
        local dir = self.root_catalog_download_dir
        if dir and dir ~= "" then return dir end
        return orig_getDir(self)
    end

    -- 2. Capture the per-catalog settings when the user taps a root catalog
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

    -- 3. Decrypt an encrypted OPDS catalog (catalog.xml.enc) before parsing.
    --    The query string is stripped first: `catalog.xml.enc?v=2` is still
    --    an encrypted catalog.
    local orig_fetchFeed = OPDSBrowser.fetchFeed
    OPDSBrowser.fetchFeed = function(self, item_url, headers_only)
        local data = orig_fetchFeed(self, item_url, headers_only)
        local key = self.root_catalog_encrypt_key
        if data and key and key ~= ""
            and item_url:gsub("[?#].*$", ""):match("%.enc$")
        then
            local plain = Decrypt.data(data, key)
            if plain then
                logger.info("opdsdir: catalog decrypted")
                return plain
            end
            -- Returning the ciphertext would get parsed as XML and surface as
            -- an empty catalog, which says nothing about what went wrong.
            warn(Decrypt.available()
                and _("Could not decrypt this catalog. Check its encryption key.")
                or  _("This catalog is encrypted, but this device cannot decrypt it."))
            return nil
        end
        return data
    end

    -- 4. Decrypt a downloaded file if its catalog has an encryption key.
    local orig_downloadFile = OPDSBrowser.downloadFile
    OPDSBrowser.downloadFile = function(self, local_path, remote_url, username, password, caller_callback)
        -- During a sync, root_catalog_encrypt_key has already moved on to the
        -- last catalog filled, so the key is looked up by destination path
        -- (see patch 5) before falling back to the browsing case.
        local key = (self.opdsdir_sync_keys and self.opdsdir_sync_keys[local_path])
            or self.root_catalog_encrypt_key
        if key and key ~= "" then
            local wrapped = function(path)
                -- A catalog can mix encrypted and plain books, so "nothing to
                -- decrypt" is a normal outcome and only "failed" is worth a
                -- message.
                local _ok, status = Decrypt.file(path, key)
                if status == "failed" then
                    warn(T(_("Could not decrypt:\n%1\n\nCheck the catalog's encryption key."),
                        BD.filepath(path)))
                end
                if caller_callback then caller_callback(path) end
            end
            return orig_downloadFile(self, local_path, remote_url, username, password, wrapped)
        end
        return orig_downloadFile(self, local_path, remote_url, username, password, caller_callback)
    end

    -- 5. Sync never goes through onMenuSelect: fillPendingSyncs sets the
    --    per-catalog username/password/title itself and knows nothing about
    --    our two fields. Left alone, "Sync all catalogs" downloads every
    --    catalog into the folder of whichever one was opened last and
    --    decrypts it with that one's key.
    local orig_fillPendingSyncs = OPDSBrowser.fillPendingSyncs
    OPDSBrowser.fillPendingSyncs = function(self, server)
        self.root_catalog_download_dir = server and server.download_dir or nil
        self.root_catalog_encrypt_key  = server and server.encrypt_key  or nil

        local pending = self.pending_syncs or {}
        local first_new = #pending + 1
        if first_new == 1 then self.opdsdir_sync_keys = {} end

        local ret = orig_fillPendingSyncs(self, server)

        -- The download paths were just computed with this catalog's folder;
        -- remember which key each of them needs before the next catalog
        -- overwrites root_catalog_encrypt_key.
        local key = self.root_catalog_encrypt_key
        if key and key ~= "" then
            self.opdsdir_sync_keys = self.opdsdir_sync_keys or {}
            for i = first_new, #(self.pending_syncs or {}) do
                local entry = self.pending_syncs[i]
                if entry and entry.file then
                    self.opdsdir_sync_keys[entry.file] = key
                end
            end
        end
        return ret
    end

    -- 6. The Edit dialog rebuilds the server entry from the six fields it
    --    shows and assigns it over the old one, so editing a catalog to fix a
    --    typo silently dropped both of our fields. Carry them over.
    local orig_editCatalogFromInput = OPDSBrowser.editCatalogFromInput
    OPDSBrowser.editCatalogFromInput = function(self, fields, item, no_refresh)
        local old = item and self.servers[item.idx - 1]
        local dir = old and old.download_dir
        local key = old and old.encrypt_key

        local ret = orig_editCatalogFromInput(self, fields, item, no_refresh)

        if item then
            local new = self.servers[item.idx - 1]
            if new then
                new.download_dir = dir
                new.encrypt_key  = key
            end
        end
        return ret
    end

    -- 7. Long-press context menu: Download directory + Encryption key buttons.
    --    NOTE: replaces onMenuHold -- sync manually if KOReader adds buttons there.
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

        local function clear_dir()
            if server and server.download_dir then
                server.download_dir = nil
                self._manager.updated = true
                UIManager:show(InfoMessage:new{
                    text = _("Download directory cleared."),
                    timeout = 2,
                })
            end
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
                        -- long-press to go back to the global download folder
                        hold_callback = function()
                            UIManager:close(dialog)
                            clear_dir()
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

    patched = true
    logger.info("opdsdir: patch applied (download directory + full encryption)")
end

return OpdsDirPlugin
