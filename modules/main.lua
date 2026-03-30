local nk = require("nakama")

-- The match handler in match.lua is auto-discovered by Nakama.
-- Its module name is "match" (the filename without .lua).
-- Clients create matches via: nk.match_create("match", {})

-- RPC: Create a new match and return its ID
-- Player 1 calls this to create a match, shares the match_id with Player 2
-- Player 2 joins using the match_id via socket.joinMatch()
local function find_or_create_match(context, payload)
  -- Look for an existing waiting match first
  local matches = nk.match_list(10, true, nil, 0, 1)
  local match_id
  if #matches > 0 then
    match_id = matches[1].match_id
  else
    match_id = nk.match_create("match", {})
  end
  return nk.json_encode({ match_id = match_id })
end
nk.register_rpc(find_or_create_match, "find_or_create_match")

-- RPC: Get player stats
local function get_player_stats(context, payload)
  local reads = {
    {
      collection = "player_stats",
      key = "tictactoe",
      user_id = context.user_id
    }
  }

  local ok, records = pcall(nk.storage_read, reads)

  if not ok or not records or not records[1] then
    return nk.json_encode({
      wins = 0,
      losses = 0,
      draws = 0,
      score = 0
    })
  end

  return records[1].value
end
nk.register_rpc(get_player_stats, "get_player_stats")
