-- decrypt.lua -- AES-256-CBC decryption for OPDS catalogues and books.
--
-- Mirrors exactly what the server does (reading-pipeline,
-- scripts/update_catalog.py):
--     openssl enc -aes-256-cbc -pbkdf2 -k "$EPUB_ENCRYPT_KEY"
-- which means: the 8 bytes "Salted__", an 8-byte salt, then the ciphertext.
-- Key and IV come from PBKDF2-HMAC-SHA256 over 10000 iterations -- OpenSSL's
-- defaults for `enc -pbkdf2` -- producing 48 bytes, 32 of key and 16 of IV.
-- The plaintext is PKCS#7 padded.
--
-- There are two backends. KOReader bundles libcrypto and exposes it through
-- LuaJIT's FFI (see base/ffi/crypto.lua), so the work is done in-process:
-- no openssl binary to depend on, no temporary files, no shell command to
-- quote, and -- the part that actually mattered -- the passphrase never
-- touches the filesystem. The openssl CLI is kept as a fallback, because
-- ffi.loadlib pins a soname that a future KOReader could move.
--
-- This module is loaded by path from main.lua, never by `require`: its
-- dependency on sh.lua is resolved the same way, because a bare
-- `require("sh")` would land in the one global `package.loaded["sh"]` slot
-- that every other plugin on the device shares.

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local Sh = assert(loadfile(_dir .. "sh.lua"))()

local logger = require("logger")

local Decrypt = {}

local MAGIC      = "Salted__"
local HEADER_LEN = 16          -- magic + salt
local SALT_LEN   = 8
local BLOCK      = 16
local KEY_LEN    = 32
local IV_LEN     = 16
local ITERATIONS = 10000
local CHUNK      = 64 * 1024

-- os.execute reports success two different ways: LuaJIT (what KOReader runs)
-- returns the raw exit status, Lua 5.2+ returns ok, "exit", code. Accept both,
-- otherwise every command reads as failed under one of them.
local function succeeded(a, _, code)
    if type(a) == "number" then return a == 0 end
    return a == true and (code == nil or code == 0)
end

-- ---------------------------------------------------------------------------
-- libcrypto backend
-- ---------------------------------------------------------------------------

-- Declared one at a time on purpose. base/ffi/crypto_h.lua already declares
-- most of these, and it may be loaded before or after us (wpa_supplicant pulls
-- it in when Wi-Fi comes up), so a single cdef block would abort on the first
-- redefinition and leave the rest -- the three symbols that are genuinely
-- missing upstream -- undeclared.
local DECLS = {
    "typedef struct engine_st ENGINE;",
    "typedef struct evp_cipher_st EVP_CIPHER;",
    "typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;",
    "typedef struct evp_md_st EVP_MD;",
    "const EVP_CIPHER *EVP_aes_256_cbc(void);",
    "const EVP_MD *EVP_sha256(void);",
    "int PKCS5_PBKDF2_HMAC(const char *, int, const unsigned char *, int, int, const EVP_MD *, int, unsigned char *);",
    "EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);",
    "void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *);",
    "int EVP_CIPHER_CTX_set_padding(EVP_CIPHER_CTX *, int);",
    "int EVP_DecryptInit_ex(EVP_CIPHER_CTX *, const EVP_CIPHER *, ENGINE *, const unsigned char *, const unsigned char *);",
    "int EVP_DecryptUpdate(EVP_CIPHER_CTX *, unsigned char *, int *, const unsigned char *, int);",
    "int EVP_DecryptFinal_ex(EVP_CIPHER_CTX *, unsigned char *, int *);",
}

local ffi, C            -- nil until probed; C is false if unusable

local function load_crypto()
    if C ~= nil then return C end
    C = false

    local ok
    ok, ffi = pcall(require, "ffi")
    if not ok then
        logger.warn("opdsdir: no ffi, falling back to the openssl binary")
        return false
    end

    for _, decl in ipairs(DECLS) do
        pcall(ffi.cdef, decl)   -- already declared elsewhere is fine
    end

    local lib
    if ffi.loadlib then
        -- KOReader's loader takes a list of name/version candidates and falls
        -- back to the unversioned name.
        ok, lib = pcall(ffi.loadlib, "crypto", "57", "crypto", "3", "crypto")
    else
        ok, lib = pcall(ffi.load, "crypto")
    end
    if not ok or lib == nil then
        logger.warn("opdsdir: libcrypto not loadable, falling back to the openssl binary")
        return false
    end

    -- Resolving a symbol is what actually proves the library is the one we
    -- want; loading it only proves a file was found.
    if not pcall(function() return lib.EVP_aes_256_cbc() end) then
        logger.warn("opdsdir: libcrypto has no EVP_aes_256_cbc, falling back to the openssl binary")
        return false
    end

    C = lib
    return C
end

local function derive(pass, salt)
    local out = ffi.new("unsigned char[?]", KEY_LEN + IV_LEN)
    local ok = C.PKCS5_PBKDF2_HMAC(pass, #pass, salt, SALT_LEN, ITERATIONS,
                                   C.EVP_sha256(), KEY_LEN + IV_LEN, out)
    if ok ~= 1 then return nil end
    return ffi.string(out, KEY_LEN), ffi.string(out + KEY_LEN, IV_LEN)
end

-- Strip and validate PKCS#7 padding from the final block. Checking every
-- padding byte, not just the length, is what makes a wrong key fail loudly:
-- decryption with the wrong key produces a block that almost never carries
-- valid padding.
local function unpad(block)
    if #block ~= BLOCK then return nil end
    local n = block:byte(BLOCK)
    if n < 1 or n > BLOCK then return nil end
    for i = BLOCK - n + 1, BLOCK do
        if block:byte(i) ~= n then return nil end
    end
    return block:sub(1, BLOCK - n)
end

-- Streams `read` through libcrypto into `write`. read(n) returns up to n bytes
-- or nil at end of input. Returns true on success.
--
-- Padding is handled here rather than by OpenSSL so that the last block can be
-- held back: with it disabled, EVP produces exactly as many bytes as it
-- consumes, so the tail is always the final block and memory stays bounded by
-- CHUNK whatever the size of the book.
local function ffi_decrypt(read, write, key)
    local header = read(HEADER_LEN)
    if not header or #header < HEADER_LEN or header:sub(1, #MAGIC) ~= MAGIC then
        return false
    end

    local k, iv = derive(key, header:sub(#MAGIC + 1, HEADER_LEN))
    if not k then return false end

    local ctx = C.EVP_CIPHER_CTX_new()
    if ctx == nil then return false end
    local function done(ok)
        C.EVP_CIPHER_CTX_free(ctx)
        return ok
    end

    if C.EVP_DecryptInit_ex(ctx, C.EVP_aes_256_cbc(), nil, k, iv) ~= 1 then
        return done(false)
    end
    if C.EVP_CIPHER_CTX_set_padding(ctx, 0) ~= 1 then return done(false) end

    local buf     = ffi.new("unsigned char[?]", CHUNK + BLOCK)
    local buf_len = ffi.new("int[1]")
    local pending = ""

    while true do
        local chunk = read(CHUNK)
        if not chunk or #chunk == 0 then break end
        if C.EVP_DecryptUpdate(ctx, buf, buf_len, chunk, #chunk) ~= 1 then
            return done(false)
        end
        if buf_len[0] > 0 then
            pending = pending .. ffi.string(buf, buf_len[0])
            if #pending > BLOCK then
                write(pending:sub(1, #pending - BLOCK))
                pending = pending:sub(#pending - BLOCK + 1)
            end
        end
    end

    -- Fails when the ciphertext is not a whole number of blocks, which is what
    -- a truncated download looks like.
    if C.EVP_DecryptFinal_ex(ctx, buf, buf_len) ~= 1 then return done(false) end
    if buf_len[0] > 0 then pending = pending .. ffi.string(buf, buf_len[0]) end

    local tail = unpad(pending)
    if not tail then return done(false) end
    if #tail > 0 then write(tail) end
    return done(true)
end

-- ---------------------------------------------------------------------------
-- openssl CLI backend
-- ---------------------------------------------------------------------------

local have_cli

local function cli_available()
    if have_cli == nil then
        have_cli = succeeded(os.execute("command -v openssl >/dev/null 2>&1"))
    end
    return have_cli
end

-- The key goes through a temp file rather than the command line, where it
-- would be visible to anything that can read /proc. Every path is quoted: the
-- catalogue picks the local filename, so it is untrusted input.
local function cli_run(key, in_path, out_path)
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

-- ---------------------------------------------------------------------------
-- Public interface
-- ---------------------------------------------------------------------------

-- "libcrypto", "openssl" or nil when neither is usable.
function Decrypt.backend()
    if load_crypto() then return "libcrypto" end
    if cli_available() then return "openssl" end
    return nil
end

function Decrypt.available()
    local b = Decrypt.backend()
    if not b then
        logger.warn("opdsdir: no libcrypto and no openssl binary, decryption unavailable")
    end
    return b ~= nil
end

-- Decrypt `path` in place. Returns true on success; on failure the original
-- file is left untouched.
function Decrypt.file(path, key)
    local backend = Decrypt.backend()
    if not backend then return false end

    -- A fixed short name in the same directory, rather than path .. ".dec":
    -- KOReader already allows filenames up to 240 characters, so a suffix can
    -- push the temporary past the 255-character limit on VFAT and the write
    -- fails for a reason that looks like a bad key.
    local dir = path:match("^(.*)/[^/]*$") or "."
    local tmp = dir .. "/.opdsdir-decrypt.tmp"

    local ok = false
    if backend == "libcrypto" then
        local fin = io.open(path, "rb")
        if fin then
            local fout = io.open(tmp, "wb")
            if fout then
                ok = ffi_decrypt(function(n) return fin:read(n) end,
                                 function(s) fout:write(s) end, key)
                fout:close()
            end
            fin:close()
        end
    else
        ok = cli_run(key, path, tmp)
    end

    if ok then
        os.remove(path)
        if os.rename(tmp, path) then
            logger.info("opdsdir: decrypted", path, "via", backend)
            return true
        end
        logger.warn("opdsdir: could not replace", path)
    end
    os.remove(tmp)
    logger.warn("opdsdir: decryption failed for", path)
    return false
end

-- Decrypt an in-memory string (the catalogue XML). Returns nil on failure, so
-- the caller can tell "decrypted to empty" from "could not decrypt".
function Decrypt.data(blob, key)
    local backend = Decrypt.backend()
    if not backend then return nil end

    local result
    if backend == "libcrypto" then
        local pos, parts = 1, {}
        local ok = ffi_decrypt(
            function(n)
                if pos > #blob then return nil end
                local s = blob:sub(pos, pos + n - 1)
                pos = pos + #s
                return s
            end,
            function(s) parts[#parts + 1] = s end,
            key)
        if ok then result = table.concat(parts) end
    else
        local in_path, out_path = os.tmpname(), os.tmpname()
        local f = io.open(in_path, "wb")
        if f then
            f:write(blob)
            f:close()
            if cli_run(key, in_path, out_path) then
                local g = io.open(out_path, "rb")
                if g then
                    result = g:read("*all")
                    g:close()
                end
            end
        end
        os.remove(in_path)
        os.remove(out_path)
    end

    if not result then logger.warn("opdsdir: catalog decryption failed") end
    return result
end

return Decrypt
