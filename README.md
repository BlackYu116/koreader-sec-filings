# KOReader SEC Filings — SEC 研习室

> **2026-10-12 23:58 PDT更新：r4已安装、正常重启，31文件hash匹配。设备52930项通过，真实第一批产品名修复通过；第二请求HTTP0停止，累计70次，新增缓存合计386片段，整本仍未完成。** 详见仓库`docs/DEPLOYMENT-0.2.8.md`；下方旧“未安装”状态不再有效。

> Latest 2026-10-12 23:20 PDT: real testing stopped after 68 requests; full-book acceptance remains incomplete. Device runs r3. Candidate-r4 adds exact standalone product labels and passes 52,930 host checks but is not installed. See [deployment status](docs/DEPLOYMENT-0.2.8.md). Earlier status below is historical.

**Version 0.2.8 candidate — device acceptance in progress** · [中文使用说明](README.zh-CN.md)

> 2026-10-12 22:19 PDT: installed and normally restarted. Host and device-dependency suites pass 583 ordinary plus 52,336 scan checks. Real cancellation and cached continuation were tested; full Chinese-book acceptance remains incomplete. The latest candidate-r3 fixes output-budget, month-digit and standalone-trademark issues found during 35 real requests. Device access is currently blocked pending wake-up. See [deployment and remaining checks](docs/DEPLOYMENT-0.2.8.md).

## New in the 0.2.8 candidate

- Read verified originals/Chinese editions directly from local records and result dialogs.
- Persistent scrollable result details, live watch/thinking checkmarks, explicit search refresh and pending-search cancellation.
- Translate ordinary uppercase headings, reject obvious untranslated echoes, preserve inline whitespace and validate legacy caches before reuse.
- Bound SEC Source response bytes while receiving; this does not solve cleaner/ReaderUI peak memory or long synchronous cancellation.
- Existing books and reading state are not silently rebuilt. Real UI, full paid translation and deep-sleep acceptance remain pending.

### Historical 0.2.7 deployment

> 2026-10-12: installed and normally restarted on the test Kindle, with zero-paid UI and real Apple preflight acceptance. A placeholder-expansion compatibility issue found on-device was fixed. The real plan is 540 remaining fragments in 100 requests; it was cancelled without model dispatch. Host and device-dependency regressions pass 516 ordinary plus 52,336 scan checks. Real model quality, a complete Chinese filing, production memory and deep sleep remain unverified. See [deployment and limits](docs/DEPLOYMENT-0.2.7.md). Public main was last verified on 0.2.4; no new publication.

## New in 0.2.7

- Bounded batches of up to eight original fragments, individually validated; preserve HTML and reuse validated v2 caches.
- A separate **整份剩余译文** action preflights finite request, protected-text and complete-HTTP-body limits, then requires explicit confirmation. No silent budget resets, automatic retries or paid restart recovery.
- Suspend revokes queued network authorizations too; task exceptions and persistence failures stop safely.
- Temporary recent-N downloads bypass subscription state; tracked updates keep their persistent fixed queue. Failed subscription saves roll back and partial search results remain explicitly incomplete.

Read SEC EDGAR filings as local EPUBs in KOReader. Download an individual filing, preserve its source snapshot, and optionally produce a separate Chinese edition using your own DeepSeek account. No AI-assistant plugin is required.

## New in 0.2.3–0.2.4: download reliability

- Reuse successful company metrics within one batch and checkpoint completed filings individually.
- Preserve cancellation through image fetching and release temporary power protection on completion or failure.
- Renew Kindle's native idle timer safely even when AutoSuspend is disabled, without permanently inhibiting manual sleep.
- Skip redundant HTML scans and transfer raw-response ownership to reduce retained memory without dropping text, tables or images.
- An optional Special Offers screensaver companion is in `contrib/kindle/`; it requires separate backup and installation, not automatic plugin installation.

Historical 0.2.4 did not persist a fixed retry queue. This candidate retains the 0.2.5–0.2.6 fixed queue, translation-validator and search repairs. Missing books do not silently reset download history. Production memory risk and long-hibernation acceptance remain separate unfinished device work.

## Earlier in 0.2.2: recovery and search

The `feat/recovery-location-search` branch adds explicit offline original reconstruction, hash-verified relinking within the configured SEC library, and an immediate search-results panel. These additions are installed on the test Kindle as 0.2.2.

- Restore a missing original from its valid snapshot and assets after confirmation. Source/translation records, Chinese EPUBs and reading sidecars are preserved. Relink a moved book first to avoid making another copy.
- Relink an original or Chinese edition by selecting an identical-content candidate inside the managed library. Only location metadata is changed; books and sidecars are not moved. External locations, modified content and unsafe links are refused.
- Search, company selection, filtering and pagination display results directly. Positions are retained; complete result sets can be filtered locally. Partial sets keep a visible warning, failed requests preserve valid results, and obsolete callbacks cannot replace a newer query.
- Corrupt snapshots, missing assets and unproven interrupted staging remain blocked. Ordinary receipt-write errors clean up only verifiably owned scratch from that attempt; unknown crash residue is not silently discarded. This is not a power-loss or cross-process transaction guarantee.

The three-year search window and platform restrictions remain unchanged. See [development validation](docs/VALIDATION-RECOVERY-SEARCH.md) for test and deployment boundaries.

Project handoff and planning boundaries: [current project status](docs/PROJECT-STATUS.md). The full local host-test runner/adapters are outside this Git repository; clean-clone CI is still pending.

## Features

- Search by ticker, CIK or company name; filter annual, quarterly and other filing types.
- Select exactly one accession, or follow companies for incremental downloads.
- Store independent original/Chinese editions under company-and-CIK folders.
- Clean presentational HTML, adapt wide tables and include downloadable images and a cover.
- Resume translation from validated local snapshots and successful block caches, without downloading the original again.
- Confirm the model, cache estimate and request limits before a paid run; support cache-only operation.
- Preserve legacy aggregate books, subscription preferences and completed editions instead of silently overwriting their reading state.

Company-wide latest XBRL metrics are **opt-in** and explicitly labelled as unrelated to the selected filing period. They are not automatically inserted into historical filings.

## Install

Tested on a jailbroken Kindle Paperwhite 5 with KOReader v2026.07.2. Other platforms have not been validated.

1. Back up an existing `koreader/plugins/secfilings.koplugin/` and `koreader/settings/secfilings.lua`.
2. Copy `secfilings.koplugin/` into KOReader's `plugins/` directory.
3. Choose **Restart KOReader** from its menu.
4. Open **Tools → SEC 研习室 → 设置 → SEC 联系邮箱** and enter a contact email for SEC requests.

No launcher, user patch, root filesystem modification or background service is required. Do not overwrite the Kindle launcher to install this plugin.

## Use

The interface is Chinese. The Tools menu may span two pages.

- **搜索公司…**: search and view the results directly; filtering also returns to the results panel. Selecting a dated filing downloads only that accession.
- **下载某一家 / 搜索中的最近N份**: temporary recent-N selection, independent of subscription state.
- **更新关注公司**: manually check incremental updates or resume a frozen batch; not an automatic background schedule.
- **打开下载目录**: browse generated books.
- **已有原文**: choose an original, then a small-budget translation or **整份剩余译文**; both require preflight confirmation.
- **设置 → 翻译设置（DeepSeek）**: enter a Key on the device, select the model and limits, or enable cache-only mode.

Books default to `/mnt/us/documents/SEC 财报/`. Snapshots, assets and translation caches live under `/mnt/us/secfilings-work/`.

## Storage and deletion

Open **存储与清理** to inspect local outputs, snapshots, filing-owned caches and possible leftovers. Opening the menu is read-only; there is no background deletion watcher. Books removed using KOReader, USB or a computer are checked on the next visit. Missing paths are not proof of deletion: moved/renamed books require a human decision before discarding their former auxiliary data.

A local filing also offers **删除整份资料及本地阅读记录…**. A destructive confirmation states the number of EPUBs/files, estimated space and whether local sidecars are included. Remaining original/Chinese editions protect their common data during residue cleanup. Changed assets, unknown files/directories, symlinks, hard links, interrupted publication and unavailable roots fail closed. Close the reader before deleting.

New translation caches belong to a CIK/accession. Valid old shared-cache hits are reused without writing during estimation; execution may copy them into the filing cache. Deleting one filing never clears the shared cache. Clearing that cache is a separate confirmation because retranslating may incur costs. Company search indexes, credentials, subscriptions and incremental baselines are not deleted with books.

Legacy cleanup is limited to recognized default-company sidecars and known local metadata/cover/progress files. Global reading history, collections and centralized/hash metadata are intentionally not purged. Unknown content is retained. Interrupted cleanup requires a fresh preview/confirmation; bounded JSON checkpoints are not executable deletion authority. These safeguards do not constitute cross-process or power-loss filesystem transactions.

## Translation and cost controls

The default model is `deepseek-flash`, with thinking disabled. The account must support the configured model. Only official DeepSeek HTTPS Chat Completions endpoints are accepted; custom credential destinations and redirects are rejected.

Small-run defaults remain **one filing, 20 reserved/attempted requests and 48,000 protected text bytes**, with 5/10/20 presets. Whole-remaining-task limits equal the shown preflight plan, with hard ceilings of 1,000 requests, 2,000,000 protected bytes and 16,384,000 complete HTTP-body bytes. Each body is capped at 16,384 bytes and each request uses `max_tokens=4096`. These are **not monetary limits**: bytes are not tokens, and input, reasoning and failed attempts may incur charges. Existing model/thinking settings are preserved.

Batches contain at most eight original fragments (1,200 protected-byte packing target). Original blocks keep their legacy boundaries (default 2,400 raw bytes). Placeholder expansion can exceed that raw limit: these long blocks stand alone, still bounded by the 16,384-byte complete HTTP body cap and cumulative task limits. Each item retains its own protected numbers and must match the response ID/order/count. Invalid responses stop without split retries. Validated fragments are cached before cache-only EPUB assembly. Old v2 caches remain readable without clearing or promoting them in batch mode.

An attempt is reserved durably before dispatch; interrupted reservations may overcount an unsent request. Suspend/cancellation invalidates pending network callbacks and confirmations. New runs require fresh confirmation and never automatically reset the previous authorization. Cached or complete editions are not silently replaced. Placeholder/decimal-digit checks cannot establish financial semantic completeness or detect every numeric expression, such as Chinese number words.

Keys remain in KOReader's local settings, not in an encrypted vault. The editor does not preload the stored Key. Protect the device and settings backups. No Key belongs in an issue, source tree or EPUB.

## Upgrading from the aggregate-book version

The original `sec_watchlist` setting remains untouched. A separate `sec_watchlist_filings` setting inherits subscriptions but starts an independent per-filing baseline. The first incremental run takes only the configured recent filings; it does not backfill the full history.

Legacy EPUBs and sidecars remain in place. They are not automatically imported as translation snapshots. Search for and download the desired individual filing to translate it.

## Validation

Version 0.2.2 passed 267 device-dependency checks and 14 additional native-widget callback/rendering checks before deployment. Offline network replies, simulated link/case fixtures and programmatic widget callbacks are explicitly distinguished from end-to-end touch and model validation in its deployment record. Earlier 0.2.0 and 0.2.1 records preserve historical download and cleanup evidence. Validation includes offline engine/orchestration/state tests; the actual `main.lua` under native Kindle JSON, lfs and SHA dependencies; native libarchive EPUB creation; and screen captures plus native input-event testing of menus, search, exact-filing download and reading.

A real Apple 10-Q filed on 2026-07-31 was downloaded through the production UI. ZIP/XML, navigation, 70 tables, embedded source imagery and the cover passed independent checks. Tests and the explicit-sandbox shell entry point are in `tools/verify/`.

**No paid DeepSeek request was made for 0.2.7 candidate validation.** Earlier 0.2.6 repair used two separately authorized short probes, not a full-book translation. Deterministic fixture translations prove plumbing and preservation checks, not model quality. Numeric/placeholder checks cannot establish financial semantic accuracy. Chinese output is a reading aid, not a replacement for SEC originals.

Simulated interruption tests do not establish power-loss/fsync durability. Arbitrary SEC HTML, other devices, all font sizes and all third-party patches are not covered by the test sample. Upstream/network failures and unavailable images are reported rather than concealed.

## License

The existing [AGPL-3.0 license](LICENSE) is unchanged. KOReader and SEC are not affiliated with or endorsing this plugin. Filings remain attributable to their original issuers and SEC source links.
