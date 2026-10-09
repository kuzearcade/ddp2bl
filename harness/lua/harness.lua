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
-- All memory is read from MAME memory shares (share:read_raw, added in the ddp2bl MAME
-- branch) so the observer has no side effects: e.g. reading Z80 RAM through the 68k bus
-- forces a CPU sync and changes emulation timing. Raw share bytes are host order
-- (68k word n = little-endian halfword at byte n), identically for every share.

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

local shares = machine.memory.shares
local function share(tag) return assert(shares[tag], "missing share " .. tag) end
local sh_main = share(":sram")
local sh_arm = (not reloc) and share(":arm7_shareram") or nil
local sh_vram = { share(":igs023:bg_videoram"), share(":igs023:tx_videoram"), share(":igs023:rowscrollram") }
local sh_pal = share(":palette")
local sh_spr, sh_zoom = share(":igs023:spritebuffer"), share(":igs023:zoomram")
local sh_z80 = share(":z80_mainram")

local function splice(ram, addr, bytes)
  local off = addr - 0x800000
  return ram:sub(1, off) .. bytes .. ram:sub(off + #bytes + 1)
end

-- Canonical main RAM image, identical between the protected and the converted set:
--  * protected set: the ARM shared RAM is folded into the relocation window (which the
--    protected game never uses), so both sets show the same bytes there;
--  * the converted set's private ARM-replacement state (target.hlev) is masked in both;
--  * dead stack between target.stack_floor and the live SP is masked in both (interrupts
--    landing at different instructions leave different garbage there; nothing reads it).
local function canonical_mainram()
  local ram = sh_main:read_raw(0, 0x20000)
  local w = target.reloc_window
  if not reloc then
    ram = splice(ram, w.base, sh_arm:read_raw(0, w.size))
  end
  ram = splice(ram, target.hlev.base, string.rep("\0", target.hlev.size))
  local sp = cpu.state["SP"].value & 0xffffff
  if sp > target.stack_floor and sp <= 0x820000 then
    ram = splice(ram, target.stack_floor, string.rep("\0", sp - target.stack_floor))
  end
  return ram
end

local function vregs()
  -- scroll/zoom/control registers: plain register reads without side effects
  local t = {}
  for _, a in ipairs({ 0xb02000, 0xb03000, 0xb04000, 0xb05000, 0xb06000, 0xb0e000 }) do
    t[#t + 1] = string.pack("<I2", space:read_u16(a))
  end
  return sh_spr:read_raw(0, sh_spr.size) .. sh_zoom:read_raw(0, sh_zoom.size) .. table.concat(t)
end

-- optional instruction trace of the 68000 (needs -debug): DDP2H_TRACE="first,last,path"
local trace_first, trace_last, trace_path
do
  local t = env("DDP2H_TRACE")
  if t then
    local a, b, p = t:match("^(%d+),(%d+),(.+)$")
    trace_first, trace_last, trace_path = tonumber(a), tonumber(b), p
  end
end

fn_frame = emu.add_machine_frame_notifier(function()
  local frame = screen:frame_number()
  if trace_first and frame == trace_first then
    machine.debugger:command("trace " .. trace_path .. ",maincpu,noloop")
  elseif trace_first and frame == trace_last then
    machine.debugger:command("trace off,maincpu")
  end
  for _, c in ipairs(cheats) do c(space, frame) end
  if state_out then
    state_out:write("FRME" .. u32(frame))
    section(canonical_mainram())
    section(sh_vram[1]:read_raw(0, sh_vram[1].size) .. sh_vram[2]:read_raw(0, sh_vram[2].size) .. sh_vram[3]:read_raw(0, sh_vram[3].size))
    section(sh_pal:read_raw(0, sh_pal.size))
    section(vregs())
    section(sh_z80:read_raw(0, sh_z80.size))
    section(screen:pixels())
  end
  if max_frames > 0 and frame >= max_frames then
    if state_out then state_out:close(); state_out = nil end
    if input_log then input_log:close(); input_log = nil end
    machine:exit()
  end
end)

-- optional extra analysis script sharing this session (DDP2H_EXTRA_LUA=path)
if env("DDP2H_EXTRA_LUA") then dofile(env("DDP2H_EXTRA_LUA")) end
