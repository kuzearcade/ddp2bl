-- interrupt / protocol timing probe (protected set): the game's two short interrupt handlers
-- ($147F1E reads $80ECD4 first, $147F80 reads $80ECDC), every command word write ($D00010) and every
-- latch read ($D10001), with the 68000 cycle time. IRQPROBE_OUT.
local m = manager.machine
local sp = m.devices[":maincpu"].spaces["program"]
local out = assert(io.open(os.getenv("IRQPROBE_OUT"), "w"))
local function cyc() return math.floor(m.time:as_double() * 20000000 + 0.5) end
local last4, last6 = -1000, -1000
-- (opcode fetches do not reach taps: use the first RAM each handler reads)
ip1 = sp:install_read_tap(0x80ecd4, 0x80ecd7, "ipa", function(o, d, k)
  local t = cyc(); if t - last4 > 50 then out:write("IA ", t, "\n") end; last4 = t
end)
ip2 = sp:install_read_tap(0x80ecdc, 0x80ecdf, "ipb", function(o, d, k)
  local t = cyc(); if t - last6 > 50 then out:write("IB ", t, "\n") end; last6 = t
end)
ip3 = sp:install_write_tap(0xd00010, 0xd00011, "ipc", function(o, d, k)
  out:write("C ", cyc(), " ", d & 0xffff, "\n")
end)
ip4 = sp:install_read_tap(0xd10000, 0xd10001, "ipl", function(o, d, k)
  out:write("L ", cyc(), " ", d & 0xff, "\n")
end)
