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
    __slots__ = ("mn", "size", "ops", "cycles", "kind", "taken", "nottaken", "targets", "text", "dyn",
                 "unlikely", "target_text")


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
    ap.add_argument("--entry", action="append", default=[],
                    help="label entered from outside the accounted code (potential 0)")
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
    table_targets = set()
    manual = False        # inside "; @cyc-off" .. "; @cyc-on": code that accounts for itself
    for raw in lines:
        code, com = split_comment(raw)
        if not code.strip() and "@cyc-off" in com:
            manual = True
            items.append(("raw", raw))
            continue
        if not code.strip() and "@cyc-on" in com:
            manual = False
            items.append(("raw", raw))
            continue
        mq = re.match(r"^(\w+)\s+equ\s+(.+)$", code.strip())
        if mq and not raw[:1].isspace():
            syms[mq.group(1)] = imm_value("#" + mq.group(2).strip(), syms)
            items.append(("raw", raw))
            continue
        if manual:
            # passed through verbatim (no markers, branch sizes kept); the code adds its
            # own cycles with "@cyc-adjust" instructions; labels here are internal only
            if re.search(r"\ba3\b", code, re.I) and "@cyc-adjust" not in com:
                raise SystemExit("a3 is reserved for accounting: %s" % raw)
            mm = re.match(r"^([.\w]+):", code)
            if mm and not mm.group(1).startswith("."):
                raise SystemExit("global label inside a @cyc-off region: %s" % raw)
            items.append(("raw", raw))
            continue
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
                q = scope + lab if lab.startswith(".") else lab
                targets.add(q)
                table_targets.add(q)
            continue
        ops = split_operands(opstr)
        if re.search(r"\ba3\b", opstr, re.I) and "@cyc-adjust" not in com:
            raise SystemExit("a3 is reserved for accounting: %s" % raw)
        ins = Insn()
        ins.mn, ins.size, ins.ops, ins.text, ins.dyn = mn, size, ops, "\t" + rest + ("\t" + com if com else ""), "@cyc-adjust" in com
        ins.unlikely = "@unlikely" in com
        ins.target_text = ops[-1] if ops else None
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

    # pass 2: basic blocks. A block starts at a target label or after a control transfer
    # (calls do not end blocks: the callee accounts for itself).
    blocks = []           # dict(start=index in items, insns, term, labels, taken, fall)
    label_block = {}
    cur = None
    pending_labels = []
    for idx, it in enumerate(items):
        if it[0] == "label":
            if it[1] in targets:
                if cur is not None:
                    cur["term"] = "fall"
                    cur = None
                pending_labels.append(it[1])
            continue
        if it[0] != "insn":
            continue
        ins = it[1]
        if cur is None:
            cur = dict(first=idx, insns=[], term=None, labels=pending_labels, n=len(blocks))
            for lab in pending_labels:
                label_block[lab] = cur["n"]
            pending_labels = []
            blocks.append(cur)
        cur["insns"].append(ins)
        if ins.kind in ("cond", "dbra", "bra", "jmp", "rts"):
            cur["term"] = ins.kind
            cur = None
    if cur is not None:
        cur["term"] = "fall"
    for i, b in enumerate(blocks):
        last = b["insns"][-1]
        b["taken"] = None
        b["fall"] = i + 1 if b["term"] in ("fall", "cond", "dbra") and i + 1 < len(blocks) else None
        if b["term"] in ("cond", "dbra", "bra"):
            b["taken"] = label_block[last.targets[0]]
        b["calls"] = [label_block[i_.targets[0]] for i_ in b["insns"] if i_.kind == "call" and i_.targets]

    # potentials: a marker on edge u->v must add cost(u) + phi(v) - phi(u); a path from
    # an entry e to a return then adds its exact cost - phi(e). Entries reached from
    # outside (and computed-dispatch targets, whose callers cannot know which one runs)
    # get phi = 0; a direct call adds the callee's phi to the caller's cost. Each block
    # takes phi = its cost + phi(taken successor) when free, so only diverging costs need
    # markers. Loop heads (targets of back edges) are pinned to 0.
    FIXED = set(a.entry)
    fixed = set(label_block[l] for l in FIXED if l in label_block)
    fixed |= set(label_block[l] for l in table_targets if l in label_block)
    state = {}

    def succs(n):
        b = blocks[n]
        return [x for x in (b["taken"], b["fall"]) if x is not None] + b["calls"]

    import sys as _sys
    _sys.setrecursionlimit(100000)

    def dfs(n):
        state[n] = 1
        for m in succs(n):
            if state.get(m) == 1:
                if m in blocks[n]["calls"]:
                    raise SystemExit("recursion through %s" % blocks[m]["labels"])
                fixed.add(m)                       # back edge: loop head
            elif m not in state:
                dfs(m)
        state[n] = 2
    for n in range(len(blocks)):
        if n not in state:
            dfs(n)

    phi = {}

    def base_cost(n):
        b = blocks[n]
        c = 0
        for i_ in b["insns"]:
            c += i_.taken if i_.kind in ("cond", "dbra") else i_.cycles
            if i_.kind == "call" and i_.targets:
                c += get_phi(label_block[i_.targets[0]])
        return c

    def unlikely(n):
        b = blocks[n]
        return b["term"] == "cond" and b["insns"][-1].unlikely and b["fall"] is not None

    def out_phi(n):
        """phi (+ timing difference) of the successor whose edge needs no marker of its own:
        the taken one, or for a branch marked "@unlikely" the fall-through one (its taken
        edge then goes through a stub carrying the correction)"""
        b = blocks[n]
        if b["term"] in ("rts", "jmp"):
            return 0
        if unlikely(n):
            last = b["insns"][-1]
            return (last.nottaken - last.taken) + get_phi(b["fall"])
        if b["term"] in ("cond", "dbra", "bra"):
            return get_phi(b["taken"])
        return get_phi(b["fall"]) if b["fall"] is not None else 0

    def get_phi(n):
        if n in fixed:
            return 0
        if n not in phi:
            phi[n] = None
            phi[n] = base_cost(n) + out_phi(n)
        if phi[n] is None:
            raise SystemExit("potential cycle at %s" % blocks[n]["labels"])
        return phi[n]

    inserts = []          # (item index, line) inserted before that item
    stubs = {}            # item index -> lines of @unlikely stubs inserted before it
    nmark = 0
    for n, b in enumerate(blocks):
        m = base_cost(n) + out_phi(n) - get_phi(n)
        if m:
            inserts.append((b["first"], "\tlea\t%d(a3),a3\t\t; [cyc] block" % (m + MARK)))
            nmark += 1
        if unlikely(n):
            # taken edge: needs base_cost + phi(T) - phi(u) in total, m of it is done
            last = b["insns"][-1]
            w = base_cost(n) + get_phi(b["taken"]) - get_phi(n) - m
            if w:
                stub = ".cyc_stub%d" % n
                k = next((i_ for i_ in range(b["first"], len(items)) if items[i_][0] == "insn"
                          and items[i_][1] is last), None)
                # place the stub after the next unconditional transfer in the same scope
                j = k + 1
                while j < len(items):
                    it = items[j]
                    if it[0] == "label" and not it[2].startswith("."):
                        j = None
                        break
                    if it[0] == "insn" and it[1].kind in ("rts", "bra", "jmp"):
                        break
                    j += 1
                if j is None or j >= len(items):
                    raise SystemExit("no place for the @unlikely stub of %s" % last.text.strip())
                last.text = last.text.replace(last.target_text, stub, 1)
                stubs.setdefault(j + 1, []).extend([
                    stub + ":",
                    "\tlea\t%d(a3),a3\t\t; [cyc] unlikely edge" % (w + MARK + 10),
                    "\tbra\t%s" % last.target_text])
                nmark += 1
        elif b["term"] in ("cond", "dbra") and b["fall"] is not None:
            last = b["insns"][-1]
            f = (last.nottaken - last.taken) + get_phi(b["fall"]) - get_phi(b["taken"])
            if f:
                # after the branch, before the next block's labels: fall-through path only
                nxt = blocks[b["fall"]]["first"]
                while nxt > 0 and items[nxt - 1][0] in ("label", "raw"):
                    nxt -= 1
                inserts.append((nxt, "\tlea\t%d(a3),a3\t\t; [cyc] fall-through" % (f + MARK)))
                nmark += 1
    at = {}
    for i_, line in inserts:
        at.setdefault(i_, []).append(line)
    for i_, lines_ in stubs.items():
        at.setdefault(i_, [])[:0] = lines_
    out = []
    for idx, it in enumerate(items):
        for line in at.get(idx, []):
            out.append(line)
        if it[0] == "label":
            out.append(it[2] + ":")
        elif it[0] == "raw":
            out.append(it[1])
        else:
            out.append(it[1].text)
    nblocks = len(blocks)
    open(a.output, "w").write("; generated by tools/cycacc.py from %s - do not edit\n" % os.path.basename(a.source)
                              + "\n".join(out) + "\n")
    if a.report:
        print("blocks: %d, markers: %d" % (nblocks, nmark))


if __name__ == "__main__":
    main()
