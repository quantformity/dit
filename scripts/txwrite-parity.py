#!/usr/bin/env python3
"""Real write/read parity, with separately captured byte streams and error immutability.
Build: go test -c -o .build/txwrite-test ./internal/cli
Run: DIT_TXWRITE_BINARY=1 GO=$PWD/.build/txwrite-test python3 scripts/txwrite-parity.py
UUIDs are random by contract; only UUID/path identities are mapped for comparison.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

SWIFT = os.environ.get('SWIFT', '/opt/homebrew/bin/dit')
GO = os.environ.get('GO', str(Path('.build/ditgo').resolve()))
passed = 0
with tempfile.TemporaryDirectory(prefix='dit-txwrite-') as tmp:
    root = Path(tmp).resolve()
    seed, a, b = [root / s for s in ('seed', 'swift', 'go')]
    def run(binary, home, args):
        env = dict(os.environ, DIT_BACKEND='file', DIT_STORE_URL=str(home / 'store'),
                   DIT_MARKET_URL=str(home / 'market'), NO_COLOR='1', TERM='dumb')
        return subprocess.run([binary, *args], env=env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    for name in ('TFSA',):
        result = run(SWIFT, seed, ['account', 'add', '--name', name, '--currency', 'CAD'])
        assert result.returncode == 0, result.stderr
    shutil.copytree(seed, a)
    # Go starts with no store: it imports account metadata, then builds its own
    # transaction ledger entirely with Go entry/correction commands.
    result = run(SWIFT, seed, ['store', 'export', '--to', str(root / 'accounts.json')])
    assert result.returncode == 0, result.stderr
    result = run(GO, b, ['store', 'import', str(root / 'accounts.json'), '--yes'])
    assert result.returncode == 0, result.stderr
    def portfolio(home):
        return json.loads((home / 'store' / 'portfolio.dat').read_bytes())
    identities = {}
    def normalize(data, home, go=False):
        if go:
            for x, y in identities.items():
                data = data.replace(x.encode(), y.encode())
        # Darwin's oracle canonicalizes /tmp to /private/tmp.
        return data.replace(str(home).encode(), b'<STORE>')
    def compare(args_a, args_b=None, failing=False):
        global passed
        before = {p.relative_to(b): p.read_bytes() for p in b.rglob('*') if p.is_file()}
        ra, rb = run(SWIFT, a, args_a), run(GO, b, args_b or args_a)
        pa, pb = portfolio(a), portfolio(b)
        for ta, tb in zip(pa['transactions'], pb['transactions']):
            identities[tb['id']] = ta['id']
            identities[tb['id'][:8]] = ta['id'][:8]
        assert ra.returncode == rb.returncode, (args_a, ra.returncode, rb.returncode, ra.stderr, rb.stderr)
        assert normalize(ra.stdout, a) == normalize(rb.stdout, b, True), (args_a, ra.stdout, rb.stdout)
        assert normalize(ra.stderr, a) == normalize(rb.stderr, b, True), (args_a, ra.stderr, rb.stderr)
        if failing:
            assert rb.returncode != 0
            after = {p.relative_to(b): p.read_bytes() for p in b.rglob('*') if p.is_file()}
            assert before == after, ('failed command mutated store', args_a)
        passed += 1
        print('ok —', ' '.join(args_a))
    entries = [
        ['deposit', '--account', 'TFSA', '--amount', '10000', '--date', '2024-01-01'],
        ['withdraw', '--account', 'TFSA', '--amount', '100', '--date', '2024-01-02'],
        ['buy', '--account', 'TFSA', '--ticker', 'ABC', '--shares', '5', '--price', '10', '--fee', '1', '--date', '2024-01-03'],
        ['sell', '--account', 'TFSA', '--ticker', 'ABC', '--shares', '2', '--price', '12', '--date', '2024-01-04'],
        ['dividend', '--account', 'TFSA', '--ticker', 'ABC', '--amount', '2.25', '--date', '2024-01-05'],
        ['gic', '--account', 'TFSA', '--product', 'Bond', '--principal', '1000', '--rate', '4.1', '--compounding', 'monthly', '--maturity', '2028-01-01'],
        ['gic-redeem', '--account', 'TFSA', '--gic', 'Bond', '--proceeds', '1100', '--date', '2024-01-08'],
        ['fx', '--account', 'TFSA', '--from', 'CAD', '--to', 'USD', '--from-amount', '100', '--to-amount', '75', '--date', '2024-01-06'],
    ]
    for entry in entries:
        compare(['tx', *entry])
        if entry[0] == 'gic':
            ta, tb = portfolio(a)['transactions'][-1], portfolio(b)['transactions'][-1]
            compare(['tx', 'edit', ta['id'][:8], '--date', '2024-01-07'],
                    ['tx', 'edit', tb['id'][:8], '--date', '2024-01-07'])
    def read_checks():
        for args in [['accounts'], ['tx', 'list'], ['tx', 'list', '--kind', 'sell'],
                     ['summary', '--offline'], ['market', 'coverage']]:
            compare(args)
        for ta, tb in zip(portfolio(a)['transactions'], portfolio(b)['transactions']):
            compare(['tx', 'show', ta['id'][:8]], ['tx', 'show', tb['id'][:8]])
    read_checks()
    ta, tb = portfolio(a)['transactions'][2], portfolio(b)['transactions'][2]
    compare(['tx', 'edit', ta['id'][:8], '--shares', '6', '--fee', '0'],
            ['tx', 'edit', tb['id'][:8], '--shares', '6', '--fee', '0'])
    compare(['tx', 'edit', ta['id'][:8], '--shares', '0'],
            ['tx', 'edit', tb['id'][:8], '--shares', '0'], failing=True)
    compare(['tx', 'delete', ta['id'][:8]], ['tx', 'delete', tb['id'][:8]], failing=True)
    compare(['tx', 'delete', ta['id'][:8], '--yes'], ['tx', 'delete', tb['id'][:8], '--yes'])
    read_checks()
    for entry in [
        ['deposit', '--account', 'TFSA', '--amount', '0'],
        ['deposit', '--account', 'TFSA', '--amount', 'bad'],
        ['buy', '--account', 'TFSA', '--ticker', 'X', '--shares', '1', '--price', '-1'],
        ['buy', '--account', 'TFSA', '--ticker', 'X', '--shares', '1', '--offline'],
        ['fx', '--account', 'TFSA', '--from', 'CAD', '--to', 'CAD', '--from-amount', '1', '--to-amount', '1'],
    ]:
        compare(['tx', *entry], failing=True)
    # Machine facts must agree too, not just their human presentation.
    pa, pb = portfolio(a), portfolio(b)
    def canonical(p, go=False):
        raw = json.dumps(p, sort_keys=True).encode()
        if go:
            for x, y in identities.items():
                raw = raw.replace(x.encode(), y.encode())
        p = json.loads(raw)
        for tx in p['transactions']:
            if 'gicPurchase' in tx['kind']:
                tx['date'] = int(tx['date'] // 86400)  # implicit Date() differs in subsecond instant
        return p
    assert canonical(pa) == canonical(pb, True)
print(f'txwrite-parity: {passed} identical, 0 differing; failed stores byte-identical')
