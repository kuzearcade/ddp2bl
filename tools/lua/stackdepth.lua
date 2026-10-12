-- deepest stack write (lowest address in $81C000-$81FFFF) and the PC that made it
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local out = os.getenv("STACKDEPTH_OUT")
local lo = 0x820000
local lopc = 0
sdtap = sp:install_write_tap(0x81c000, 0x81ffff, "sd", function(o, d, k)
  if o < lo then lo = o; lopc = cpu.state["CURPC"].value end
end)
sdfr = emu.add_machine_frame_notifier(function()
  if m.screens[":screen"]:frame_number() % 600 == 0 then
    local f = io.open(out, "w"); f:write(string.format("%06x %06x\n", lo, lopc)); f:close()
  end
end)
