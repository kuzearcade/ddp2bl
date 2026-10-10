#!/usr/bin/env python3
"""Cycle accounting for the 68000 job code (hle/job.s and its includes).

Produces an assembler file in which every basic block starts with
    lea N(a3),a3       (N = cycles of the block, including this instruction)
so that, after running any path through the code, a3 has grown by exactly the
number of 68000 clock cycles that path took (MC68000 user manual, section 8, which
MAME's cycle-exact core reproduces). The result is verified against MAME by the
ddp2bl job probe (see docs/timing.md).

Rules enforced (the tool aborts otherwise):
  * a3 appears only in the inserted markers and in "@cyc-adjust" lines;
  * MULS/MULU have an immediate source, or carry "@muls-dyn" (base cost counted here,
    the data-dependent 2n added by the code itself through a MULCOST table);
  * no DIVU/DIVS, no register-count shifts, no other data-dependent timing;
  * branch targets are labels.
Conditional branches are charged their taken time; the not-taken difference is
added on the fall-through edge (a correction marker placed before any label there).

usage: cycacc.py <job.s> <output.s> [--symbols target.inc ...] [--report]
"""
import argparse
import os
import re
import sys

# ---------------------------------------------------------------- source handling
def read_with_includes(path, seen=None):
    out = []
    base = os.path.dirname(path)
    for line in open(path):
        m = re.match(r'^\s+include\s+"([^"]+)"', line)
        if m:
            out += read_with_includes(os.path.join(base, m.group(1)))
        else:
            out.append(line.rstrip("\n"))
    return out


def split_comment(line):
    in_str = False
    for i, c in enumerate(line):
        if c == '"':
            in_str = not in_str
        if c == ";" and not in_str:
            return line[:i], line[i:]
    return line, ""


def expand_macros(lines):
    macros, out, i = {}, [], 0
    while i < len(lines):
        code, _ = split_comment(lines[i])
        m = re.match(r"^(\w+)\s+macro\b", code)
        if m:
            body = []
            i += 1
            while not re.match(r"^\s+endm\b", split_comment(lines[i])[0]):
                body.append(lines[i])
                i += 1
            macros[m.group(1)] = body
            i += 1
            continue
        out.append(lines[i])
        i += 1
    res, counter = [], [0]

    def expand(line, depth=0):
        code, com = split_comment(line)
        m = re.match(r"^(\s*(?:[.\w]+:)?\s+)(\w+)(?:\s+(.*))?$", code)
        if m and m.group(2) in macros:
            if depth > 8:
                raise SystemExit("macro recursion")
            args = split_operands(m.group(3) or "")
            counter[0] += 1
            tag = "_%d" % counter[0]
            label = m.group(1).strip()
            out_lines = [label] if label else []
            for b in macros[m.group(2)]:
                t = b
                for k, a in enumerate(args, 1):
                    t = t.replace("\\%d" % k, a)
                t = t.replace("\\@", tag)
                out_lines += expand(t, depth + 1)
            return out_lines
        return [line]

    for line in out:
        res += expand(line)
    return res


def split_operands(s):
    ops, depth, cur = [], 0, ""
    for c in s:
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        if c == "," and depth == 0:
            ops.append(cur.strip())
            cur = ""
        else:
            cur += c
    if cur.strip():
        ops.append(cur.strip())
    return ops


# ---------------------------------------------------------------- timing model
EA_BW = {"dn": 0, "an": 0, "ind": 4, "post": 4, "pre": 6, "d16": 8, "d8x": 10, "absw": 8, "absl": 12,
         "pcd16": 8, "pcd8x": 10, "imm": 4}
EA_L = {"dn": 0, "an": 0, "ind": 8, "post": 8, "pre": 10, "d16": 12, "d8x": 14, "absw": 12, "absl": 16,
        "pcd16": 12, "pcd8x": 14, "imm": 8}
MOVE_DST_BW = {"dn": 0, "an": 0, "ind": 4, "post": 4, "pre": 4, "d16": 8, "d8x": 10, "absw": 8, "absl": 12}
MOVE_DST_L = {"dn": 0, "an": 0, "ind": 8, "post": 8, "pre": 8, "d16": 12, "d8x": 14, "absw": 12, "absl": 16}
JMP_T = {"ind": 8, "d16": 10, "d8x": 14, "absw": 10, "absl": 12, "pcd16": 10, "pcd8x": 14}
JSR_T = {"ind": 16, "d16": 18, "d8x": 22, "absw": 18, "absl": 20, "pcd16": 18, "pcd8x": 22}
LEA_T = {"ind": 4, "d16": 8, "d8x": 12, "absw": 8, "absl": 12, "pcd16": 8, "pcd8x": 12}
REG = r"(?:d[0-7]|a[0-7]|sp)"
MARK = 8      # lea d16(An),An


def ea_mode(op):
    o = op.lower().replace(" ", "")
    if re.fullmatch(r"d[0-7]", o):
        return "dn"
    if re.fullmatch(r"a[0-7]|sp", o):
        return "an"
    if o.startswith("#"):
        return "imm"
    if re.fullmatch(r"\(" + REG + r"\)", o):
        return "ind"
    if re.fullmatch(r"\(" + REG + r"\)\+", o):
        return "post"
    if re.fullmatch(r"-\(" + REG + r"\)", o):
        return "pre"
    m = re.fullmatch(r"(.*)\((pc|" + REG + r")(,(" + REG + r")(\.[wl])?)?\)", o)
    if m:
        pc = m.group(2) == "pc"
        idx = m.group(3) is not None
        if pc:
            return "pcd8x" if idx else "pcd16"
        if idx:
            return "d8x"
        return "d16" if m.group(1) != "" else "ind"
    return "absw" if o.endswith(".w") else "absl"


def imm_value(op, syms):
    expr = op[1:].strip()
    e = re.sub(r"\$([0-9a-fA-F]+)", lambda m: str(int(m.group(1), 16)), expr)
    e = re.sub(r"[A-Za-z_]\w*", lambda m: str(syms[m.group(0)]) if m.group(0) in syms else m.group(0), e)
    try:
        return int(eval(e, {"__builtins__": {}}))
    except Exception:
        raise SystemExit("cannot evaluate immediate %r" % op)


def mul_n(v, signed):
    v &= 0xffff
    if not signed:
        return bin(v).count("1")
    x = (v << 1) & 0x1ffff
    return sum(1 for i in range(16) if ((x >> i) & 1) != ((x >> (i + 1)) & 1))


class Insn:
    __slots__ = ("mn", "size", "ops", "cycles", "kind", "taken", "nottaken", "targets", "text", "dyn")


def timing(mn, size, ops, comment, syms):
    """returns (cycles, kind, taken, nottaken); kind in normal/cond/bra/dbra/call/jmp/rts"""
    m = [ea_mode(o) for o in ops]
    L = size == "l"
    ea = EA_L if L else EA_BW
    if mn in ("move", "movea"):
        dst = (MOVE_DST_L if L else MOVE_DST_BW)[m[1]]
        return 4 + ea[m[0]] + dst, "normal"
    if mn == "moveq" or mn in ("nop", "swap", "ext"):
        return 4, "normal"
    if mn == "lea":
        return LEA_T[m[0]], "normal"
    if mn in ("clr", "neg", "not"):
        if m[0] == "dn":
            return (6 if L else 4), "normal"
        return (12 if L else 8) + ea[m[0]], "normal"
    if mn == "tst":
        return 4 + ea[m[0]], "normal"
    if mn in ("add", "sub", "and", "or"):
        if m[1] == "dn":
            if L:
                return (8 if m[0] in ("dn", "an", "imm") else 6) + ea[m[0]], "normal"
            return 4 + ea[m[0]], "normal"
        if m[1] == "an":
            raise SystemExit("use adda/suba explicitly: %s %s" % (mn, ops))
        return (12 if L else 8) + ea[m[1]], "normal"
    if mn == "cmp":
        return (6 if L else 4) + ea[m[0]], "normal"
    if mn in ("adda", "suba"):
        if L:
            return (8 if m[0] in ("dn", "an", "imm") else 6) + EA_L[m[0]], "normal"
        return 8 + EA_BW[m[0]], "normal"
    if mn == "cmpa":
        return 6 + (EA_L if L else EA_BW)[m[0]], "normal"
    if mn in ("addi", "subi", "ori", "eori", "andi", "cmpi"):
        if m[1] == "dn":
            if not L:
                return 8, "normal"
            return (14 if mn == "cmpi" else 16), "normal"
        if mn == "cmpi":
            return (12 if L else 8) + ea[m[1]], "normal"
        return (20 if L else 12) + ea[m[1]], "normal"
    if mn in ("addq", "subq"):
        if m[1] == "dn":
            return (8 if L else 4), "normal"
        if m[1] == "an":
            return 8, "normal"
        return (12 if L else 8) + ea[m[1]], "normal"
    if mn in ("lsl", "lsr", "asl", "asr", "rol", "ror"):
        if len(ops) == 2 and m[0] == "imm" and m[1] == "dn":
            n = imm_value(ops[0], syms)
            return (8 if L else 6) + 2 * n, "normal"
        raise SystemExit("unsupported shift form: %s %s" % (mn, ops))
    if mn == "btst":
        if m[0] == "imm":
            return (10 if m[1] == "dn" else 8 + EA_BW[m[1]]), "normal"
        return (6 if m[1] == "dn" else 4 + EA_BW[m[1]]), "normal"
    if mn in ("muls", "mulu"):
        if m[0] == "imm":
            return 38 + 2 * mul_n(imm_value(ops[0], syms), mn == "muls") + EA_BW["imm"], "normal"
        if "@muls-dyn" in comment:
            return 38 + EA_BW[m[0]], "normal"
        raise SystemExit("data-dependent multiply without @muls-dyn: %s %s" % (mn, ops))
    if mn in ("divu", "divs"):
        raise SystemExit("DIVU/DIVS not allowed in accounted code")
    if mn == "movem":
        regs = ops[0] if m[1] in ("pre", "ind", "d16", "absl") else ops[1]
        n = 0
        for part in regs.lower().split("/"):
            if "-" in part:
                a, b = part.split("-")
                n += int(b[1]) - int(a[1]) + 1
            else:
                n += 1
        per = 8 if L else 4
        if m[1] in ("pre", "ind"):
            return 8 + per * n, "normal"
        if m[0] == "post":
            return 12 + per * n, "normal"
        raise SystemExit("unsupported movem form %s" % ops)
    if mn in ("bra",):
        return 10, "bra"
    if mn == "bsr":
        return 18, "call"
    if mn == "jsr":
        return JSR_T[m[0]], "call"
    if mn == "jmp":
        return JMP_T[m[0]], "jmp"
    if mn == "rts":
        return 16, "rts"
    if mn == "dbra" or mn == "dbf":
        return 10, "dbra"
    if re.fullmatch(r"b(eq|ne|cs|cc|hi|ls|ge|gt|le|lt|pl|mi|vs|vc|hs|lo)", mn):
        return 10, "cond"
    raise SystemExit("no timing for %s.%s %s" % (mn, size, ops))


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("output")
    ap.add_argument("--symbols", action="append", default=[])
    ap.add_argument("--report", action="store_true")
    a = ap.parse_args()

    syms = {}
    for sf in a.symbols:
        for line in open(sf):
            code, _ = split_comment(line)
            mm = re.match(r"^(\w+)\s+equ\s+(.+)$", code.strip())
            if mm:
                v = mm.group(2).strip()
                try:
                    syms[mm.group(1)] = imm_value("#" + v, syms)
                except SystemExit:
                    pass

    lines = expand_macros(read_with_includes(a.source))
    # pass 1: parse, qualify local labels, collect branch targets
    items = []          # ("label", name) | ("insn", Insn, raw) | ("raw", raw)
    scope = ""
    targets = set()
    for raw in lines:
        code, com = split_comment(raw)
        if not code.strip():
            items.append(("raw", raw))
            continue
        mm = re.match(r"^([.\w]+):\s*(.*)$", code)
        rest = code
        if mm:
            name = mm.group(1)
            if not name.startswith("."):
                scope = name
                targets.add(name)           # global labels are entry points
            q = scope + name if name.startswith(".") else name
            items.append(("label", q, name))
            rest = mm.group(2)
            if not rest.strip():
                continue
        else:
            rest = code
        rest = rest.strip()
        mm = re.match(r"^(\w+)(?:\.([bwls]))?(?:\s+(.*))?$", rest)
        if not mm:
            items.append(("raw", "\t" + rest + ("\t" + com if com else "")))
            continue
        mn, size, opstr = mm.group(1).lower(), (mm.group(2) or "w").lower(), mm.group(3) or ""
        if size == "s" and re.fullmatch(r"b(ra|sr|eq|ne|cs|cc|hi|ls|ge|gt|le|lt|pl|mi|vs|vc|hs|lo)", mn):
            # markers make blocks longer: use 16-bit displacements everywhere (and account them)
            size = "w"
            rest = re.sub(r"^(\w+)\.s\b", r"\1", rest)
        if mn in ("dc", "ds", "even", "align", "cnop", "equ", "set"):
            items.append(("raw", "\t" + rest + ("\t" + com if com else "")))
            for lab in re.findall(r"([.\w]+)-[.\w]+", opstr):
                targets.add(scope + lab if lab.startswith(".") else lab)
            continue
        ops = split_operands(opstr)
        if re.search(r"\ba3\b", opstr, re.I) and "@cyc-adjust" not in com:
            raise SystemExit("a3 is reserved for accounting: %s" % raw)
        ins = Insn()
        ins.mn, ins.size, ins.ops, ins.text, ins.dyn = mn, size, ops, "\t" + rest + ("\t" + com if com else ""), "@cyc-adjust" in com
        t = timing(mn, size, ops, com, syms)
        ins.cycles, ins.kind = t
        ins.targets = []
        if ins.kind in ("cond", "bra", "dbra", "call", "jmp"):
            tgt = ops[-1]
            if ins.kind == "jmp" or (ins.kind == "call" and "(" in tgt):
                pass      # computed (tables) or absolute: targets collected from tables
            else:
                lab = tgt.split("(")[0]
                q = scope + lab if lab.startswith(".") else lab
                ins.targets = [q]
                targets.add(q)
            if ins.kind == "cond":
                ins.taken, ins.nottaken = 10, (8 if size == "s" else 12)
            elif ins.kind == "dbra":
                ins.taken, ins.nottaken = 10, 14
            elif ins.kind == "bra":
                ins.cycles = 10
        items.append(("insn", ins))

    # pass 2: blocks. A block starts at a target label or after a control transfer.
    out = []
    pending = []          # instructions of the current block
    block_open = False
    corr = 0              # fall-through correction owed by the previous block
    nblocks = 0

    def marker_line(n):
        # LEA does not touch the condition codes (blocks may start right after a
        # conditional branch whose flags the next branch still uses)
        return "\tlea\t%d(a3),a3\t\t; [cyc] block" % n

    def flush():
        nonlocal pending, block_open, nblocks
        if not block_open:
            return
        cost = sum(i.cycles if i.kind != "cond" and i.kind != "dbra" else i.taken for i in pending)
        out.insert(block_start_idx[0], marker_line(cost + corr_at_start[0] + MARK))
        nblocks += 1
        pending = []
        block_open = False

    block_start_idx = [0]
    corr_at_start = [0]
    last_kind = "rts"     # code before the first label is unreachable unless labelled
    for it in items:
        if it[0] == "label":
            if it[1] in targets:
                if block_open:
                    flush()
                if corr:
                    # fall-through into a target label after a conditional branch:
                    # separate correction marker executed only on the fall-through path
                    out.append("\tlea\t%d(a3),a3\t\t; [cyc] fall-through" % (corr + MARK))
                    corr = 0
            out.append(it[2] + ":" if not it[2].startswith(".") else it[2] + ":")
            continue
        if it[0] == "raw":
            out.append(it[1])
            continue
        ins = it[1]
        if not block_open:
            block_open = True
            block_start_idx[0] = len(out)
            corr_at_start[0] = corr
            corr = 0
        out.append(ins.text)
        pending.append(ins)
        if ins.kind != "normal":
            flush()
            if ins.kind == "cond" or ins.kind == "dbra":
                corr = ins.nottaken - ins.taken
            else:
                corr = 0
    if block_open:
        flush()
    open(a.output, "w").write("; generated by tools/cycacc.py from %s - do not edit\n" % os.path.basename(a.source)
                              + "\n".join(out) + "\n")
    if a.report:
        print("blocks: %d" % nblocks)


if __name__ == "__main__":
    main()
