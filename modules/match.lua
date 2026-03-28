local M = {}

local OP_MOVE  = 1
local OP_STATE = 11

local STATE_WAITING  = "waiting"
local STATE_PLAYING  = "playing"

local TICK_RATE = 5

local function new_board()
  local b = {}
  for i = 0, 8 do b[i] = "" end
  return b
end

local function build_state(state)
  return nk.json_encode({
    board = state.board,
    turn  = state.turn,
    status = state.status
  })
end

local function broadcast_state(dispatcher, state)
  dispatcher.broadcast_message(OP_STATE, build_state(state))
end

function M.match_init(context, setupstate)
  local state = {
    board = new_board(),
    players = {},
    turn = "X",
    status = STATE_WAITING
  }

  return state, TICK_RATE, "tic-tac-toe"
end

function M.match_join(context, dispatcher, tick, state, presences)
  for _, presence in ipairs(presences) do
    if not state.players["X"] then
      state.players["X"] = presence
    elseif not state.players["O"] then
      state.players["O"] = presence
    end
  end

  if state.players["X"] and state.players["O"] then
    state.status = STATE_PLAYING
  end

  broadcast_state(dispatcher, state)
  return state
end

function M.match_loop(context, dispatcher, tick, state, messages)
  return state
end

return M
