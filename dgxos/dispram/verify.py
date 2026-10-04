"""Fill/verify the whole display carveout through dispramd, as an unprivileged CUDA client (no torch).
Run it while NOTHING borrows the carveout (engine stopped): it claims the whole slice.
Passes: 0x5A5A5A5A, 0xA5A5A5A5 (every bit both ways), word-unique address pattern, then the same address
pattern re-checked after HOLD seconds while the box keeps serving (nothing else may write the carveout)."""
import array, ctypes as C, os, socket, sys, time
sys.path.insert(0, "/opt/kindling/dispram/python")
import dispram
HOLD = int(os.environ.get("HOLD", "120"))
cu = C.CDLL("libcuda.so.1")
def ck(rc, what):
    if rc: raise SystemExit(f"FAIL {what}: CUresult {rc}")
ck(cu.cuInit(0), "cuInit"); dev = C.c_int(); ck(cu.cuDeviceGet(C.byref(dev), 0), "cuDeviceGet")
ctx = C.c_void_p(); ck(cu.cuDevicePrimaryCtxRetain(C.byref(ctx), dev), "ctx"); ck(cu.cuCtxSetCurrent(ctx), "setctx")
for n in ("cuMemcpyHtoD_v2", "cuMemcpyDtoH_v2", "cuMemcpyDtoD_v2", "cuMemsetD32_v2", "cuMemAlloc_v2", "cuMemFree_v2", "cuCtxSynchronize"):
    getattr(cu, n).restype = C.c_int
info = dispram.info(); print(f"{socket.gethostname()}: dispramd info base=0x{info['base']:x} size={info['size']>>20} MiB free={info['free']>>20} MiB")
claim = dispram.reserve_bytes()
ptr, total, tail = dispram.map_glued(claim, 0)
print(f"claimed {claim>>20} MiB; mapped 0x{ptr:x} total={total>>20} MiB tail(carveout)={tail>>20} MiB")
assert tail == claim == total, "expected the whole mapping to be carveout"
BLK = 2 << 20; W = BLK // 4; nblk = total // BLK
host = C.create_string_buffer(BLK)
def verify_const(v, label):
    want = array.array("I", [v]).tobytes() * W; bad = 0
    for i in range(nblk):
        ck(cu.cuMemcpyDtoH_v2(host, C.c_uint64(ptr + i * BLK), C.c_size_t(BLK)), "DtoH")
        if host.raw != want: bad += 1
    print(f"  {label}: {nblk - bad}/{nblk} blocks exact"); return bad
def fill_const(v):
    ck(cu.cuMemsetD32_v2(C.c_uint64(ptr), C.c_uint(v), C.c_size_t(total // 4)), "memset"); ck(cu.cuCtxSynchronize(), "sync")
def pat(i): return array.array("I", range(i * W, (i + 1) * W)).tobytes()
def fill_addr():
    for i in range(nblk):
        b = pat(i); ck(cu.cuMemcpyHtoD_v2(C.c_uint64(ptr + i * BLK), b, C.c_size_t(BLK)), "HtoD")
    ck(cu.cuCtxSynchronize(), "sync")
def verify_addr(label):
    bad = 0; badwords = 0
    for i in range(nblk):
        ck(cu.cuMemcpyDtoH_v2(host, C.c_uint64(ptr + i * BLK), C.c_size_t(BLK)), "DtoH")
        if host.raw != pat(i):
            bad += 1; got = array.array("I", host.raw); exp = array.array("I", pat(i))
            badwords += sum(1 for a, b in zip(got, exp) if a != b)
    print(f"  {label}: {nblk - bad}/{nblk} blocks exact, {badwords} wrong words of {nblk * W:,}"); return bad
t0 = time.time(); bad = 0
for v, lab in ((0x5A5A5A5A, "0x5A5A5A5A"), (0xA5A5A5A5, "0xA5A5A5A5")):
    fill_const(v); bad += verify_const(v, lab)
fill_addr(); bad += verify_addr("address pattern")
# bandwidth: 256 MiB ordinary <-> carveout
N = 256 << 20; plain = C.c_uint64(); ck(cu.cuMemAlloc_v2(C.byref(plain), C.c_size_t(N)), "alloc plain")
def bw(dst, src, label, reps=8):
    ck(cu.cuCtxSynchronize(), "sync"); t = time.time()
    for _ in range(reps): ck(cu.cuMemcpyDtoD_v2(C.c_uint64(dst), C.c_uint64(src), C.c_size_t(N)), "DtoD")
    ck(cu.cuCtxSynchronize(), "sync"); dt = time.time() - t
    print(f"  copy {label}: {reps * N / dt / 1e9:.0f} GB/s (counted once, read+write = 2x traffic)")
dst2 = ptr + total - N  # tail end of the carveout; refill the address pattern after
bw(dst2, plain.value, "ordinary -> carveout"); bw(plain.value, dst2, "carveout -> ordinary")
ck(cu.cuMemFree_v2(plain), "free")
fill_addr()
print(f"  holding the pattern {HOLD} s while the engine serves ..."); time.sleep(HOLD)
bad += verify_addr(f"address pattern after {HOLD} s")
print(f"RESULT {'PASS' if bad == 0 else 'FAIL'} in {time.time() - t0:.0f} s")
