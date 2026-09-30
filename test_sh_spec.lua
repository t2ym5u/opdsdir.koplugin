-- The plugin shells out to openssl, mv and rm with paths that come from the
-- OPDS catalogue, so the quoting below is the only thing standing between a
-- hostile filename and os.execute.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.path = DIR .. "?.lua;" .. package.path

describe("Sh.quote", function()
    local Sh

    setup(function()
        Sh = require("sh")
    end)

    it("wraps an ordinary path in single quotes", function()
        assert.are.equal("'/mnt/books/novel.epub'", Sh.quote("/mnt/books/novel.epub"))
    end)

    it("keeps spaces inside the one word", function()
        assert.are.equal("'/mnt/A Long Title.epub'", Sh.quote("/mnt/A Long Title.epub"))
    end)

    it("neutralises a single quote instead of letting it close the quoting", function()
        -- A catalogue entry named  x'; rm -rf ~; '.epub  used to end the quoted
        -- string and hand the rest to the shell.
        local quoted = Sh.quote("x'; rm -rf ~; '.epub")
        assert.are.equal([['x'\''; rm -rf ~; '\''.epub']], quoted)
    end)

    it("leaves shell metacharacters inert", function()
        for _, s in ipairs({ "a;b", "a|b", "a&b", "a`b`", "a$(b)", "a>b", "a\nb", "a*b", "a$HOME" }) do
            local q = Sh.quote(s)
            -- Everything between the outer quotes is literal, and the only way
            -- out is a single quote -- which the input above does not contain.
            assert.are.equal("'" .. s .. "'", q)
        end
    end)

    it("produces one shell word, whatever the input", function()
        -- Round-trip through the shell itself: printf must echo back exactly
        -- what went in, for every awkward string.
        local cases = {
            "plain.epub",
            "with space.epub",
            "quote'inside.epub",
            "double\"quote.epub",
            "back\\slash.epub",
            "semi;colon.epub",
            "dollar$VAR.epub",
            "sub$(echo hi).epub",
            "tick`echo hi`.epub",
            "star*.epub",
            "new\nline.epub",
            "-leading-dash.epub",
            "accentué—dash.epub",
        }
        for _, s in ipairs(cases) do
            local pipe = io.popen("printf %s " .. Sh.quote(s))
            local out  = pipe:read("*all")
            pipe:close()
            assert.are.equal(s, out, "round-trip failed for " .. s)
        end
    end)

    it("accepts a non-string without erroring", function()
        assert.are.equal("'42'", Sh.quote(42))
    end)
end)
