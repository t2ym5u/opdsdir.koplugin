-- Shell quoting for the openssl/mv/rm commands in main.lua.
--
-- The paths handed to those commands come from the OPDS catalogue: KOReader
-- builds the local filename from the remote entry. A catalogue is a remote
-- party, so a filename is untrusted input, and wrapping it in plain single
-- quotes is not enough -- a single quote inside the name closes the quoting
-- and the rest of the name runs as shell.

local Sh = {}

-- Wrap s in single quotes, ending and reopening the quoting around every
-- single quote it contains. The result is a single shell word for any input,
-- including newlines and metacharacters.
function Sh.quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

return Sh
