#!/usr/bin/env python3
"""Generate an unused bundle resource to target 50 MB without runtime allocation."""

import os
from pathlib import Path

TARGET_BYTES = 50_000_000
# CodeResources is generated after this phase; leave room for signing metadata.
SIGNATURE_ALLOWANCE = 16_384
bundle = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['WRAPPER_NAME']
reserve = bundle / 'SizeReserve.dat'
existing = sum(
    p.stat().st_size for p in bundle.rglob('*')
    if p.is_file() and p != reserve and '_CodeSignature' not in p.parts
)
remaining = max(0, TARGET_BYTES - existing - SIGNATURE_ALLOWANCE)
with reserve.open('wb') as output:
    while remaining:
        chunk = min(remaining, 1_048_576)
        output.write(os.urandom(chunk))
        remaining -= chunk
print(f'Bundle size reserve: {reserve.stat().st_size} bytes; target 50 MB')
