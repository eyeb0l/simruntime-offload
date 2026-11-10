"""Concurrent uncached random-read benchmark across many files.

Usage: parbench.py <label> <directory> <threads> [reads]
Reads random 16 KiB blocks from files under the directory, as a boot does.
"""
import fcntl, os, random, sys, threading, time

label, root, threads = sys.argv[1], sys.argv[2], int(sys.argv[3])
total = int(sys.argv[4]) if len(sys.argv) > 4 else 6000
files = []
for d, _, names in os.walk(root):
    for n in names:
        p = os.path.join(d, n)
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if (st.st_mode & 0o170000) == 0o100000 and st.st_size >= 65536:
            files.append((p, st.st_size))
    if len(files) > 4000:
        break
rng = random.Random(99)
plan = [(rng.choice(files)) for _ in range(total)]
offs = [rng.randrange(0, s - 16384) // 4096 * 4096 for _, s in plan]
idx = [0]
lock = threading.Lock()
lat = []

def worker():
    while True:
        with lock:
            i = idx[0]
            idx[0] += 1
        if i >= total:
            return
        t = time.perf_counter()
        try:
            fd = os.open(plan[i][0], os.O_RDONLY)
            fcntl.fcntl(fd, 48, 1)
            os.pread(fd, 16384, offs[i])
            os.close(fd)
        except OSError:
            pass
        lat.append((time.perf_counter() - t) * 1000)

t0 = time.perf_counter()
ts = [threading.Thread(target=worker) for _ in range(threads)]
[t.start() for t in ts]
[t.join() for t in ts]
el = time.perf_counter() - t0
lat.sort()
print(f"{label} threads={threads:2d}: {total/el:7.0f} reads/s | median {lat[len(lat)//2]:6.2f} ms, p99 {lat[int(len(lat)*0.99)]:7.2f} ms ({len(files)} files)")
