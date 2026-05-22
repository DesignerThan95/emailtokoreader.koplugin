local socket = require("socket")

local imap = {
    _tag_counter = 0
}

function imap.next_tag()
    imap._tag_counter = imap._tag_counter + 1
    return string.format("A%03d", imap._tag_counter)
end

function imap.connect(config)
    local conn = socket.tcp()
    conn:settimeout(30)

    local ok, err = conn:connect(config.imap_server, config.imap_port)
    if not ok then return nil, err end

    if config.use_ssl then
        local has_ssl, ssl = pcall(require, "ssl")
        if not has_ssl then
            conn:close()
            return nil, "SSL module unavailable"
        end

        conn = ssl.wrap(conn, { mode = "client", protocol = "tlsv1_2", verify = "none" })
        local hs_ok, hs_err = conn:dohandshake()
        if not hs_ok then
            conn:close()
            return nil, "SSL handshake failed: " .. tostring(hs_err)
        end
    end

    local greeting = conn:receive("*l")
    if not greeting then
        conn:close()
        return nil, "No IMAP greeting received"
    end

    return conn
end

function imap.login(conn, email, password)
    local tag = imap.next_tag()
    local safe_tag = tag:gsub("(%W)", "%%%1")
    conn:send(string.format('%s LOGIN "%s" "%s"\r\n', tag, email, password))

    for _ = 1, 10 do
        local line = conn:receive("*l")
        if not line then return false end
        if line:match("^" .. safe_tag .. " OK") then return true
        elseif line:match("^" .. safe_tag .. " NO") or line:match("^" .. safe_tag .. " BAD") then return false end
    end
    return false
end

function imap.search_unseen(conn)
    local tag_select = imap.next_tag()
    local safe_select = tag_select:gsub("(%W)", "%%%1")
    conn:send(tag_select .. " SELECT INBOX\r\n")

    local line
    repeat line = conn:receive("*l") until not line or line:match("^" .. safe_select .. " ")
    if not line or not line:match("^" .. safe_select .. " OK") then return {} end

    local tag_search = imap.next_tag()
    local safe_search = tag_search:gsub("(%W)", "%%%1")
    conn:send(tag_search .. " SEARCH UNSEEN\r\n")

    local ids = {}
    line = conn:receive("*l")
    
    while line and not line:match("^" .. safe_search .. " ") do
        for id in line:gmatch("%d+") do table.insert(ids, id) end
        line = conn:receive("*l")
    end
    return ids
end

function imap.fetch_stream(conn, id)
    local tag = imap.next_tag()
    local safe_tag = tag:gsub("(%W)", "%%%1")
    
    conn:settimeout(30)
    conn:send(string.format("%s FETCH %s BODY[]\r\n", tag, id))

    local line
    local literal_size = nil

    -- Read until we find the literal byte count e.g. {5812345}
    repeat
        line = conn:receive("*l")
        if not line then return nil, "connection_dropped" end
        literal_size = tonumber(line:match("{(%d+)}$"))
    until literal_size

    local remaining = literal_size
    local done = false

    return function()
        if done then return nil end

        -- Once we read the exact byte count, clean up the trailing protocol lines
        if remaining <= 0 then
            done = true
            repeat
                line = conn:receive("*l")
            until not line or line:match("^" .. safe_tag .. " ")
            return nil
        end

        local chunk_size = math.min(8192, remaining)
        local chunk, err, partial = conn:receive(chunk_size)
        chunk = chunk or partial

        if not chunk or #chunk == 0 then
            done = true
            return nil, err or "read_failed"
        end

        remaining = remaining - #chunk
        return chunk
    end
end

function imap.logout(conn)
    local tag = imap.next_tag()
    conn:send(tag .. " LOGOUT\r\n")
    conn:settimeout(5)
    pcall(function() conn:receive("*l") end)
    conn:close()
end

return imap