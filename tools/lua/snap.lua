-- Screen snapshots for visual checks (harness extra script).
--   SNAP_DIR    output directory (PNG per snapshot, named by video frame)
--   SNAP_EVERY  snapshot period in frames (default 1000)
--   SNAP_DENSE  optional "first,last,every": a denser period inside a frame range
local dir = assert(os.getenv("SNAP_DIR"))
local every = tonumber(os.getenv("SNAP_EVERY") or "1000")
local d1, d2, de = (os.getenv("SNAP_DENSE") or ""):match("^(%d+),(%d+),(%d+)$")
d1, d2, de = tonumber(d1), tonumber(d2), tonumber(de)
local scr = manager.machine.screens[":screen"]
snap_fn = emu.add_machine_frame_notifier(function()
  local f = scr:frame_number()
  local n = (d1 and f >= d1 and f <= d2) and de or every
  if f % n == 0 then scr:snapshot(string.format("%s/%07d.png", dir, f)) end
end)
