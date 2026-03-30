

local nk = require("nakama")

local LEADERBOARD_ID = "tictactoe_global"

-- ── Helpers .
local function ok_response(data)
  return nk.json_encode({ success = true, data = data })
end

local function err_response(code, message)
  return nk.json_encode({ success = false, error = { code = code, message = message } })
end

-- ── Ensure the leaderboard record exists 
-- Called once at startup from main.lua
local function ensure_leaderboard()
  -- operator "set" means a score submission replaces the previous value
  -- sort_order "desc" → highest score = rank 1
  local ok, err = pcall(nk.leaderboard_create,
    LEADERBOARD_ID,   -- id
    false,            -- authoritative (false = players can submit directly too)
    "desc",           -- sort_order
    "set",            -- operator
    nil,              -- reset schedule (nil = never auto-reset)
    nil               -- metadata
  )
  if not ok then
    -- Will error if already exists — that is fine
    nk.logger_info("leaderboard_create skipped (may already exist): " .. tostring(err))
  end
end

-- ── RPC: global leaderboard
--[[
  Payload (optional JSON):
    { "limit": 20 }    → number of top players to return (default 20, max 100)

  Response:
    {
      "success": true,
      "data": {
        "records": [
          { "rank": 1, "username": "Ace", "score": 2100,
            "wins": 10, "losses": 2, "draws": 1 },
          ...
        ]
      }
    }
--]]
local function rpc_get_leaderboard(context, payload)
  local limit = 20
  if payload and payload ~= "" then
    local ok, p = pcall(nk.json_decode, payload)
    if ok and type(p) == "table" and type(p.limit) == "number" then
      limit = math.min(math.max(1, math.floor(p.limit)), 100)
    end
  end

  local records, owner_records, next_cursor, prev_cursor =
    nk.leaderboard_records_list(LEADERBOARD_ID, nil, limit, nil, 1)

  local result = {}
  if records then
    for _, rec in ipairs(records) do
      -- Pull detailed stats from storage for win/loss/draw breakdown
      local stats = { wins = 0, losses = 0, draws = 0, score = rec.score }
      local reads = {{ collection = "player_stats", key = "tictactoe", user_id = rec.owner_id }}
      local ok2, storage_records = pcall(nk.storage_read, reads)
      if ok2 and storage_records and storage_records[1] then
        local decoded = nk.json_decode(storage_records[1].value)
        if decoded then stats = decoded end
      end

      table.insert(result, {
        rank     = rec.rank,
        user_id  = rec.owner_id,
        username = rec.username,
        score    = rec.score,
        wins     = stats.wins   or 0,
        losses   = stats.losses or 0,
        draws    = stats.draws  or 0,
      })
    end
  end

  return ok_response({ records = result })
end

-- ── RPC: personal stats
--[[
  No payload required (uses calling user's context.user_id).

  Response:
    {
      "success": true,
      "data": {
        "user_id": "...",
        "username": "...",
        "score": 2100,
        "wins": 10,
        "losses": 2,
        "draws": 1,
        "rank": 1
      }
    }
--]]
local function rpc_get_my_stats(context, payload)
  local user_id = context.user_id

  -- Storage stats
  local reads = {{ collection = "player_stats", key = "tictactoe", user_id = user_id }}
  local ok, records = pcall(nk.storage_read, reads)
  local stats = { wins = 0, losses = 0, draws = 0, score = 0 }
  if ok and records and records[1] then
    local decoded = nk.json_decode(records[1].value)
    if decoded then stats = decoded end
  end

  -- Rank from leaderboard
  local rank = nil
  local ok2, owner_records = pcall(nk.leaderboard_records_list,
    LEADERBOARD_ID, { user_id }, 1, nil, 1)
  if ok2 and owner_records and owner_records[1] then
    rank = owner_records[1].rank
  end

  -- Username
  local users = nk.users_get_id({ user_id })
  local username = (users and users[1] and users[1].username) or "unknown"

  return ok_response({
    user_id  = user_id,
    username = username,
    score    = stats.score  or 0,
    wins     = stats.wins   or 0,
    losses   = stats.losses or 0,
    draws    = stats.draws  or 0,
    rank     = rank,
  })
end

-- ── Exports .
return {
  ensure_leaderboard  = ensure_leaderboard,
  rpc_get_leaderboard = rpc_get_leaderboard,
  rpc_get_my_stats    = rpc_get_my_stats,
}
