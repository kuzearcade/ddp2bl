# Developer build: 68000 replacement code + patch list for a target.
# End users only need tools/ddp2bl_build.py (it uses the committed hle/build/*.bin).
TARGET  ?= ddp2_v102_world
TOOLS   ?= $(HOME)/DDP2_Repair/toolchain/bin
ARM     ?= work/arm
PROG    ?= work/prog
BUILD   := hle/build
VASM    := $(TOOLS)/vasmm68k_mot -quiet -Fbin -m68000 -no-opt

all: $(BUILD)/$(TARGET).bin targets/$(TARGET)/patches.json

$(BUILD)/$(TARGET).inc: targets/$(TARGET)/target.json tools/gen_target_inc.py
	@mkdir -p $(BUILD)
	python3 tools/gen_target_inc.py $(TARGET) $(ARM)/internal.bin $@

$(BUILD)/$(TARGET).bin: $(BUILD)/$(TARGET).inc $(wildcard hle/*.s)
	cp $< $(BUILD)/target.inc
	$(VASM) -I$(BUILD) -Ihle -o $@ -L $(BUILD)/$(TARGET).lst hle/hle.s

targets/$(TARGET)/patches.json: $(BUILD)/$(TARGET).bin tools/gen_patches.py targets/$(TARGET)/target.json
	python3 tools/gen_patches.py --target $(TARGET) --program $(PROG)/v102.be.bin --dasm $(PROG)/v102.dasm --listing $(BUILD)/$(TARGET).lst

oracle/libestmodel.so: oracle/est_model.c $(wildcard oracle/*.inc)
	gcc -O2 -fPIC -shared -Wall -Wno-unused-function -o $@ oracle/est_model.c

.PHONY: all
