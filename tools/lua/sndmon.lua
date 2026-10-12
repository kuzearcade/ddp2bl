-- Sound path monitor (DDP2): each vblank the game waits for the Z80 to be ready
-- ($175976: writes $Fx to latch 3 $C0000C, polls latch 2 $C00004), takes the Z80 bus
-- ($C0000A = $45D3), writes a 4-byte command packet into Z80 RAM $0006-$0009 ($C10006),
-- releases the bus ($0A0A) and signals on latch 1 ($C00002).
-- SNDMON_OUT gets, per video frame: "F frame packets consumed lost maxwait" (maxwait: the
-- longest ready wait in 68000 cycles), "P frame b0 b1 b2 b3" for every packet, "LOST frame"
-- when a packet is overwritten before the Z80 read it, and "SUMMARY ..." at exit.
local m = manager.machine
local main = m.devices[":maincpu"].spaces["program"]
local zprg = m.devices[":soundcpu"].spaces["program"]
local scr = m.screens[":screen"]
local out = assert(io.open(os.getenv("SNDMON_OUT"), "w"))
local function cyc() return m.time:as_double() * 20000000 end
local pkt = {0, 0, 0, 0}
local pending, waitstart, wrote = false, nil, false
local fp, fc, fl, fwait = 0, 0, 0, 0
local tp, tc, tl, twait, nwait = 0, 0, 0, 0, 0
local hist = {}
sm1 = main:install_write_tap(0xc10006, 0xc10009, "sm_pkt", function(o, d, k)
  -- word or long writes from the 68000 (move.l = two word writes)
  local i = o - 0xc10006
  if (k & 0xff00) ~= 0 then pkt[i + 1] = (d >> 8) & 0xff end
  if (k & 0x00ff) ~= 0 then pkt[i + 2] = d & 0xff end
  wrote = true
end)
sm2 = zprg:install_read_tap(0x0006, 0x0009, "sm_zr", function(o, d, k)
  if pending then pending = false; fc = fc + 1; tc = tc + 1 end
end)
sm3 = main:install_write_tap(0xc0000a, 0xc0000d, "sm_hs", function(o, d, k)
  if o == 0xc0000c and (d & 0xf0) == 0xf0 then
    if waitstart == nil then waitstart = cyc() end
  elseif o == 0xc0000a and (d & 0xffff) == 0x0a0a and wrote then
    -- bus released after a packet write: one packet
    wrote = false
    if pending then fl = fl + 1; tl = tl + 1; out:write(string.format("LOST %d\n", scr:frame_number())) end
    pending = true; fp = fp + 1; tp = tp + 1
    out:write(string.format("P %d %02x %02x %02x %02x\n", scr:frame_number(), pkt[1], pkt[2], pkt[3], pkt[4]))
  elseif o == 0xc0000a and (d & 0xffff) == 0x45d3 and waitstart ~= nil then
    local w = cyc() - waitstart
    waitstart = nil
    if w > fwait then fwait = w end
    if w > twait then twait = w end
    local b = w < 1000 and 0 or (w < 10000 and 1 or (w < 50000 and 2 or (w < 150000 and 3 or 4)))
    hist[b] = (hist[b] or 0) + 1
  end
end)
sm4 = emu.add_machine_frame_notifier(function()
  out:write(string.format("F %d %d %d %d %d\n", scr:frame_number(), fp, fc, fl, math.floor(fwait)))
  fp, fc, fl, fwait = 0, 0, 0, 0
end)
sm5 = emu.add_machine_stop_notifier(function()
  out:write(string.format("SUMMARY packets %d consumed %d lost %d maxwait %d waits<1k %d <10k %d <50k %d <150k %d >=150k %d\n",
    tp, tc, tl, math.floor(twait), hist[0] or 0, hist[1] or 0, hist[2] or 0, hist[3] or 0, hist[4] or 0))
  out:close()
end)
