-- Exercises decrypt.lua's libcrypto backend against real `openssl enc` output.
--
-- Not a busted spec: busted here runs on Lua 5.5, which has no FFI, so this
-- path is invisible to `busted`. Run it directly:
--     luajit test_decrypt_ffi.lua
-- test_decrypt_spec.lua covers the same surface through the CLI backend.

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.loaded["logger"] = {
    info = function() end, warn = function() end, dbg = function() end,
}

local Decrypt = assert(loadfile(_dir .. "decrypt.lua"))()

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("  ok   " .. name)
    else
        failed = failed + 1
        print("  FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

local KEY = [[p4ss'w0rd "with" $pecials & ;rm -rf /]]

local function write(path, data)
    local f = assert(io.open(path, "wb")); f:write(data); f:close()
end
local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local d = f:read("*all"); f:close(); return d
end

local function encrypt(plain, key)
    local pass_file, in_file, out_file = os.tmpname(), os.tmpname(), os.tmpname()
    write(pass_file, key)
    write(in_file, plain)
    local rc = os.execute(string.format(
        "openssl enc -aes-256-cbc -pbkdf2 -pass file:'%s' -in '%s' -out '%s' 2>/dev/null",
        pass_file, in_file, out_file))
    os.remove(pass_file); os.remove(in_file)
    assert(rc == 0 or rc == true, "openssl encryption failed")
    return out_file
end

print("backend: " .. tostring(Decrypt.backend()))
check("libcrypto is the backend", Decrypt.backend() == "libcrypto",
      "got " .. tostring(Decrypt.backend()))
check("available()", Decrypt.available())

-- A plaintext whose length is an exact multiple of the block size forces
-- openssl to append a whole block of padding; one byte short exercises the
-- ordinary case. Both must round-trip.
for _, case in ipairs({
    { "empty",            "" },
    { "one byte",         "x" },
    { "exactly 16 bytes", string.rep("A", 16) },
    { "15 bytes",         string.rep("A", 15) },
    { "17 bytes",         string.rep("A", 17) },
    { "utf-8 xml",        "<?xml version='1.0'?><feed>…ünïcödé…</feed>" },
    { "spans chunks",     string.rep("EPUB payload\n", 20000) },
}) do
    local name, plain = case[1], case[2]
    local enc = encrypt(plain, KEY)
    local got = Decrypt.data(read(enc), KEY)
    check("data() round-trips " .. name, got == plain,
          got and ("len " .. #got .. " vs " .. #plain) or "nil")
    os.remove(enc)
end

do
    local enc = encrypt("secret", KEY)
    check("data() rejects a wrong key", Decrypt.data(read(enc), "not the key") == nil)
    os.remove(enc)
end

do
    local plain = string.rep("EPUB payload\n", 20000)
    local enc = encrypt(plain, KEY)
    check("file() decrypts in place", Decrypt.file(enc, KEY))
    check("file() content matches", read(enc) == plain)
    os.remove(enc)
end

do
    local enc = encrypt("secret", KEY)
    local before = read(enc)
    check("file() rejects a wrong key", Decrypt.file(enc, "not the key") == false)
    check("file() leaves the original untouched", read(enc) == before)
    os.remove(enc)
end

do
    local dir = os.tmpname() .. ".d"
    os.execute("mkdir -p '" .. dir .. "'")
    local enc = encrypt("payload", KEY)
    local target = dir .. [[/it's $(whoami) `id` ;rm -rf x.epub]]
    write(target, read(enc)); os.remove(enc)
    check("file() handles shell metacharacters in the name", Decrypt.file(target, KEY))
    check("file() content matches", read(target) == "payload")
    local listing = io.popen("ls -A '" .. dir .. "'"):read("*all")
    check("file() leaves no temporary behind", listing:find("opdsdir%-decrypt") == nil, listing)
    os.execute("rm -rf '" .. dir .. "'")
end

do
    -- A catalogue can mix encrypted and plain books; a plain one must be left
    -- alone and reported as such, not as a failure.
    local plain_path = os.tmpname()
    write(plain_path, "PK\003\004 not encrypted at all")
    local ok, status = Decrypt.file(plain_path, KEY)
    check("file() reports a plain file as plaintext", ok == true and status == "plaintext",
          tostring(ok) .. "/" .. tostring(status))
    check("file() leaves a plain file untouched",
          read(plain_path) == "PK\003\004 not encrypted at all")
    os.remove(plain_path)

    local e2 = encrypt("payload", KEY)
    local _, st2 = Decrypt.file(e2, KEY)
    check("file() reports a decrypted file as decrypted", st2 == "decrypted", tostring(st2))
    os.remove(e2)

    local e3 = encrypt("payload", KEY)
    local _, st3 = Decrypt.file(e3, "wrong")
    check("file() reports a wrong key as failed", st3 == "failed", tostring(st3))
    os.remove(e3)
end

do
    local enc = encrypt("payload", KEY)
    local blob = read(enc)
    check("rejects a missing Salted__ header", Decrypt.data(blob:sub(9), KEY) == nil)
    check("rejects a truncated body", Decrypt.data(blob:sub(1, #blob - 3), KEY) == nil)
    os.remove(enc)
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
