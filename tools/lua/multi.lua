-- Runs several harness extra scripts: EXTRA_LUAS = "a.lua;b.lua"
for p in (os.getenv("EXTRA_LUAS") or ""):gmatch("[^;]+") do dofile(p) end
