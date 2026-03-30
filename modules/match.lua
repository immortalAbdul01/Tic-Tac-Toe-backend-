local nk = require("nakama")
local M = {}

local OP_MOVE     = 1
local OP_STATE    = 11
local OP_ERROR    = 12

local STATE_WAITING  = "waiting"
local STATE_PLAYING  = "playing"
local STATE_FINISHED = "finished"

local TICK_RATE = 5

local WINNING_LINES = {
  {0,1,2}, {3,4,5}, {6,7,8},
  {0,3,6}, {1,4,7}, {2,5,8},
  {0,4,8}, {2,4,6},
}

local function new_board()
  local b = {}
  for i = 0, 8 do b[i] = "" end
  return b
end

local function board_to_array(board)
  local arr = {}
  for i = 0, 8 do arr[i + 1] = board[i] end
  return arr
end

local function check_result(board)
  for _, line in ipairs(WINNING_LINES) do
    local a, b, c = line[1], line[2], line[3]
    if board[a] ~= "" and board[a] == board[b] and board[a] == board[c] then
      return board[a], line
    end
  end
  for i = 0, 8 do
    if board[i] == "" then return nil, nil end
  end
  return "draw", {}
end

local function build_state(state)
  return nk.json_encode({
    status       = state.status,
    board        = board_to_array(state.board),
    turn         = state.turn,
    players      = state.players,
    winner       = state.winner,
    winning_line = state.winning_line,
    move_count   = state.move_count,
  })
end

local function broadcast_state(dispatcher, state)
  dispatcher.broadcast_message(OP_STATE, build_state(state), nil, nil, true)
end

local function send_error(dispatcher, presence, code, msg)
  dispatcher.broadcast_message(
    OP_ERROR,
    nk.json_encode({ code = code, message = msg }),
    { presence }, nil, true
  )
end

local function record_result(state)
  local writes = {}
  for mark, info in pairs(state.players) do
    local outcome
    if state.winner == "draw" then
      outcome = "draw"
    elseif state.winner == mark then
      outcome = "win"
    else
      outcome = "loss"
    end

    local reads = {{ collection = "player_stats", key = "tictactoe", user_id = info.id }}
    local ok, records = pcall(nk.storage_read, reads)
    local stats = { wins = 0, losses = 0, draws = 0, score = 0 }
    if ok and records and records[1] then
      local decoded = nk.json_decode(records[1].value)
      if decoded then stats = decoded end
    end

    if outcome == "win" then
      stats.wins  = (stats.wins  or 0) + 1
      stats.score = (stats.score or 0) + 200
    elseif outcome == "loss" then
      stats.losses = (stats.losses or 0) + 1
      stats.score  = math.max(0, (stats.score or 0) - 50)
    else
      stats.draws = (stats.draws or 0) + 1
      stats.score = (stats.score or 0) + 50
    end

    table.insert(writes, {
      collection       = "player_stats",
      key              = "tictactoe",
      user_id          = info.id,
      value            = nk.json_encode(stats),
      permission_read  = 2,
      permission_write = 0,
    })
  end
  local ok, err = pcall(nk.storage_write, writes)
  if not ok then
    nk.logger_error("record_result failed: " .. tostring(err))
  end
end

-- Declared before match_loop so it is visible when called
local function handle_move(context, dispatcher, tick, state, message)
  local sender = message.sender

  if state.status ~= STATE_PLAYING then
    send_error(dispatcher, sender, "GAME_NOT_ACTIVE", "No active game.")
    return state
  end

  local sender_mark = nil
  for mark, info in pairs(state.players) do
    if info.session_id == sender.session_id then
      sender_mark = mark
      break
    end
  end

  if not sender_mark then
    send_error(dispatcher, sender, "NOT_A_PLAYER", "You are not a player in this match.")
    return state
  end

  if state.turn ~= sender_mark then
    send_error(dispatcher, sender, "NOT_YOUR_TURN", "It is " .. state.turn .. "'s turn.")
    return state
  end

  local ok, data = pcall(nk.json_decode, message.data)
  if not ok or type(data) ~= "table" then
    send_error(dispatcher, sender, "INVALID_PAYLOAD", "Message must be valid JSON.")
    return state
  end

  local pos = data.position
  if type(pos) ~= "number" then
    send_error(dispatcher, sender, "INVALID_POSITION", "position must be a number.")
    return state
  end

  pos = math.floor(pos)
  if pos < 0 or pos > 8 then
    send_error(dispatcher, sender, "OUT_OF_BOUNDS", "position must be 0-8.")
    return state
  end

  if state.board[pos] ~= "" then
    send_error(dispatcher, sender, "CELL_OCCUPIED", "Cell " .. pos .. " is already taken.")
    return state
  end

  state.board[pos] = sender_mark
  state.move_count = state.move_count + 1

  nk.logger_info(string.format("move: %s placed %s at %d (move #%d)",
    sender.username, sender_mark, pos, state.move_count))

  local result, winning_line = check_result(state.board)
  if result then
    state.status       = STATE_FINISHED
    state.winner       = result
    state.winning_line = winning_line or {}
    state.turn         = ""
    record_result(state)
    nk.logger_info("game over: " .. result)
  else
    state.turn = (sender_mark == "X") and "O" or "X"
  end

  broadcast_state(dispatcher, state)
  return state
end

-- ── Match lifecycle ────────────────────────────────────────────────────────

function M.match_init(context, setupstate)
  local state = {
    status       = STATE_WAITING,
    board        = new_board(),
    players      = {},
    presences    = {},
    turn         = "X",
    winner       = "",
    winning_line = {},
    move_count   = 0,
  }
  return state, TICK_RATE, nk.json_encode({ status = STATE_WAITING })
end

function M.match_join_attempt(context, dispatcher, tick, state, presence, metadata)
  local count = 0
  for _ in pairs(state.players) do count = count + 1 end
  if count >= 2 then return state, false, "Match is full" end
  if state.status == STATE_FINISHED then return state, false, "Match has ended" end
  return state, true
end

function M.match_join(context, dispatcher, tick, state, presences)
  for _, presence in ipairs(presences) do
    state.presences[presence.session_id] = presence
    if not state.players["X"] then
      state.players["X"] = { id = presence.user_id, username = presence.username, session_id = presence.session_id }
    elseif not state.players["O"] then
      state.players["O"] = { id = presence.user_id, username = presence.username, session_id = presence.session_id }
    end
  end

  local count = 0
  for _ in pairs(state.players) do count = count + 1 end
  if count == 2 then
    state.status = STATE_PLAYING
    dispatcher.match_label_update(nk.json_encode({ status = STATE_PLAYING }))
  end

  broadcast_state(dispatcher, state)
  return state
end

function M.match_loop(context, dispatcher, tick, state, messages)
  if state.status == STATE_WAITING or state.status == STATE_FINISHED then
    return state
  end
  for _, message in ipairs(messages) do
    if message.op_code == OP_MOVE then
      state = handle_move(context, dispatcher, tick, state, message)
    end
  end
  return state
end

function M.match_leave(context, dispatcher, tick, state, presences)
  for _, presence in ipairs(presences) do
    state.presences[presence.session_id] = nil
    if state.status == STATE_PLAYING then
      local winner_mark = nil
      for mark, info in pairs(state.players) do
        if info.session_id ~= presence.session_id then
          winner_mark = mark
          break
        end
      end
      state.status       = STATE_FINISHED
      state.winner       = winner_mark or "draw"
      state.winning_line = {}
      state.turn         = ""
      broadcast_state(dispatcher, state)
    end
  end
  return state
end

function M.match_terminate(context, dispatcher, tick, state, grace_seconds)
  broadcast_state(dispatcher, state)
  return state
end

function M.match_signal(context, dispatcher, tick, state, data)
  return state, data
end

return M
