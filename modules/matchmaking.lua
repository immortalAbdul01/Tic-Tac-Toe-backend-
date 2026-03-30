

local nk = require("nakama")

-- ── Helpers

local function ok_response(data)
  return nk.json_encode({ success = true, data = data })
end

local function err_response(code, message)
  return nk.json_encode({ success = false, error = { code = code, message = message } })
end

-- ── RPC: create a new match
--[[
  Payload (optional JSON):
    { "timed_mode": true }   → creates a timed match
    {}                       → classic match (default)

  Response:
    { "success": true, "data": { "match_id": "..." } }
--]]
local function rpc_create_match(context, payload)
  local params = { timed_mode = false }

  if payload and payload ~= "" then
    local ok, p = pcall(nk.json_decode, payload)
    if ok and type(p) == "table" then
      params.timed_mode = p.timed_mode == true
    end
  end

  local ok, id = pcall(nk.match_create, "tictactoe", nk.json_encode(params))
  if not ok then
    nk.logger_error("rpc_create_match failed: " .. tostring(id))
    return err_response("CREATE_FAILED", "Could not create match.")
  end

  nk.logger_info("Match created: " .. id .. " timed=" .. tostring(params.timed_mode))
  return ok_response({ match_id = id, timed_mode = params.timed_mode })
end

-- ── RPC: auto-matchmake (find or create)

--]]
local function rpc_find_match(context, payload)
  local timed_mode = false
  if payload and payload ~= "" then
    local ok, p = pcall(nk.json_decode, payload)
    if ok and type(p) == "table" then
      timed_mode = p.timed_mode == true
    end
  end

  -- List matches that are waiting and have 0–1 presences
  local label_filter = nk.json_encode({ status = "waiting", timed_mode = timed_mode })

  local found_id = nil
  local ok_list, list = pcall(nk.match_list, 10, true, label_filter, 0, 1, nil)
  if ok_list and list and #list > 0 then
    found_id = list[1].match_id
  end

  if found_id then
    nk.logger_info("Auto-matchmake: found existing match " .. found_id)
    return ok_response({ match_id = found_id, created = false, timed_mode = timed_mode })
  end

  -- No waiting match found → create one
  local new_id = nk.match_create("tictactoe", nk.json_encode({ timed_mode = timed_mode }))
  nk.logger_info("Auto-matchmake: created new match " .. new_id)
  return ok_response({ match_id = new_id, created = true, timed_mode = timed_mode })
end


local function rpc_join_match(context, payload)
  if not payload or payload == "" then
    return err_response("MISSING_PAYLOAD", "match_id is required.")
  end

  local ok, p = pcall(nk.json_decode, payload)
  if not ok or type(p) ~= "table" or not p.match_id then
    return err_response("INVALID_PAYLOAD", "Payload must be JSON with match_id.")
  end

  local match_id = p.match_id

  -- Verify match exists
  local list = nk.match_list(1, true, nil, nil, nil, "+" .. match_id)
  -- nk.match_list with a query isn't guaranteed to filter by ID on all versions;
  -- we rely on the client socket to handle "not found" gracefully.
  -- This RPC is a convenience pre-check only.

  return ok_response({ match_id = match_id })
end

-- ── RPC: list open matches 
--[[
  Payload (optional JSON):
    { "timed_mode": true }   → only timed matches
    {}                       → all waiting matches

  Response:
    { "success": true, "data": { "matches": [...] } }
--]]
local function rpc_list_matches(context, payload)
  local timed_filter = nil
  if payload and payload ~= "" then
    local ok, p = pcall(nk.json_decode, payload)
    if ok and type(p) == "table" and p.timed_mode ~= nil then
      timed_filter = p.timed_mode == true
    end
  end

  local label_filter = nil
  if timed_filter ~= nil then
    label_filter = nk.json_encode({ status = "waiting", timed_mode = timed_filter })
  else
    -- list all waiting matches regardless of mode
    label_filter = nk.json_encode({ status = "waiting" })
  end

  local list = nk.match_list(20, true, label_filter, 0, 1, nil)
  local result = {}
  if list then
    for _, m in ipairs(list) do
      local label = {}
      if m.label and m.label ~= "" then
        local ok, l = pcall(nk.json_decode, m.label)
        if ok then label = l end
      end
      table.insert(result, {
        match_id   = m.match_id,
        presences  = m.size,
        timed_mode = label.timed_mode,
        status     = label.status,
      })
    end
  end

  return ok_response({ matches = result })
end

-- ── Exports ───────────────────────────────────────────────────────────────
return {
  rpc_create_match = rpc_create_match,
  rpc_find_match   = rpc_find_match,
  rpc_join_match   = rpc_join_match,
  rpc_list_matches = rpc_list_matches,
}
