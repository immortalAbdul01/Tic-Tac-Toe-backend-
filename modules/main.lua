

local nk           = require("nakama")
local match        = require("match")
local matchmaking  = require("matchmaking")
local lb           = require("leaderboard")

-- ── Register the match handler 
-- The name "tictactoe" must match the first arg of nk.match_create() calls.
nk.register_matchmaker_matched(function(context, matchmaker_users)
  -- Not using Nakama's built-in matchmaker (we use our own RPC flow),
  -- but this hook is here for completeness / future extension.
end)

nk.register_match("tictactoe", {
  match_init        = match.match_init,
  match_join_attempt = match.match_join_attempt,
  match_join        = match.match_join,
  match_loop        = match.match_loop,
  match_leave       = match.match_leave,
  match_terminate   = match.match_terminate,
  match_signal      = match.match_signal,
})

-- ── Ensure leaderboard exists (idempotent)
lb.ensure_leaderboard()

-- ── Register RPCs
-- Matchmaking
nk.register_rpc(matchmaking.rpc_create_match, "rpc_create_match")
nk.register_rpc(matchmaking.rpc_find_match,   "rpc_find_match")
nk.register_rpc(matchmaking.rpc_join_match,   "rpc_join_match")
nk.register_rpc(matchmaking.rpc_list_matches, "rpc_list_matches")

-- Leaderboard / stats
nk.register_rpc(lb.rpc_get_leaderboard, "rpc_get_leaderboard")
nk.register_rpc(lb.rpc_get_my_stats,    "rpc_get_my_stats")

nk.logger_info("Tic-Tac-Toe backend initialised ✓")
