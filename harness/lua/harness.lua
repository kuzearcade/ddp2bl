-- ddp2bl verification harness (MAME autoboot script)
--
-- Configuration comes from environment variables (set by harness/run.py):
--   DDP2H_MODE     "bot" (generate inputs, protected set only) or "replay"
--   DDP2H_INPUTS   bot: path to write the input log; replay: path to read it
--   DDP2H_SEED     bot RNG seed
--   DDP2H_CHEATS   comma list of cheat rule names (see targets/<t>/harness.lua)
--   DDP2H_STATE    path of a FIFO/file receiving per-frame state records
--   DDP2H_FRAMES   number of frames to run before exiting
--   DDP2H_TARGET   path of the per-target Lua description (RAM map, cheats, bot hints)
--   DDP2H_RELOC    "1" when running the converted set (shared RAM lives in main RAM)
--
-- State record per frame: "FRME" u32 frame, then for each section: u32 len + bytes.
-- Sections: canonical main RAM (128K, ARM shared window folded in), VRAM, palette,
-- video registers, Z80 RAM, screen pixels.

local machine = manager.machine
local cpu = machine.devices[":maincpu"]
local space = cpu.spaces["program"]
local screen = machine.screens[":screen"]

local env = os.getenv
local mode = env("DDP2H_MODE") or "replay"
local target = dofile(env("DDP2H_TARGET"))
local reloc = env("DDP2H_RELOC") == "1"
local max_frames = tonumber(env("DDP2H_FRAMES") or "0")

local state_out = env("DDP2H_STATE") and assert(io.open(env("DDP2H_STATE"), "wb"))

---------------------------------------------------------------------------
-- deterministic RNG (xorshift32) for the bot
---------------------------------------------------------------------------
local rng_state = tonumber(env("DDP2H_SEED") or "1") & 0xffffffff
if rng_state == 0 then rng_state = 1 end
local function rand()
  local x = rng_state
  x = x ~ ((x << 13) & 0xffffffff)
  x = x ~ (x >> 17)
  x = x ~ ((x << 5) & 0xffffffff)
  rng_state = x & 0xffffffff
  return rng_state
end

---------------------------------------------------------------------------
-- inputs: one record per frame {p12, p34, svc}; active low
---------------------------------------------------------------------------
local inputs = {}
local input_log
if mode == "bot" then
  input_log = assert(io.open(env("DDP2H_INPUTS"), "w"))
else
  for line in io.lines(env("DDP2H_INPUTS")) do
    local f, a, b, c = line:match("^(%d+) (%x+) (%x+) (%x+)$")
    if f then inputs[tonumber(f)] = { tonumber(a, 16), tonumber(b, 16), tonumber(c, 16) } end
  end
end

local cheats = {}
for name in (env("DDP2H_CHEATS") or ""):gmatch("[^,]+") do
  cheats[#cheats + 1] = assert(target.cheats[name], "unknown cheat " .. name)
end

local bot = (mode == "bot") and target.make_bot(space, rand) or nil
local cur = { 0xffff, 0xffff, 0xffff }
local last_frame = -1

local function inputs_for(frame)
  if frame == last_frame then return cur end
  last_frame = frame
  if mode == "bot" then
    cur = { bot(frame) }
    input_log:write(string.format("%d %04x %04x %04x\n", frame, cur[1], cur[2], cur[3]))
  else
    cur = inputs[frame] or { 0xffff, 0xffff, 0xffff }
  end
  return cur
end

-- Input ports: 0xc08000 P1P2, 0xc08002 P3P4, 0xc08004 Service (low byte), 0xc08006 DSW
in_tap = space:install_read_tap(0xc08000, 0xc08005, "ddp2h_in", function(offset, data, mask)
  local v = inputs_for(screen:frame_number())
  if offset == 0xc08000 then return v[1]
  elseif offset == 0xc08002 then return v[2]
  else return (data & 0xff00) | (v[3] & 0x00ff) end
end)

---------------------------------------------------------------------------
-- per-frame: cheats (applied identically in both runs), then state record
---------------------------------------------------------------------------
local function u32(n) return string.pack("<I4", n) end

local function section(s) state_out:write(u32(#s)); state_out:write(s) end

local function canonical_mainram()
  local ram = space:read_range(0x800000, 0x81ffff, 8)
  local w = target.reloc_window
  if not reloc then
    -- protected set: fold the ARM shared RAM into the (otherwise unused) relocation window,
    -- so both sets produce the same canonical image
    local shared = space:read_range(0xd00000, 0xd00000 + w.size - 1, 8)
    local off = w.base - 0x800000
    ram = ram:sub(1, off) .. shared .. ram:sub(off + w.size + 1)
  end
  return ram
end

fn_frame = emu.add_machine_frame_notifier(function()
  local frame = screen:frame_number()
  for _, c in ipairs(cheats) do c(space, frame) end
  if state_out then
    state_out:write("FRME" .. u32(frame))
    section(canonical_mainram())
    section(space:read_range(0x900000, 0x907fff, 8))
    section(space:read_range(0xa00000, 0xa013ff, 8))
    section(space:read_range(0xb00000, 0xb0ffff, 8))
    section(space:read_range(0xc10000, 0xc1ffff, 8))
    section(screen:pixels())
  end
  if max_frames > 0 and frame >= max_frames then
    if state_out then state_out:close(); state_out = nil end
    if input_log then input_log:close(); input_log = nil end
    machine:exit()
  end
end)
