# Nakama Tic-Tac-Toe — Backend

Server-authoritative multiplayer Tic-Tac-Toe built on [Nakama](https://heroiclabs.com/nakama/).
All game logic runs on the server. The frontend is a single HTML file that sends moves and displays state.

---

## Directory Structure

```
Tic-Tac-Toe-backend/
├── docker-compose.yml       Local dev stack (Nakama + Postgres)
├── index.html               Frontend test client (no framework, plain JS)
└── modules/
    ├── main.lua             Entry point: registers match handler + all RPCs
    ├── tictactoe.lua        Authoritative match handler (all game logic)
    ├── matchmaking.lua      RPC endpoints for creating and finding matches
    └── leaderboard.lua      RPC endpoints for rankings and player stats
```

---

## Architecture

```
Client A (X)                Nakama Server                Client B (O)
    │                            │                            │
    │── authenticate ──────────► │                            │
    │                            │ ◄─────────── authenticate ─│
    │── RPC: rpc_find_match ───► │                            │
    │                            │ ◄──── RPC: rpc_find_match ─│
    │                            │                            │
    │                    nk.match_create("tictactoe")         │
    │                            │                            │
    │── socket.joinMatch ──────► │ ◄─────── socket.joinMatch ─│
    │                       match_join (assign X / O)         │
    │ ◄──────────────── OP_STATE (board + turn) ─────────────►│
    │                            │                            │
    │── OP_MOVE {position:4} ──► │                            │
    │                       validate move (7 checks)          │
    │                       apply to board                    │
    │                       check win / draw                  │
    │ ◄──────────────── OP_STATE (updated board) ────────────►│
    │                            │                            │
```

**Rule**: the server is the single source of truth. A client that sends an invalid
move receives an `OP_ERROR` message; the board does not change.

---

## Local Setup & Installation

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) + Docker Compose
- [Python 3](https://www.python.org/) (to serve the frontend)

### 1. Clone the repository

```bash
git clone https://github.com/immortalAbdul01/Tic-Tac-Toe-backend-
cd Tic-Tac-Toe-backend-
```

### 2. Start the Nakama backend

```bash
docker compose up
```

This starts two containers:
- **Postgres** — database for Nakama
- **Nakama** — game server with your Lua modules loaded from `./modules/`

Wait until you see this line in the logs:
```
{"msg":"Startup done"}
```

| Service         | URL                          |
|-----------------|------------------------------|
| Nakama API      | http://localhost:7350        |
| Nakama Console  | http://localhost:7351        |

Console login: `admin` / `admin`

### 3. Verify modules loaded correctly

Open http://localhost:7351 → **Runtime** in the sidebar.

Under **Lua RPC Functions** you should see all 6 RPCs:
- `rpc_create_match`
- `rpc_find_match`
- `rpc_join_match`
- `rpc_list_matches`
- `rpc_get_leaderboard`
- `rpc_get_my_stats`

If they appear, the backend is running correctly. ✅

---

## Running the Frontend

The frontend is a single file — `index.html`. It uses no framework and no build step.

### Serve it with Python

```bash
# Run this command in the project root (where index.html lives)
python -m http.server 8080
```

Then open **http://localhost:8080** in your browser.

> **Why not just open the file directly?**
> Browsers block WebSocket connections from `file://` URLs. Serving over HTTP avoids this.

---

## Testing Multiplayer Locally

1. Make sure Nakama is running (`docker compose up`)
2. Run `python -m http.server 8080` in the project folder
3. Open **two browser tabs** at http://localhost:8080

**Tab 1 (Player 1):**
- Host: `localhost`, Port: `7350`
- Username: `player1`, Password: `password`
- Click **Connect**
- Click **Auto Find / Create Match** — creates a new match and waits

**Tab 2 (Player 2):**
- Username: `player2`, Password: `password`
- Click **Connect**
- Click **Auto Find / Create Match** — joins Player 1's match automatically

Both tabs now show `status: playing`. Player 1 is **X**, Player 2 is **O**.

4. Click any board cell on your turn
5. Try clicking out of turn — you'll see `NOT_YOUR_TURN` in the log
6. Win the game — scores are saved automatically
7. Click **My Stats** or **Leaderboard** to verify persistence

---

## Design Decisions

### Server-Authoritative Architecture
All game logic (turn validation, win detection, score updates) runs exclusively on the server in `tictactoe.lua`. The client only sends a position number and renders whatever state the server broadcasts. There is no client-side game logic to exploit.

### Match Handler Pattern
Nakama's Lua runtime resolves `nk.match_create("tictactoe")` by loading `tictactoe.lua` and calling the returned handler table. This means the match lifecycle (`match_init`, `match_join`, `match_loop`, `match_leave`) is fully encapsulated in one file.

### Matchmaking Flow
Rather than Nakama's built-in matchmaker, we use a simple RPC-based flow:
1. `rpc_find_match` scans for existing `waiting` matches via `nk.match_list`
2. If one exists → return its ID (player joins existing room)
3. If none → create a new match and return its ID

This supports both auto-pairing and manual room joining.

### Scoring System
| Outcome | Score Delta |
|---------|-------------|
| Win     | +200        |
| Draw    | +50         |
| Loss    | −50 (min 0) |

Scores are persisted in Nakama storage (`player_stats / tictactoe`) and also written to a global leaderboard (`tictactoe_global`) for ranking.

---

## Message Protocol

### Client → Server

| Field     | Type   | Value                        |
|-----------|--------|------------------------------|
| `op_code` | int    | `1` (OP_MOVE)                |
| `data`    | string | Base64 JSON: `{"position":4}`|

### Server → Client

#### OP_STATE (11) — full game snapshot (broadcast to all players)

```jsonc
{
  "status":       "playing",        // "waiting" | "playing" | "finished"
  "board":        ["X","","","","O","","","",""],  // 9 elements, "" = empty
  "turn":         "X",              // "X" | "O" | "" (game over)
  "players": {
    "X": { "id": "uuid", "username": "player1", "session_id": "..." },
    "O": { "id": "uuid", "username": "player2", "session_id": "..." }
  },
  "winner":       "",               // "X" | "O" | "draw" | ""
  "winning_line": [],               // e.g. [0,1,2] or [] if draw/ongoing
  "move_count":   3,
  "timed_mode":   false,
  "turn_ends_at": 0                 // epoch-ms deadline (timed mode only)
}
```

#### OP_ERROR (12) — sent only to the offending client

```jsonc
{ "code": "NOT_YOUR_TURN", "message": "It is O's turn." }
```

**Error codes**

| Code               | Meaning                          |
|--------------------|----------------------------------|
| `GAME_NOT_ACTIVE`  | Move sent before game started    |
| `NOT_A_PLAYER`     | Sender is not in this match      |
| `NOT_YOUR_TURN`    | Wrong player sent a move         |
| `INVALID_PAYLOAD`  | JSON parse error                 |
| `INVALID_POSITION` | `position` is not a number       |
| `OUT_OF_BOUNDS`    | `position` outside 0–8           |
| `CELL_OCCUPIED`    | Target cell already filled       |

#### OP_TIMER (13) — timed mode only, broadcast every second

```jsonc
{ "remaining_seconds": 24 }
```

---

## RPC Reference

All RPCs require a Bearer token in the `Authorization` header.

| RPC ID                | Method | Request Payload          | Response                              |
|-----------------------|--------|--------------------------|---------------------------------------|
| `rpc_find_match`      | POST   | `{"timed_mode": false}`  | `{"success":true,"data":{"match_id":"..."}}` |
| `rpc_create_match`    | POST   | `{"timed_mode": false}`  | `{"success":true,"data":{"match_id":"..."}}` |
| `rpc_join_match`      | POST   | `{"match_id":"..."}`     | `{"success":true,"data":{"match_id":"..."}}` |
| `rpc_list_matches`    | POST   | `{}`                     | `{"success":true,"data":{"matches":[...]}}` |
| `rpc_get_leaderboard` | POST   | `{"limit": 10}`          | `{"success":true,"data":{"records":[...]}}` |
| `rpc_get_my_stats`    | POST   | `{}`                     | `{"success":true,"data":{"wins":n,...}}` |

### Quick smoke test (curl)

```bash
# 1. Authenticate
TOKEN=$(curl -s -X POST http://localhost:7350/v2/account/authenticate/email?create=true&username=testuser \
  -H "Authorization: Basic $(echo -n 'defaultkey:' | base64)" \
  -H "Content-Type: application/json" \
  -d '{"email":"testuser@test.com","password":"password"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# 2. Find or create a match
curl -X POST "http://localhost:7350/v2/rpc/rpc_find_match?unwrap" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '"{\"timed_mode\":false}"'

# 3. Get leaderboard
curl -X POST "http://localhost:7350/v2/rpc/rpc_get_leaderboard?unwrap" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '"{\"limit\":10}"'
```

---

## Server-Side Validation

Every move passes through these 7 checks before the board is mutated:

1. **Game active** — `status == "playing"`
2. **Registered player** — `session_id` maps to a seat (X or O)
3. **Correct turn** — sender's mark matches `state.turn`
4. **Valid JSON** — payload parses without error
5. **Numeric position** — `position` field is a number
6. **In bounds** — `0 ≤ position ≤ 8`
7. **Cell empty** — `board[position] == ""`

Only after all seven checks pass is the board mutated and state broadcast.

---

## Storage Schema

| Collection     | Key         | Scope    | Contents                             |
|----------------|-------------|----------|--------------------------------------|
| `player_stats` | `tictactoe` | per user | `{ wins, losses, draws, score }`     |

- **Read permission**: public (any authenticated user can read)
- **Write permission**: server-only (clients cannot tamper with stats)

Scores are also mirrored to the `tictactoe_global` Nakama leaderboard for global ranking.

---

## Optional Features Implemented

| Feature                  | Status |
|--------------------------|--------|
| Server-authoritative logic | ✅   |
| Auto matchmaking           | ✅   |
| Concurrent match support   | ✅   |
| Player disconnect handling | ✅   |
| Leaderboard system         | ✅   |
| Score persistence          | ✅   |
| Timed mode (30s/turn)      | ✅   |
| Auto-forfeit on timeout    | ✅   |

---

## Restarting After Module Changes

```bash
docker compose restart nakama
```

Modules in `./modules/` are loaded at startup. Any change to a `.lua` file requires a restart.
