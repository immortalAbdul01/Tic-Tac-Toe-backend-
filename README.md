# Nakama Tic-Tac-Toe — Backend

Server-authoritative multiplayer Tic-Tac-Toe built on [Nakama](https://heroiclabs.com/nakama/).
All game logic runs on the server. The frontend is a thin renderer that sends moves and displays state.

---

## Directory structure

```
nakama-tictactoe/
├── docker-compose.yml       Local dev stack (Nakama + Postgres)
└── modules/
    ├── main.lua             Entry point: registers match handler + RPCs
    └── match.lua            Authoritative match handler (all game logic)
```

---

## Architecture

```
Client A (X)                Nakama Server                Client B (O)
    │                            │                            │
    │── authenticate ──────────► │                            │
    │                            │ ◄─────────── authenticate ─│
    │── RPC: find_or_create ───► │                            │
    │                            │ ◄─── RPC: find_or_create ──│
    │                            │                            │
    │                    matchmaker_matched                    │
    │                    nk.match_create("tictactoe")         │
    │                            │                            │
    │── socket.joinMatch ──────► │ ◄─────── socket.joinMatch ─│
    │                       match_join (assign X / O)         │
    │ ◄──────────────── OP_STATE (board + turn) ─────────────►│
    │                            │                            │
    │── OP_MOVE {position:4} ──► │                            │
    │                       validate move                     │
    │                       apply to board                    │
    │                       check win/draw                    │
    │ ◄──────────────── OP_STATE (new board) ────────────────►│
    │                            │                            │
```

**Rule**: the server is the single source of truth. A client that sends an invalid
move receives an `OP_ERROR` message; the board does not change.

---

## Message protocol

### Client → Server

| Field      | Type   | Value |
|------------|--------|-------|
| `op_code`  | int    | `1` (OP_MOVE) |
| `data`     | string | JSON: `{ "position": <0-8> }` |

Example (nakama-js):
```js
socket.sendMatchState(matchId, 1, JSON.stringify({ position: 4 }));
```

### Server → Client (broadcast)

#### OP_STATE (11) — full game snapshot

```jsonc
{
  "status": "playing",        // "waiting" | "playing" | "finished"
  "board":  ["X","","","","O","","","",""],  // 9-element array, "" = empty
  "turn":   "X",              // whose turn: "X" | "O" | "" (game over)
  "players": {
    "X": { "id": "uuid", "username": "Alice", "session_id": "..." },
    "O": { "id": "uuid", "username": "Bob",   "session_id": "..." }
  },
  "winner":       "",         // "X" | "O" | "draw" | ""
  "winning_line": [],         // e.g. [0,1,2] or [] if draw/ongoing
  "move_count":   3
}
```

#### OP_ERROR (12) — validation failure (sent only to the offending client)

```jsonc
{
  "code":    "NOT_YOUR_TURN",
  "message": "It is O's turn, not yours."
}
```

**Error codes**

| Code              | Meaning                        |
|-------------------|--------------------------------|
| `GAME_NOT_ACTIVE` | Move sent when game isn't live |
| `NOT_A_PLAYER`    | Sender is a spectator          |
| `NOT_YOUR_TURN`   | Wrong player sent a move       |
| `INVALID_PAYLOAD` | JSON parse error               |
| `INVALID_POSITION`| `position` is not a number     |
| `OUT_OF_BOUNDS`   | `position` outside 0–8         |
| `CELL_OCCUPIED`   | Target cell already filled     |

---

## Server-side validation checklist

Every move passes through these guards in order before the board is mutated:

1. **Game active** — `status == "playing"`
2. **Registered player** — session_id maps to a seat (X or O)
3. **Correct turn** — sender's mark == `state.turn`
4. **Valid JSON** — payload parses without error
5. **Numeric position** — `position` field is a number
6. **In bounds** — `0 ≤ position ≤ 8`
7. **Cell empty** — `board[position] == ""`

Only after all seven checks pass is the board mutated.

---

## RPC reference

| RPC name              | Auth required | Request payload        | Response |
|-----------------------|---------------|------------------------|----------|
| `find_or_create_match`| ✅            | `{}`                   | `{ "ticket": "..." }` |
| `get_player_stats`    | ✅            | `{}`                   | `{ "wins":n, "losses":n, "draws":n, "score":n }` |
| `get_leaderboard`     | ✅            | `{ "limit": 10 }`      | `{ "records": [...] }` |

---

## Local development

### Prerequisites
- Docker + Docker Compose

### Start the stack

```bash
docker compose up
```

- Nakama API:     http://localhost:7350
- Nakama Console: http://localhost:7351  (admin/admin)

Lua modules in `./modules/` are hot-reloaded when Nakama restarts.
During development restart with: `docker compose restart nakama`

### Quick smoke test (curl)

```bash
# 1. Authenticate (device auth — no account needed)
curl -X POST http://localhost:7350/v2/account/authenticate/device \
  -u "defaultkey:" \
  -H "Content-Type: application/json" \
  -d '{"id":"test-device-001","create":true}'
# → copy the "token" field

# 2. Call find_or_create_match
curl -X POST http://localhost:7350/v2/rpc/find_or_create_match \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"payload":"{}"}'
```

---

## Cloud deployment (DigitalOcean example)

```bash
# 1. Provision a droplet and install Docker
# 2. Copy project to server
scp -r nakama-tictactoe/ root@<server-ip>:/opt/tictactoe

# 3. (Production) set env vars for secrets
export NAKAMA_DB_PASSWORD="<strong-password>"

# 4. Start
ssh root@<server-ip>
cd /opt/tictactoe
docker compose -f docker-compose.yml up -d

# 5. Point your frontend SDK at:
#    http://<server-ip>:7350
```

For TLS in production, place Nakama behind nginx with Let's Encrypt.

---

## Storage schema

| Collection      | Key          | Scope       | Contents                          |
|-----------------|--------------|-------------|-----------------------------------|
| `player_stats`  | `tictactoe`  | per user    | `{ wins, losses, draws, score }` |

Read permission: **public** (any authenticated user can read any player's stats).
Write permission: **server-only** (clients cannot tamper with stats).

---

## Testing multiplayer locally

1. Open two browser tabs (or two terminal sessions with the JS SDK).
2. Authenticate each as a different device ID.
3. Both call `find_or_create_match` — the matchmaker pairs them and creates a match.
4. Both connect to the returned match via `socket.joinMatch(matchId)`.
5. The player assigned **X** sends the first move: `{ "position": 4 }`.
6. Observe `OP_STATE` broadcast to both clients with the updated board.
7. Try sending a move out of turn — verify you receive `OP_ERROR NOT_YOUR_TURN` and the board is unchanged.
