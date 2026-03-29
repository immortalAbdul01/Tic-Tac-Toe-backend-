local nk = require("nakama")

-- Matchmaker: when 2 players are matched, create a Tic Tac Toe match
nk.register_matchmaker_matched(function(context, matched_users)
  return nk.match_create("match", {})
end)

-- RPC: Find or create a match (adds player to matchmaking)
local function find_or_create_match(context, payload)
  local ticket = nk.matchmaker_add(context, 2, 2, "*", {}, {})
  return nk.json_encode({ ticket = ticket })
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
