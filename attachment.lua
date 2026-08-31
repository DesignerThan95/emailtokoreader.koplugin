local mime = require("mime")
local filesystem = require("filesystem")
local encoding = require("encoding")

local attachment = {}

function attachment.process_stream(stream_iter, download_path, tick_cb, allowed_extensions)
    local state = "SEARCHING"
    local current_boundary = nil

    -- Build a lookup set of the accepted extensions (lowercase, without dot)
    local allowed_set = {}
    for _, ext in ipairs(allowed_extensions or {"epub"}) do
        local key = tostring(ext):lower():match("^%.?(.+)$")
        if key then
            allowed_set[key] = true
        end
    end

    local header_lines = {}
    local current_filename = nil
    local is_base64 = false
    
    local chunks = {}
    local chunks_len = 0
    local b64_leftover = ""
    
    local out_file = nil
    local tmp_path = nil
    local final_path = nil
    
    local downloaded_count = 0
    local lines_processed = 0

    local function finalize_attachment()
        if out_file then
            if chunks_len > 0 or #b64_leftover > 0 then
                local final_string = b64_leftover .. table.concat(chunks)
                
                -- Ensure the final string is padded to a perfect multiple of 4
                local pad = #final_string % 4
                if pad > 0 then
                    final_string = final_string .. string.rep("=", 4 - pad)
                end
                
                -- Wrapped the final decode in pcall
                local decode_ok, decoded = pcall(mime.unb64, final_string)
                if decode_ok and decoded and #decoded > 0 then 
                    out_file:write(decoded) 
                end
            end
            
            out_file:close()
            out_file = nil
            
            if tmp_path and final_path then
                local ok, err = os.rename(tmp_path, final_path)
                if ok then
                    downloaded_count = downloaded_count + 1
                else
                    os.remove(tmp_path)
                end
            end
        end
        
        header_lines = {}
        current_filename = nil
        is_base64 = false
        chunks = {}
        chunks_len = 0
        b64_leftover = ""
        tmp_path = nil
        final_path = nil
    end

    local function process_line(line)
        lines_processed = lines_processed + 1
        
        if tick_cb and lines_processed % 250 == 0 then
            tick_cb()
        end

        line = line:gsub("\r$", "")

        -- 1. Catch global boundary definitions anywhere in the email
        local new_boundary = line:match('boundary="([^"]+)"') or line:match('boundary=([^%s]+)')
        if new_boundary then
            current_boundary = "--" .. new_boundary
        end

        -- 2. Strict RFC boundary detection
        if current_boundary and (line == current_boundary or line == current_boundary .. "--") then
            finalize_attachment()
            state = "HEADERS"
        
        -- 3. Accumulate headers
        elseif state == "HEADERS" then
            if line ~= "" then
                table.insert(header_lines, line)
            else
                local header_block = table.concat(header_lines, " ")
                
                if header_block:lower():match("content%-transfer%-encoding:%s*base64") then
                    is_base64 = true
                end
                
                -- Generic filename detection (quoted first, then unquoted)
                local fname = header_block:match('filename="([^"]+)"')
                    or header_block:match('name="([^"]+)"')
                    or header_block:match('filename=([^%s;"]+)')
                    or header_block:match('name=([^%s;"]+)')

                -- Only accept the attachment if its extension is allowed
                if fname then
                    local ext = fname:match("%.([^%.]+)$")
                    if not (ext and allowed_set[ext:lower()]) then
                        fname = nil
                    end
                end

                if fname and is_base64 then
                    local decode_ok, decoded_name = pcall(encoding.decode_rfc2047, fname)
                    if decode_ok and decoded_name then
                        fname = decoded_name
                    end
                    
                    current_filename = encoding.safe_filename(fname)
                    state = "BODY_BASE64"
                    
                    filesystem.mkdir_p(download_path)
                    final_path = filesystem.unique_filepath(download_path .. "/" .. current_filename)
                    tmp_path = final_path .. ".tmp"
                    
                    out_file = io.open(tmp_path, "wb")
                    if not out_file then
                        state = "SEARCHING"
                    end
                else
                    state = "SEARCHING"
                end
            end

        -- 4. Stream and validate Base64 payload
        elseif state == "BODY_BASE64" then
            local clean = line:gsub("%s+", "")
            
            -- Defensive check: only buffer valid Base64 characters
            if clean ~= "" and clean:match("^[A-Za-z0-9+/=]+$") then
                table.insert(chunks, clean)
                chunks_len = chunks_len + #clean
                
                if chunks_len >= 8192 then
                    local combined = b64_leftover .. table.concat(chunks)
                    chunks = {}
                    chunks_len = 0
                    
                    local safe_len = math.floor(#combined / 4) * 4
                    if safe_len > 0 then
                        local chunk_to_decode = combined:sub(1, safe_len)
                        b64_leftover = combined:sub(safe_len + 1)
                        
                        -- Wrapped the chunk decode in pcall
                        local decode_ok, decoded = pcall(mime.unb64, chunk_to_decode)
                        if decode_ok and decoded and #decoded > 0 and out_file then
                            out_file:write(decoded)
                        end
                    else
                        b64_leftover = combined
                    end
                end
            end
        end
    end

    -- 5. Safe Chunk-to-Line Buffer
    local leftover_text = ""
    while true do
        local chunk = stream_iter()
        
        -- End of stream: process any trailing text
        if not chunk then
            if leftover_text ~= "" then process_line(leftover_text) end
            break
        end

        local text = leftover_text .. chunk
        local pos = 1
        
        -- Split strictly on newlines, saving partial text for the next loop
        while true do
            local s, e = text:find("\n", pos)
            if not s then
                leftover_text = text:sub(pos)
                break
            end
            local line = text:sub(pos, s - 1)
            process_line(line)
            pos = e + 1
        end
    end

    finalize_attachment()

    return downloaded_count
end

return attachment