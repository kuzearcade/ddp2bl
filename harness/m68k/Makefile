MUSASHI ?= $(HOME)/DDP2_Repair/toolchain/src/Musashi
CFLAGS = -O2 -fPIC -I. -I$(MUSASHI) -DMUSASHI_CNF=\"m68kconf_ddp2bl.h\"
all: libm68r.so
m68kops.c m68kops.h: $(MUSASHI)/m68k_in.c $(MUSASHI)/m68kmake.c
	$(CC) -O2 -o m68kmake $(MUSASHI)/m68kmake.c && ./m68kmake . $(MUSASHI)/m68k_in.c
libm68r.so: runner.c m68kops.c m68kconf_ddp2bl.h
	$(CC) $(CFLAGS) -shared -o $@ runner.c m68kops.c $(MUSASHI)/m68kcpu.c $(MUSASHI)/m68kdasm.c $(MUSASHI)/softfloat/softfloat.c -lm
clean:
	rm -f libm68r.so m68kops.c m68kops.h m68kmake
