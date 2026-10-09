// Ghidra headless post-script: map IGS027A (type2 / 55857F) memory layout for DDP2,
// seed entry points from the external ROM pointer tables, analyze and export C.
// Args: <external_rom.bin> <out_dir> [seeds.txt]
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.*;
import ghidra.program.model.mem.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.lang.*;
import ghidra.program.model.symbol.*;
import ghidra.app.cmd.disassemble.*;
import ghidra.app.cmd.function.*;
import java.io.*;
import java.math.BigInteger;
import java.nio.file.*;

public class DDP2Setup extends GhidraScript {
    Address a(long x) { return currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(x); }

    void ram(String name, long base, long size) throws Exception {
        Memory mem = currentProgram.getMemory();
        MemoryBlock b = mem.createUninitializedBlock(name, a(base), size, false);
        b.setRead(true); b.setWrite(true); b.setExecute(false); b.setVolatile(name.startsWith("io_") || name.equals("shared68k"));
    }

    void seed(long ptr) throws Exception {
        boolean thumb = (ptr & 1) != 0;
        Address ad = a(ptr & ~1L);
        if (getInstructionAt(ad) != null) {
            if (getFunctionAt(ad) == null) new CreateFunctionCmd(ad).applyTo(currentProgram, monitor);
            return;
        }
        Register tm = currentProgram.getRegister("TMode");
        try { currentProgram.getProgramContext().setValue(tm, ad, ad, BigInteger.valueOf(thumb ? 1 : 0)); }
        catch (Exception e) { println("ctx conflict at " + ad); return; }
        new DisassembleCommand(ad, null, true).applyTo(currentProgram, monitor);
        if (getFunctionAt(ad) == null) new CreateFunctionCmd(ad).applyTo(currentProgram, monitor);
    }

    public void run() throws Exception {
        String[] args = getScriptArgs();
        byte[] ext = Files.readAllBytes(Paths.get(args[0]));
        Memory mem = currentProgram.getMemory();
        int tx = currentProgram.startTransaction("setup");
        MemoryBlock eb = mem.createInitializedBlock("ext_rom", a(0x08000000L), new ByteArrayInputStream(ext), ext.length, monitor, false);
        eb.setRead(true); eb.setExecute(true); eb.setWrite(false);
        ram("iram", 0x10000000L, 0x400);
        ram("arm_ram", 0x18000000L, 0x10000);
        ram("io_latch", 0x38000000L, 4);
        ram("shared68k", 0x48000000L, 0x10000);
        ram("io_xortab", 0x50000000L, 0x400);
        currentProgram.endTransaction(tx, true);

        // seed: reset/vector targets of internal ROM are found by analysis; seed ext pointer tables
        for (long p = 0x08000000L; p < 0x08000040L; p += 4) seed(mem.getInt(a(p)) & 0xffffffffL);
        for (long p = 0x08000080L; p < 0x08000088L; p += 4) seed(mem.getInt(a(p)) & 0xffffffffL);
        // optional seed list: one hex address per line, odd = Thumb (from dispatch tables / runtime coverage)
        if (args.length > 2) {
            for (String line : Files.readAllLines(Paths.get(args[2]))) {
                line = line.trim();
                if (line.isEmpty() || line.startsWith("#")) continue;
                seed(Long.parseLong(line.replace("0x", ""), 16));
            }
        }
        analyzeAll(currentProgram);

        // second pass: any word in ext ROM that looks like an odd Thumb pointer into ext code with a valid instruction
        // is left for manual review (not auto-seeded) to avoid false functions.

        File outDir = new File(args[1]); outDir.mkdirs();
        DecompInterface di = new DecompInterface();
        di.openProgram(currentProgram);
        try (PrintWriter pw = new PrintWriter(new File(outDir, "decompiled.c"));
             PrintWriter fl = new PrintWriter(new File(outDir, "functions.txt"))) {
            for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
                Register tm = currentProgram.getRegister("TMode");
                BigInteger t = currentProgram.getProgramContext().getValue(tm, f.getEntryPoint(), false);
                fl.printf("%s %s %d %s%n", f.getEntryPoint(), (t != null && t.intValue() == 1) ? "T" : "A",
                          f.getBody().getNumAddresses(), f.getName());
                DecompileResults r = di.decompileFunction(f, 120, monitor);
                pw.println("// ===== " + f.getEntryPoint() + " " + f.getName());
                pw.println(r.decompileCompleted() ? r.getDecompiledFunction().getC() : "// decompile failed: " + r.getErrorMessage());
            }
        }
    }
}
