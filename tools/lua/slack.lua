-- log idle-entry and vblank times (in 68k cycles) for slack analysis
local m = manager.machine
local sp = m.devices[":maincpu"].spaces["program"]
local out = assert(io.open(os.getenv("SLACK_OUT"), "w"))
local function cyc() return string.format("%.1f", m.time:as_double() * 20000000) end
slk1 = sp:install_read_tap(0x808d8e, 0x808d8f, "slk_fc", function(o, d, k)
  out:write("R ", cyc(), "\n")
end)
slk2 = sp:install_write_tap(0x80ed3a, 0x80ed3b, "slk_vb", function(o, d, k)
  out:write("V ", cyc(), " ", d, "\n")
end)
slk3 = sp:install_write_tap(0x808d90, 0x808d91, "slk_fw", function(o, d, k)
  out:write("W ", cyc(), " ", d, "\n")
end)
