-- Target description for the verification harness: DoDonPachi II (World, ver. 102)
local T = {}

-- Main RAM window that receives the relocated IGS027A shared RAM in the converted set.
-- Must match targets/ddp2_v102_world/target.json ("reloc_window").
local json_path = debug.getinfo(1, "S").source:sub(2):gsub("harness%.lua$", "target.json")
do
  local s = io.open(json_path):read("a")
  local base = tonumber(s:match('"reloc_base"%s*:%s*"0x(%x+)"'), 16)
  local size = tonumber(s:match('"reloc_size"%s*:%s*"0x(%x+)"'), 16)
  T.reloc_window = { base = base, size = size }
  T.hlev = { base = tonumber(s:match('"hlev_base"%s*:%s*"0x(%x+)"'), 16),
             size = tonumber(s:match('"hlev_size"%s*:%s*"0x(%x+)"'), 16) }
  T.stack_floor = tonumber(s:match('"stack_floor"%s*:%s*"0x(%x+)"'), 16)
  T.frame_counter = tonumber(s:match('"frame_counter"%s*:%s*"0x(%x+)"'), 16)
end

-- RAM map (68k addresses), found by analysis of v102 World:
local P1_LIVES   = 0x815a74 -- byte, 3 at game start, 0 = last life lost
local P1_INVTIME = 0x812600 -- word, respawn invulnerability timer (0xea on respawn, counts down)
local P2_OFS_LIVES, P2_OFS_OBJ = 0x14, 0x114

local function pin_lives(base)
  return function(space, frame)
    local v = space:read_u8(base)
    if v == 1 or v == 2 then space:write_u8(base, 3) end
  end
end

local function pin_invuln(base, lives)
  return function(space, frame)
    -- only while that player is in a game (lives > 0), so attract/demo state is untouched
    if space:read_u8(lives) > 0 then space:write_u16(base, 0x00ea) end
  end
end

-- Player 2's object is P2_OFS_OBJ2 after player 1's (code at $16F18E and the object
-- layout); P2_OFS_OBJ (0x114) was a wrong guess: invuln_p2 writes into the middle of
-- player 2's object and does not protect player 2. It is kept unchanged so that the
-- recorded sessions that used it replay exactly.
local P2_OFS_OBJ2 = 0x192
local DEBUT_LIFE = 0x803808 -- byte: starting lives; the game asserts cntLife <= it on a miss

-- lives3: lives held at the starting count (extends are taken back), so the game's
-- assertion "p->cntLife <= RV_DEBUTLIFE" (cplayer.c) can never fire
local function hold_lives(base)
  return function(space, frame)
    local v, d = space:read_u8(base), space:read_u8(DEBUT_LIFE)
    if v > 0 and v ~= d then space:write_u8(base, d) end
  end
end

T.cheats = {
  lives_p1   = pin_lives(P1_LIVES),
  lives_p2   = pin_lives(P1_LIVES + P2_OFS_LIVES),
  invuln_p1  = pin_invuln(P1_INVTIME, P1_LIVES),
  invuln_p2  = pin_invuln(P1_INVTIME + P2_OFS_OBJ, P1_LIVES + P2_OFS_LIVES),  -- wrong address, see above
  lives3_p1  = hold_lives(P1_LIVES),
  lives3_p2  = hold_lives(P1_LIVES + P2_OFS_LIVES),
  invuln2_p2 = pin_invuln(P1_INVTIME + P2_OFS_OBJ2, P1_LIVES + P2_OFS_LIVES),
}

-- Game-state agnostic random bot. Returns active-low words for P1P2, P3P4, Service.
-- DDP2H_BOT_PLAYERS = "1" or "2"; DDP2H_BOT_COINEVERY = frames between coins.
function T.make_bot(space, rand)
  local players = tonumber(os.getenv("DDP2H_BOT_PLAYERS") or "1")
  local coin_every = tonumber(os.getenv("DDP2H_BOT_COINEVERY") or "300")
  local pl = {}
  for p = 1, players do pl[p] = { dir = 0, dir_left = 0, fire_hold = true, fire_left = 0 } end
  local dirs = { 0, 0x02, 0x04, 0x08, 0x10, 0x0a, 0x12, 0x0c, 0x14 } -- none, U, D, L, R, diagonals
  local quiet = tonumber(os.getenv("DDP2H_BOT_QUIET") or "600")
  local style = os.getenv("DDP2H_BOT_STYLE") or "random" -- no inputs while the BIOS boots
  return function(frame)
    local p12, svc = 0xffff, 0xffff
    if frame < quiet then return p12, 0xffff, svc end
    if frame % coin_every < 4 then svc = svc & ~0x01 end
    if frame % coin_every >= 8 and frame % coin_every < 12 then svc = svc & ~0x02 end
    for p = 1, players do
      local s, sh = pl[p], (p - 1) * 8
      local bits = 0
      if frame % 120 >= 60 + p * 4 and frame % 120 < 63 + p * 4 then bits = bits | 0x01 end -- start / continue
      if (style == "aim" or style == "max") and space:read_u8(P1_LIVES + (p - 1) * P2_OFS_LIVES) > 0 then
        -- steer to the screen's centre column, a fixed distance from the bottom, with jitter
        local obj = 0x812566 + (p - 1) * (style == "max" and P2_OFS_OBJ2 or P2_OFS_OBJ)
        local u = space:read_i16(obj)        -- up/down axis   (32..191, centre ~112)
        local v = space:read_i16(obj + 2)    -- left/right axis
        local tu = 112 + ((frame // 97) % 5 - 2) * 12
        local tv = 85 + ((frame // 131) % 3) * 15 + (style == "max" and (p - 1) * 50 or 0)
        if u < tu - 4 then bits = bits | 0x02 elseif u > tu + 4 then bits = bits | 0x04 end
        if v < tv - 4 then bits = bits | 0x10 elseif v > tv + 4 then bits = bits | 0x08 end
        s.fire_hold = true
      else
        if s.dir_left <= 0 then s.dir = dirs[rand() % #dirs + 1]; s.dir_left = 5 + rand() % 40 end
        s.dir_left = s.dir_left - 1
        bits = bits | s.dir
      end
      if style == "max" then
        -- maximum screen load: shot on autofire all the time (2 frames pressed, 2 released),
        -- bomb pressed every ~1.5 s (each player in its own phase), so every bomb in stock
        -- is used as soon as the previous one is over
        if (frame % 4) < 2 then bits = bits | 0x20 end
        if (frame + p * 45) % 90 < 4 then bits = bits | 0x40 end
      else
        if s.fire_left <= 0 then s.fire_hold = (rand() % 4) ~= 0; s.fire_left = 10 + rand() % 120 end
        s.fire_left = s.fire_left - 1
        if s.fire_hold or (frame % 6) < 3 then bits = bits | 0x20 end       -- hold = laser, tap = shot
        if rand() % 900 == 0 then bits = bits | 0x40 end                    -- bomb, rarely
        if rand() % 3000 == 0 then bits = bits | 0x80 end                   -- button 3
      end
      p12 = p12 & ~(bits << sh)
    end
    return p12, 0xffff, svc
  end
end

return T
