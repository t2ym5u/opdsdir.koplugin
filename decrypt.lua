-- decrypt.lua -- AES-256-CBC decryption for OPDS catalogues and books.
--
-- Mirrors exactly what the server does (reading-pipeline,
-- scripts/update_catalog.py):
--     openssl enc -aes-256-cbc -pbkdf2 -k "$EPUB_ENCRYPT_KEY"
-- i.e. a "Salted__" header, an 8-byte salt, then PBKDF2-HMAC-SHA256 over
-- 10000 iterations deriving 32 bytes of key and 16 of IV.
--
-- Shelling out to the openssl CLI is what this does today. It lives in its
-- own module so the libcrypto/FFI backend can replace it without any caller
-- in main.lua changing.
--
-- This module is loaded by path from main.lua, never by `require`: its
-- dependency on sh.lua is resolved the same way, because a bare
-- `require("sh")` would land in the one global `package.loaded["sh"]` slot
-- that every other plugin on the device shares.

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local Sh = assert(loadfile(_dir .. "sh.lua"))()

local logger = require("logger")

local Decrypt = {}

-- os.execute reports success two different ways: LuaJIT (what KOReader runs)
-- returns the raw exit status, Lua 5.2+ returns ok, "exit", code. Accept both,
-- otherwise every command reads as failed under one of them.
local function succeeded(a, _, code)
    if type(a) == "number" then return a == 0 end
    return a == true and (code == nil or code == 0)
end

-- Probed once, lazily: nothing guarantees an openssl binary on the device,
-- and without this every decryption just fails with no explanation.
local have_openssl
function Decrypt.available()
    if have_openssl == nil then
        have_openssl = succeeded(os.execute("command -v openssl >/dev/null 2>&1"))
        if not have_openssl then
            logger.warn("opdsdir: no openssl binary, decryption unavailable")
        end
    end
    return have_openssl
end

-- The key goes through a temp file rather than the command line, where it
-- would be visible to anything that can read /proc. Every path is quoted:
-- the catalogue picks the local filename, so it is untrusted input.
local function run(key, in_path, out_path)
    local key_file = os.tmpname()
    local f = io.open(key_file, "w")
    if not f then return false end
    f:write(key)
    f:close()

    local ok = succeeded(os.execute(string.format(
        "openssl enc -aes-256-cbc -pbkdf2 -d -pass file:%s -in %s -out %s 2>/dev/null",
        Sh.quote(key_file), Sh.quote(in_path), Sh.quote(out_path)
    )))

    os.remove(key_file)
    return ok
end

-- Decrypt `path` in place. Returns true on success; on failure the original
-- file is left untouched.
function Decrypt.file(path, key)
    if not Decrypt.available() then return false end

    -- A fixed short name in the same directory, rather than path .. ".dec":
    -- KOReader already allows filenames up to 240 characters, so a suffix can
    -- push the temporary past the 255-character limit on VFAT and the write
    -- fails for a reason that looks like a bad key.
    local dir = path:match("^(.*)/[^/]*$") or "."
    local tmp = dir .. "/.opdsdir-decrypt.tmp"

    if run(key, path, tmp) then
        os.remove(path)
        if os.rename(tmp, path) then
            logger.info("opdsdir: decrypted", path)
            return true
        end
        logger.warn("opdsdir: could not replace", path)
    end
    os.remove(tmp)
    logger.warn("opdsdir: decryption failed for", path)
    return false
end

-- Decrypt an in-memory string (the catalogue XML). Returns nil on failure,
-- so the caller can tell "decrypted to empty" from "could not decrypt".
function Decrypt.data(data, key)
    if not Decrypt.available() then return nil end

    local in_path, out_path = os.tmpname(), os.tmpname()
    local result
    local f = io.open(in_path, "wb")
    if f then
        f:write(data)
        f:close()
        if run(key, in_path, out_path) then
            local g = io.open(out_path, "rb")
            if g then
                result = g:read("*all")
                g:close()
            end
        end
    end
    os.remove(in_path)
    os.remove(out_path)

    if not result then logger.warn("opdsdir: catalog decryption failed") end
    return result
end

return Decrypt
