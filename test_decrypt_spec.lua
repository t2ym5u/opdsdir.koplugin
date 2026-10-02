-- Round-trips real openssl output through decrypt.lua, so the plugin's
-- reader stays pinned to what the server actually writes:
--     openssl enc -aes-256-cbc -pbkdf2 -k "$EPUB_ENCRYPT_KEY"

package.loaded["logger"] = { info = function() end, warn = function() end, dbg = function() end }

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local Decrypt = assert(loadfile(_dir .. "decrypt.lua"))()

-- Same two os.execute conventions the module itself has to cope with.
local function succeeded(a, _, code)
    if type(a) == "number" then return a == 0 end
    return a == true and (code == nil or code == 0)
end

local KEY = [[p4ss'w0rd "with" $pecials & ;rm -rf /]]

local function tmp() return os.tmpname() end

local function write(path, data)
    local f = assert(io.open(path, "wb")); f:write(data); f:close()
end

local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local d = f:read("*all"); f:close(); return d
end

local function encrypt(plain, key)
    local pass_file, in_file, out_file = tmp(), tmp(), tmp()
    write(pass_file, key)
    write(in_file, plain)
    local ok = succeeded(os.execute(string.format(
        "openssl enc -aes-256-cbc -pbkdf2 -pass file:'%s' -in '%s' -out '%s' 2>/dev/null",
        pass_file, in_file, out_file)))
    os.remove(pass_file); os.remove(in_file)
    assert(ok, "openssl encryption failed")
    return out_file
end

describe("decrypt", function()
    it("finds openssl", function()
        assert.is_true(Decrypt.available())
    end)

    it("round-trips a string through Decrypt.data", function()
        local plain = "<?xml version='1.0'?><feed>…ünïcödé…</feed>"
        local enc = encrypt(plain, KEY)
        assert.are.equal(plain, Decrypt.data(read(enc), KEY))
        os.remove(enc)
    end)

    it("returns nil from Decrypt.data on a wrong key", function()
        local enc = encrypt("secret", KEY)
        assert.is_nil(Decrypt.data(read(enc), "not the key"))
        os.remove(enc)
    end)

    it("decrypts a file in place", function()
        local plain = string.rep("EPUB payload\n", 500)
        local enc = encrypt(plain, KEY)
        assert.is_true(Decrypt.file(enc, KEY))
        assert.are.equal(plain, read(enc))
        os.remove(enc)
    end)

    it("leaves the file untouched when the key is wrong", function()
        local enc = encrypt("secret", KEY)
        local before = read(enc)
        assert.is_false(Decrypt.file(enc, "not the key"))
        assert.are.equal(before, read(enc))
        os.remove(enc)
    end)

    it("reports a plain file as plaintext rather than a failure", function()
        -- A catalogue can mix encrypted and plain books: the server only
        -- encrypts what it was given a key for.
        local path = tmp()
        write(path, "PK\003\004 not encrypted at all")
        local ok, status = Decrypt.file(path, KEY)
        assert.is_true(ok)
        assert.are.equal("plaintext", status)
        assert.are.equal("PK\003\004 not encrypted at all", read(path))
        os.remove(path)
    end)

    it("reports statuses for decrypted and failed", function()
        local enc = encrypt("payload", KEY)
        local _, ok_status = Decrypt.file(enc, KEY)
        assert.are.equal("decrypted", ok_status)
        os.remove(enc)

        local enc2 = encrypt("payload", KEY)
        local _, bad_status = Decrypt.file(enc2, "not the key")
        assert.are.equal("failed", bad_status)
        os.remove(enc2)
    end)

    it("leaves no temporary behind in the download folder", function()
        local dir = os.tmpname() .. ".d"
        assert(succeeded(os.execute("mkdir -p '" .. dir .. "'")))
        local enc = encrypt("payload", KEY)
        local target = dir .. "/book.epub"
        assert(succeeded(os.execute(string.format("mv '%s' '%s'", enc, target))))

        assert.is_true(Decrypt.file(target, KEY))
        local listing = io.popen("ls -A '" .. dir .. "'"):read("*all")
        assert.are.equal("book.epub\n", listing)
        os.execute("rm -rf '" .. dir .. "'")
    end)

    it("survives a filename full of shell metacharacters", function()
        local dir = os.tmpname() .. ".d"
        assert(succeeded(os.execute("mkdir -p '" .. dir .. "'")))
        local target = dir .. [[/it's $(whoami) `id` ;rm -rf x.epub]]
        local enc = encrypt("payload", KEY)
        write(target, read(enc)); os.remove(enc)

        assert.is_true(Decrypt.file(target, KEY))
        assert.are.equal("payload", read(target))
        os.execute("rm -rf '" .. dir .. "'")
    end)
end)
