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

T.cheats = {
  lives_p1  = pin_lives(P1_LIVES),
  lives_p2  = pin_lives(P1_LIVES + P2_OFS_LIVES),
  invuln_p1 = pin_invuln(P1_INVTIME, P1_LIVES),
  invuln_p2 = pin_invuln(P1_INVTIME + P2_OFS_OBJ, P1_LIVES + P2_OFS_LIVES),
}

-- Game-state agnostic random bot. Returns active-low words for P1P2, P3P4, Service.
-- DDP2H_BOT_PLAYERS = "1" or "2"; DDP2H_BOT_COINEVERY = frames between coins.
function T.make_bot(space, rand)
  local players = tonumber(os.getenv("DDP2H_BOT_PLAYERS") or "1")
  local coin_every = tonumber(os.getenv("DDP2H_BOT_COINEVERY") or "300")
  local pl = {}
  for p = 1, players do pl[p] = { dir = 0, dir_left = 0, fire_hold = true, fire_left = 0 } end
  local dirs = { 0, 0x02, 0x04, 0x08, 0x10, 0x0a, 0x12, 0x0c, 0x14 } -- none, U, D, L, R, diagonals
  return function(frame)
    local p12, svc = 0xffff, 0xffff
    if frame % coin_every < 4 then svc = svc & ~0x01 end
    if frame % coin_every >= 8 and frame % coin_every < 12 then svc = svc & ~0x02 end
    for p = 1, players do
      local s, sh = pl[p], (p - 1) * 8
      local bits = 0
      if frame % 120 >= 60 + p * 4 and frame % 120 < 63 + p * 4 then bits = bits | 0x01 end -- start / continue
      if s.dir_left <= 0 then s.dir = dirs[rand() % #dirs + 1]; s.dir_left = 5 + rand() % 40 end
      s.dir_left = s.dir_left - 1
      bits = bits | s.dir
      if s.fire_left <= 0 then s.fire_hold = (rand() % 4) ~= 0; s.fire_left = 10 + rand() % 120 end
      s.fire_left = s.fire_left - 1
      if s.fire_hold or (frame % 6) < 3 then bits = bits | 0x20 end         -- hold = laser, tap = shot
      if rand() % 900 == 0 then bits = bits | 0x40 end                      -- bomb, rarely
      if rand() % 3000 == 0 then bits = bits | 0x80 end                     -- button 3
      p12 = p12 & ~(bits << sh)
    end
    return p12, 0xffff, svc
  end
end

return T
