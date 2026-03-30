

local nk = require("nakama")
local M  = {}

-- ── Op-codes
local OP_MOVE    = 1   -- client → server
local OP_STATE   = 11  -- server → clients  (full state snapshot)
local OP_ERROR   = 12  -- server → client   (per-player error)
local OP_TIMER   = 13  -- server → clients  (remaining seconds)

-- ── Game constants
local STATE_WAITING  = "waiting"
local STATE_PLAYING  = "playing"
local STATE_FINISHED = "finished"

local TICK_RATE     = 5   -- ticks per second
local TURN_SECONDS  = 30  -- seconds per turn in timed mode

local function secs_to_ticks(s) return s * TICK_RATE end

local WINNING_LINES = {
  {0,1,2}, {3,4,5}, {6,7,8},   -- rows
  {0,3,6}, {1,4,7}, {2,5,8},   -- cols
  {0,4,8}, {2,4,6},             -- diagonals
}

-- ── Board helpers
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

-- ── Messaging helpers
local function build_state(state)
  return nk.json_encode({
    status       = state.status,
    board        = board_to_array(state.board),
    turn         = state.turn,
    players      = state.players,
    winner       = state.winner,
    winning_line = state.winning_line,
    move_count   = state.move_count,
    timed_mode   = state.timed_mode,
    turn_ends_at = state.turn_ends_at,   -- epoch-ms, 0 if not timed
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

local function broadcast_timer(dispatcher, remaining_secs)
  dispatcher.broadcast_message(
    OP_TIMER,
    nk.json_encode({ remaining_seconds = remaining_secs }),
    nil, nil, true
  )
end

-- ── Stat / leaderboard persistence
local LEADERBOARD_ID = "tictactoe_global"

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

    -- Read existing stats
    local reads  = {{ collection = "player_stats", key = "tictactoe", user_id = info.id }}
    local ok, records = pcall(nk.storage_read, reads)
    local stats  = { wins = 0, losses = 0, draws = 0, score = 0 }
    if ok and records and records[1] then
      local decoded = nk.json_decode(records[1].value)
      if decoded then stats = decoded end
    end

    -- Update counters & score
    local delta = 0
    if outcome == "win" then
      stats.wins  = (stats.wins  or 0) + 1
      delta       = 200
    elseif outcome == "loss" then
      stats.losses = (stats.losses or 0) + 1
      delta        = -50
    else
      stats.draws = (stats.draws or 0) + 1
      delta       = 50
    end
    stats.score = math.max(0, (stats.score or 0) + delta)

    table.insert(writes, {
      collection       = "player_stats",
      key              = "tictactoe",
      user_id          = info.id,
      value            = nk.json_encode(stats),
      permission_read  = 2,
      permission_write = 0,
    })

    -- Write to global leaderboard (best score, operator = set if higher)
    -- Nakama leaderboard_write_score uses "best" by default when created with
    -- operator BEST. We write absolute score so rank = highest score.
    local lok, lerr = pcall(nk.leaderboard_write_score,
      LEADERBOARD_ID, info.id, stats.score, 0, "set")
    if not lok then
      nk.logger_warn("leaderboard_write_score failed: " .. tostring(lerr))
    end
  end

  local wok, werr = pcall(nk.storage_write, writes)
  if not wok then
    nk.logger_error("record_result storage write failed: " .. tostring(werr))
  end
end

-- ── Finish game helper
local function finish_game(dispatcher, state, winner, winning_line, reason)
  state.status       = STATE_FINISHED
  state.winner       = winner
  state.winning_line = winning_line or {}
  state.turn         = ""
  state.timer_ticks  = 0
  state.turn_ends_at = 0
  record_result(state)
  nk.logger_info(string.format("game over: winner=%s reason=%s", tostring(winner), tostring(reason or "normal")))
  broadcast_state(dispatcher, state)
  return state
end

-- ── Move handler
local function handle_move(context, dispatcher, tick, state, message)
  local sender = message.sender

  if state.status ~= STATE_PLAYING then
    send_error(dispatcher, sender, "GAME_NOT_ACTIVE", "No active game.")
    return state
  end

  -- Identify which mark (X / O) the sender holds
  local sender_mark = nil
  for mark, info in pairs(state.players) do
    if info.session_id == sender.session_id then
      sender_mark = mark
      break
    end
  end

  if not sender_mark then
    send_error(dispatcher, sender, "NOT_A_PLAYER", "You are not in this match.")
    return state
  end

  if state.turn ~= sender_mark then
    send_error(dispatcher, sender, "NOT_YOUR_TURN", "It is " .. state.turn .. "'s turn.")
    return state
  end

  -- Parse payload
  local ok, data = pcall(nk.json_decode, message.data)
  if not ok or type(data) ~= "table" then
    send_error(dispatcher, sender, "INVALID_PAYLOAD", "Payload must be valid JSON.")
    return state
  end

  local pos = data.position
  if type(pos) ~= "number" then
    send_error(dispatcher, sender, "INVALID_POSITION", "position must be a number.")
    return state
  end

  pos = math.floor(pos)
  if pos < 0 or pos > 8 then
    send_error(dispatcher, sender, "OUT_OF_BOUNDS", "position must be 0–8.")
    return state
  end

  if state.board[pos] ~= "" then
    send_error(dispatcher, sender, "CELL_OCCUPIED", "Cell " .. pos .. " is already taken.")
    return state
  end

  -- Apply move
  state.board[pos] = sender_mark
  state.move_count = state.move_count + 1
  nk.logger_info(string.format("move: %s placed %s at %d (move #%d)",
    sender.username, sender_mark, pos, state.move_count))

  -- Reset turn timer
  if state.timed_mode then
    state.timer_ticks  = secs_to_ticks(TURN_SECONDS)
    state.turn_ends_at = nk.time() + TURN_SECONDS * 1000
  end

  -- Check win / draw
  local result, winning_line = check_result(state.board)
  if result then
    return finish_game(dispatcher, state, result, winning_line)
  end

  -- Flip turn
  state.turn = (sender_mark == "X") and "O" or "X"
  broadcast_state(dispatcher, state)
  return state
end

-- ── Match lifecycle 

--[[
  match_init
  Called once when the match is created.
  setupstate comes from nk.match_create() params — used to pass timed_mode flag.
--]]
function M.match_init(context, setupstate)
  local params = {}
  if setupstate and setupstate ~= "" then
    local ok, p = pcall(nk.json_decode, setupstate)
    if ok and type(p) == "table" then params = p end
  end

  local timed = params.timed_mode == true

  local state = {
    status       = STATE_WAITING,
    board        = new_board(),
    players      = {},
    presences    = {},
    turn         = "X",
    winner       = "",
    winning_line = {},
    move_count   = 0,
    -- timer
    timed_mode   = timed,
    timer_ticks  = timed and secs_to_ticks(TURN_SECONDS) or 0,
    turn_ends_at = 0,
  }

  local label = nk.json_encode({ status = STATE_WAITING, timed_mode = timed })
  return state, TICK_RATE, label
end

--[[
  match_join_attempt
  Authorise (or reject) a player before they fully join.
  Rejects: match full, game finished, or same user already in match.
--]]
function M.match_join_attempt(context, dispatcher, tick, state, presence, metadata)
  -- Count current players
  local count = 0
  for _ in pairs(state.players) do count = count + 1 end

  if count >= 2 then
    return state, false, "Match is full."
  end
  if state.status == STATE_FINISHED then
    return state, false, "Match has already ended."
  end

  -- Prevent same user joining twice (e.g. reconnect race)
  for _, info in pairs(state.players) do
    if info.id == presence.user_id then
      return state, false, "You are already in this match."
    end
  end

  return state, true
end

--[[
  match_join
  Assigns X / O and starts the game when both players are seated.
--]]
function M.match_join(context, dispatcher, tick, state, presences)
  for _, presence in ipairs(presences) do
    state.presences[presence.session_id] = presence

    if not state.players["X"] then
      state.players["X"] = {
        id         = presence.user_id,
        username   = presence.username,
        session_id = presence.session_id,
      }
      nk.logger_info("Player " .. presence.username .. " joined as X")
    elseif not state.players["O"] then
      state.players["O"] = {
        id         = presence.user_id,
        username   = presence.username,
        session_id = presence.session_id,
      }
      nk.logger_info("Player " .. presence.username .. " joined as O")
    end
  end

  -- Start game if both seats filled
  local count = 0
  for _ in pairs(state.players) do count = count + 1 end
  if count == 2 and state.status == STATE_WAITING then
    state.status = STATE_PLAYING

    -- Arm timer for first turn
    if state.timed_mode then
      state.timer_ticks  = secs_to_ticks(TURN_SECONDS)
      state.turn_ends_at = nk.time() + TURN_SECONDS * 1000
    end

    local label = nk.json_encode({ status = STATE_PLAYING, timed_mode = state.timed_mode })
    dispatcher.match_label_update(label)
    nk.logger_info("Match started")
  end

  broadcast_state(dispatcher, state)
  return state
end

--[[
  match_loop
  Called every tick.
  • Dispatches incoming OP_MOVE messages to handle_move.
  • Counts down timer ticks and triggers auto-forfeit when expired.
--]]
function M.match_loop(context, dispatcher, tick, state, messages)
  -- Nothing to do until game is active
  if state.status ~= STATE_PLAYING then
    return state
  end

  -- Process incoming moves
  for _, message in ipairs(messages) do
    if message.op_code == OP_MOVE then
      state = handle_move(context, dispatcher, tick, state, message)
    end
  end

  -- Timer countdown (timed mode only)
  if state.timed_mode and state.timer_ticks > 0 and state.status == STATE_PLAYING then
    state.timer_ticks = state.timer_ticks - 1

    -- Broadcast remaining time every second (every TICK_RATE ticks)
    if state.timer_ticks % TICK_RATE == 0 then
      local remaining = math.floor(state.timer_ticks / TICK_RATE)
      broadcast_timer(dispatcher, remaining)
    end

    -- Time expired → forfeit current turn's player; opponent wins
    if state.timer_ticks == 0 then
      local loser_mark  = state.turn
      local winner_mark = (loser_mark == "X") and "O" or "X"
      nk.logger_info(string.format("turn timeout: %s forfeits, %s wins", loser_mark, winner_mark))
      state = finish_game(dispatcher, state, winner_mark, {}, "timeout")
    end
  end

  return state
end

--[[
  match_leave
  A player disconnected or left voluntarily.
  • If the game was in progress → opponent wins by walkover.
  • Stats are recorded.
--]]
function M.match_leave(context, dispatcher, tick, state, presences)
  for _, presence in ipairs(presences) do
    state.presences[presence.session_id] = nil
    nk.logger_info("Player left: " .. tostring(presence.username))

    if state.status == STATE_PLAYING then
      -- Find the mark that belongs to the player who LEFT
      local leaver_mark = nil
      for mark, info in pairs(state.players) do
        if info.session_id == presence.session_id then
          leaver_mark = mark
          break
        end
      end

      local winner_mark = nil
      if leaver_mark then
        winner_mark = (leaver_mark == "X") and "O" or "X"
      end

      state = finish_game(dispatcher, state,
        winner_mark or "draw", {}, "disconnect")
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
