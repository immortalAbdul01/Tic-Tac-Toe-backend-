--[[
  matchmaking.lua — RPC endpoints for match creation and joining
--]]

local nk = require("nakama")

local function ok_response(data)
  return nk.json_encode({ success = true, data = data })
end

local function err_response(code, message)
  return nk.json_encode({ success = false, error = { code = code, message = message } })
end

-- ── RPC: create a new match ───────────────────────────────────────────────
local function rpc_create_match(context, payload)
  local timed_mode = false
  if payload and payload ~= "" then
    local ok, p = pcall(nk.json_decode, payload)
    if ok and type(p) == "table" then
      timed_mode = p.timed_mode == true
    end
  end

  -- Second arg must be a Lua TABLE, not a JSON string
  local ok, match_id = pcall(nk.match_create, "tictactoe", { timed_mode = timed_mode })
  if not ok then
    nk.logger_error("rpc_create_match failed: " .. tostring(match_id))
    return err_response("CREATE_FAILED", tostring(match_id))
  end

  nk.logger_info("Match created: " .. tostring(match_id))
  return ok_response({ match_id = match_id, timed_mode = timed_mode })
end

-- ── RPC: auto-matchmake (find or create) ─────────────────────────────────
local function rpc_find_match(context, payload)
  local timed_mode = false
  if payload and payload ~= "" then
    local ok, p = pcall(nk.json_decode, payload)
    if ok and type(p) == "table" then
      timed_mode = p.timed_mode == true
    end
  end

  -- Find an existing waiting match
  local found_id = nil
  local ok_list, list = pcall(nk.match_list, 10, true, nil, 0, 1, nil)
  if ok_list and type(list) == "table" then
    for _, m in ipairs(list) do
      if m.label and m.label ~= "" then
        local ok_lbl, lbl = pcall(nk.json_decode, m.label)
        if ok_lbl and type(lbl) == "table" and lbl.status == "waiting" then
          found_id = m.match_id
          break
        end
      end
    end
  end

  if found_id then
    nk.logger_info("Auto-matchmake: found existing match " .. found_id)
    return ok_response({ match_id = found_id, created = false, timed_mode = timed_mode })
  end

  -- Create new match — second arg is a Lua TABLE
  local ok_c, new_id = pcall(nk.match_create, "tictactoe", { timed_mode = timed_mode })
  if not ok_c then
    nk.logger_error("match_create failed: " .. tostring(new_id))
    return err_response("CREATE_FAILED", tostring(new_id))
  end

  nk.logger_info("Auto-matchmake: created new match " .. tostring(new_id))
  return ok_response({ match_id = new_id, created = true, timed_mode = timed_mode })
end

-- ── RPC: join a specific match by ID ─────────────────────────────────────
local function rpc_join_match(context, payload)
  if not payload or payload == "" then
    return err_response("MISSING_PAYLOAD", "match_id is required.")
  end
  local ok, p = pcall(nk.json_decode, payload)
  if not ok or type(p) ~= "table" or not p.match_id then
    return err_response("INVALID_PAYLOAD", "Payload must be JSON with match_id.")
  end
  return ok_response({ match_id = p.match_id })
end

-- ── RPC: list open matches ────────────────────────────────────────────────
local function rpc_list_matches(context, payload)
  local ok_list, list = pcall(nk.match_list, 20, true, nil, 0, 1, nil)
  local result = {}
  if ok_list and type(list) == "table" then
    for _, m in ipairs(list) do
      local label = {}
      if m.label and m.label ~= "" then
        local ok_lbl, l = pcall(nk.json_decode, m.label)
        if ok_lbl and type(l) == "table" then label = l end
      end
      if label.status == "waiting" then
        table.insert(result, {
          match_id   = m.match_id,
          presences  = m.size,
          timed_mode = label.timed_mode or false,
          status     = label.status,
        })
      end
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
