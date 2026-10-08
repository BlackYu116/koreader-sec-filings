# Version 0.2.0 validation

As of 2026-10-08, 13:48 PDT. This is a local installed build, not a GitHub Release or a guarantee of universal compatibility.

## Installed environment

- Kindle Paperwhite 5, KOReader v2026.07.2.
- 13 runtime Lua modules and 8 cover assets installed in the production plugin directory.
- Source, repository and installed module bytes matched; installed cover bytes matched the package assets.
- Normal KOReader menu restart was used. No device reboot, launcher change, rootfs write or user-patch edit.

## Automated checks

| Check | Result |
| --- | --- |
| Translation engine regression | 57 passed; no network requests |
| Per-filing orchestration | 19 passed; SEC transport and EPUB writer are spies |
| Library state/cache/recovery | 32 passed; explicit offline adapters |
| Actual main.lua UI contracts | 27 passed; fake UI/network objects |
| Total independent offline checks | 135 passed in the repository |
| Native Kindle shell entry | 27 passed using native JSON, lfs and SHA |
| Syntax | 13 runtime modules and 6 test scripts passed |
| Whitespace/diff validation | `git diff --check` passed |

The UI checks cover legacy baseline preservation, independent new baselines, idempotent reload, real search-result field names, exact filing selection, no-Key/cache-only paths, request confirmation, duplicate activation, coroutine yielding and progress throttling. A fixed-clock fixture verifies that 1,000 local progress callbacks do not each incur KOReader's 100 ms progress delay.

## Production UI and real content

Native KOReader input events were sent through its input helper, and the framebuffer was read back. This exercised actual widgets and handlers, not only UI spies. It is not a physical-finger calibration test.

Verified:

1. Version 0.2.0 appears in the Tools menu.
2. Searching `AAPL` returns SEC filings; filtering annual/quarterly/current reports works.
3. Selecting the 2026-07-31 10-Q downloads only accession `0000320193-26-000020`.
4. The resulting 88,852-byte original EPUB appears in the company/CIK directory and opens in the reader.
5. Financial tables and the source image render on the device, including aligned financial numbers.
6. The filing appears in the local translation menu.
7. Without a Key, the production UI stops before a paid request and displays the missing-Key/cache-only guidance.
8. After progress throttling was installed and KOReader restarted, that report's preflight reached the guidance in seconds rather than spending 100 ms on each text-node update.

Independent Python checks passed ZIP CRC, XML well-formedness, navigation targets, image references, cover metadata, 70 tables and presentation cleanup. The exact saved source XHTML is retained in the EPUB. A separate raw-table numeric-token comparison found 1,041 input tokens, 1,078 output tokens after table projection, and zero missing multiplicities. This is numeric-token coverage, not proof of every possible row/column semantic relationship.

Native libarchive also generated original/Chinese fixture pairs. Their deterministic translation responses are test data, not real model outputs.

## Upgrade preservation

- All seven pre-existing EPUB files remained byte-identical.
- Every pre-existing plugin setting, including the entire old subscription record, compared equal to the pre-upgrade backup.
- Seven company subscriptions were copied to an independent per-filing baseline without treating old aggregate books as resumable snapshots.
- New book opening and normal KOReader use may update reading history or sidecar timestamps. No blanket byte-equality claim is made for active reading sidecars.
- Complete old-plugin and settings backups were retained outside the live plugin directory.

## Explicit limitations

No paid DeepSeek API request was made; the device had no Key. Real provider/model compatibility and Chinese financial semantics remain unverified. Request limits are not currency caps. Large filings can need multiple confirmed runs, and text nodes are not batched.

Power-loss/fsync durability, other firmware/devices, every font size and arbitrary SEC HTML are not exhaustively verified. Legacy aggregate EPUBs are retained rather than automatically imported for translation.
