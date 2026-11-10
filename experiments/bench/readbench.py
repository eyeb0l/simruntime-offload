"""Uncached read benchmark: sequential throughput and random-read latency.

Uses F_NOCACHE so results do not depend on what the page cache already holds.
Usage: readbench.py <label> <file> [seq_bytes] [random_reads]
"""
import fcntl, os, random, statistics, sys, time

F_NOCACHE = 48
label, path = sys.argv[1], sys.argv[2]
seq_bytes = int(sys.argv[3]) if len(sys.argv) > 3 else 1536 * 1024 * 1024
n_random = int(sys.argv[4]) if len(sys.argv) > 4 else 1500

fd = os.open(path, os.O_RDONLY)
fcntl.fcntl(fd, F_NOCACHE, 1)
size = os.fstat(fd).st_size
seq_bytes = min(seq_bytes, size)

chunk = 4 * 1024 * 1024
done = 0
t0 = time.perf_counter()
while done < seq_bytes:
    data = os.pread(fd, min(chunk, seq_bytes - done), done)
    if not data:
        break
    done += len(data)
seq_s = time.perf_counter() - t0

rng = random.Random(1234)
block = 64 * 1024
lat = []
for _ in range(n_random):
    off = rng.randrange(0, max(1, size - block)) // 4096 * 4096
    t = time.perf_counter()
    os.pread(fd, block, off)
    lat.append((time.perf_counter() - t) * 1000)
os.close(fd)
lat.sort()
print(f"{label}: seq {done/1e6/seq_s:7.0f} MB/s over {done/1e9:.2f} GB | "
      f"random 64K x{n_random}: median {statistics.median(lat):6.2f} ms, "
      f"p95 {lat[int(len(lat)*0.95)]:6.2f} ms, p99 {lat[int(len(lat)*0.99)]:6.2f} ms")
