#!/usr/bin/env python3
"""Parse a Windows minidump: exception code/address, modules, and the
crashing thread's return-address chain (stack scan). Usage:
  minidump_parse.py dump.dmp
"""
import struct
import sys

MDMP = 0x504D444D
STREAM_THREAD_LIST = 3
STREAM_MODULE_LIST = 4
STREAM_EXCEPTION = 6
STREAM_MEMORY64 = 9


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def u64(b, o):
    return struct.unpack_from("<Q", b, o)[0]


def main(path):
    data = open(path, "rb").read()
    if u32(data, 0) != MDMP:
        print("not a minidump"); return
    nstreams = u32(data, 8)
    dir_rva = u32(data, 12)
    streams = {}
    for i in range(nstreams):
        off = dir_rva + i * 12
        stype = u32(data, off)
        dsize = u32(data, off + 4)
        drva = u32(data, off + 8)
        streams[stype] = (drva, dsize)

    # modules
    mods = []
    if STREAM_MODULE_LIST in streams:
        rva, _ = streams[STREAM_MODULE_LIST]
        n = u32(data, rva)
        for i in range(n):
            off = rva + 4 + i * 108
            base = u64(data, off)
            size = u32(data, off + 8)
            name_rva = u32(data, off + 20)
            name = ""
            if name_rva and name_rva < len(data):
                end = data.index(b"\0", name_rva)
                name = data[name_rva:end].decode("utf-8", "replace")
            mods.append((base, size, name))

    def mod_for(addr):
        for base, size, name in mods:
            if base <= addr < base + size:
                return name, addr - base
        return None, addr

    # exception
    if STREAM_EXCEPTION not in streams:
        print("no exception stream"); return
    rva, _ = streams[STREAM_EXCEPTION]
    tid = u32(data, rva)
    code = u32(data, rva + 8)
    exc_addr = u64(data, rva + 24)
    print(f"thread id: {tid}")
    print(f"exception: 0x{code:08x} at 0x{exc_addr:x}")
    m, r = mod_for(exc_addr)
    print(f"  in {m} (rva 0x{r:x})" if m else "  module unknown")

    # crashing thread: stack range + context
    stack_range = None
    ctx = None
    if STREAM_THREAD_LIST in streams:
        rva2, _ = streams[STREAM_THREAD_LIST]
        n = u32(data, rva2)
        for i in range(n):
            off = rva2 + 4 + i * 48
            t = u32(data, off)
            if t == tid:
                s_start = u64(data, off + 24)
                s_rva = u32(data, off + 32)
                s_size = u32(data, off + 36)
                stack_range = (s_start, s_rva, s_size)
                c_size = u32(data, off + 40)
                c_rva = u32(data, off + 44)
                ctx = (c_rva, c_size)
                break
    print(f"stack: {stack_range}")
    if not ctx:
        print("no context"); return

    # memory ranges (64-bit list)
    ranges = []
    if STREAM_MEMORY64 in streams:
        rva3, _ = streams[STREAM_MEMORY64]
        n = u64(data, rva3)
        base_rva = u64(data, rva3 + 8)
        off = rva3 + 16
        for i in range(n):
            start = u64(data, off + i * 16)
            size = u64(data, off + i * 16 + 8)
            ranges.append((start, base_rva, size))
            base_rva += size

    def read_mem(addr, size):
        for start, mrva, msize in ranges:
            if start <= addr < start + msize:
                o = mrva + (addr - start)
                if o + size <= len(data):
                    return data[o:o + size]
        return None

    c_rva, c_size = ctx
    # AMD64 CONTEXT: Rsp at 0x98, Rip at 0xF8 (relative to context start)
    if c_size >= 0x100:
        rsp = u64(data, c_rva + 0x98)
        rip = u64(data, c_rva + 0xF8)
        print(f"context rip=0x{rip:x} rsp=0x{rsp:x}")
    else:
        rsp, rip = None, None

    # scan the stack for return addresses into known modules
    if rsp:
        found = []
        seen = set()
        for addr in range(rsp, rsp + 0x20000, 8):
            chunk = read_mem(addr, 8)
            if not chunk:
                continue
            v = struct.unpack("<Q", chunk)[0]
            m, r = mod_for(v)
            if m and v not in seen:
                seen.add(v)
                found.append((v, m, r))
        for v, m, r in found[:60]:
            print(f"  ret 0x{v:x} in {m} (rva 0x{r:x})")

    # memory summary
    if STREAM_MEMORY64 in streams:
        n = u64(data, rva3)
        total = 0
        for i in range(n):
            total += u64(data, rva3 + 16 + i * 16 + 8)
        print(f"memory ranges: {n}, total {total >> 20} MB")


if __name__ == "__main__":
    main(sys.argv[1])


def dump_extra(path):
    data = open(path, "rb").read()
    nstreams = u32(data, 8)
    dir_rva = u32(data, 12)
    streams = {}
    for i in range(nstreams):
        off = dir_rva + i * 12
        streams[u32(data, off)] = (u32(data, off + 8), u32(data, off + 4))
    if 4 in streams:
        rva, _ = streams[4]
        n = u32(data, rva)
        print(f"modules: {n}")
        for i in range(min(n, 12)):
            off = rva + 4 + i * 108
            base = u64(data, off)
            size = u32(data, off + 8)
            name_rva = u32(data, off + 20)
            end = data.index(b"\0", name_rva)
            print(f"  {hex(base)} size={hex(size)} {data[name_rva:end].decode('utf-8', 'replace')}")


def dump_bytes(path, addr, n=64):
    data = open(path, "rb").read()
    nstreams = u32(data, 8)
    dir_rva = u32(data, 12)
    streams = {}
    for i in range(nstreams):
        off = dir_rva + i * 12
        streams[u32(data, off)] = (u32(data, off + 8), u32(data, off + 4))
    ranges = []
    if 9 in streams:
        rva3, _ = streams[9]
        n_ranges = u64(data, rva3)
        base_rva = u64(data, rva3 + 8)
        off = rva3 + 16
        for i in range(n_ranges):
            start = u64(data, off + i * 16)
            size = u64(data, off + i * 16 + 8)
            ranges.append((start, base_rva, size))
            base_rva += size
    for start, mrva, msize in ranges:
        if start <= addr < start + msize:
            o = mrva + (addr - start)
            chunk = data[o:o + n]
            print(f"memory at 0x{addr:x}:")
            for i in range(0, len(chunk), 16):
                row = chunk[i:i + 16]
                hexs = " ".join(f"{b:02x}" for b in row)
                asci = "".join(chr(b) if 32 <= b < 127 else "." for b in row)
                print(f"  +{i:02x}  {hexs:<48} {asci}")
            return
    print("address not in dump")
