--[[
  main.lua — Nakama server runtime entry point

  In Nakama's Lua runtime:
  - Match handlers are registered by returning them from the module file
    that matches the handler name passed to nk.match_create().
  - RPCs are registered with nk.register_rpc().
  - There is no nk.register_match() in Lua (that is Go/JS only).
--]]

local nk          = require("nakama")
local matchmaking = require("matchmaking")
local lb          = require("leaderboard")

-- ── Ensure leaderboard exists (idempotent) ────────────────────────────────
lb.ensure_leaderboard()

-- ── Register RPCs ─────────────────────────────────────────────────────────
nk.register_rpc(matchmaking.rpc_create_match, "rpc_create_match")
nk.register_rpc(matchmaking.rpc_find_match,   "rpc_find_match")
nk.register_rpc(matchmaking.rpc_join_match,   "rpc_join_match")
nk.register_rpc(matchmaking.rpc_list_matches, "rpc_list_matches")

nk.register_rpc(lb.rpc_get_leaderboard, "rpc_get_leaderboard")
nk.register_rpc(lb.rpc_get_my_stats,    "rpc_get_my_stats")

nk.logger_info("Tic-Tac-Toe backend initialised")
