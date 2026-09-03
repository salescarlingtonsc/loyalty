"""Split normalise.sql into chunks of N guarded blocks, each a complete transaction carrying the
helper functions, so every chunk finishes well inside the API gateway's 100 s limit. Blocks are
idempotent (exact match -> skip), so re-running any chunk is harmless."""
import pathlib, re, sys
S = pathlib.Path('/private/tmp/claude-501/-Users-cs-Downloads-loyalty-main/b2eb2901-2f29-4ab9-8d07-185769b6d407/scratchpad')
src = (S / 'normalise.sql').read_text()
# Block headers are "-- <regprocedure>" — public functions print WITHOUT the schema prefix.
hdr = re.compile(r'\n(?=-- [a-z_][a-z0-9_.]*\()')
first = hdr.search(src)
head, body = src[:first.start()], src[first.start() + 1:]
body = body.rsplit('\ncommit;', 1)[0]
blocks = hdr.split('\n' + body)
blocks = [b for b in blocks if b.strip()]
n = int(sys.argv[1]) if len(sys.argv) > 1 else 12
out = S / 'normalise-chunks'; out.mkdir(exist_ok=True)
for f in out.glob('*.sql'): f.unlink()
for i in range(0, len(blocks), n):
    chunk = head + '\n' + '\n'.join(blocks[i:i + n]) + '\ncommit;\n'
    (out / f'chunk-{i // n + 1:02d}.sql').write_text(chunk)
print(len(blocks), 'blocks ->', (len(blocks) + n - 1) // n, 'chunks of', n)
