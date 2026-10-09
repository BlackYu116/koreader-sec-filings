# KOReader SEC Filings — SEC 研习室

**Version 0.2.1** · [中文使用说明](README.zh-CN.md)

> Version 0.2.1 was deployed to the test Kindle on 2026-10-09. Isolated device tests and the real storage/preview/cancel UI passed; the user then separately approved removal of 29 existing residue files, which completed with settings and company indexes unchanged. See [deployment](docs/DEPLOYMENT-0.2.1.md) and [lifecycle validation](docs/VALIDATION-LIFECYCLE.md).

Read SEC EDGAR filings as local EPUBs in KOReader. Download an individual filing, preserve its source snapshot, and optionally produce a separate Chinese edition using your own DeepSeek account. No AI-assistant plugin is required.

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

- **搜索公司…**: search, then reopen **搜索结果** as prompted. Selecting a dated filing downloads only that accession.
- **下载某一家 / 下载全部关注的公司**: download recent new filings according to your preferences.
- **打开下载目录**: browse generated books.
- **已有原文 → 生成 / 续译中文版**: choose an original and review translation limits.
- **设置 → 翻译设置（DeepSeek）**: enter a Key on the device, select the model and limits, or enable cache-only mode.

Books default to `/mnt/us/documents/SEC 财报/`. Snapshots, assets and translation caches live under `/mnt/us/secfilings-work/`.

## Storage and deletion

Open **存储与清理** to inspect local outputs, snapshots, filing-owned caches and possible leftovers. Opening the menu is read-only; there is no background deletion watcher. Books removed using KOReader, USB or a computer are checked on the next visit. Missing paths are not proof of deletion: moved/renamed books require a human decision before discarding their former auxiliary data.

A local filing also offers **删除整份资料及本地阅读记录…**. A destructive confirmation states the number of EPUBs/files, estimated space and whether local sidecars are included. Remaining original/Chinese editions protect their common data during residue cleanup. Changed assets, unknown files/directories, symlinks, hard links, interrupted publication and unavailable roots fail closed. Close the reader before deleting.

New translation caches belong to a CIK/accession. Valid old shared-cache hits are reused without writing during estimation; execution may copy them into the filing cache. Deleting one filing never clears the shared cache. Clearing that cache is a separate confirmation because retranslating may incur costs. Company search indexes, credentials, subscriptions and incremental baselines are not deleted with books.

Legacy cleanup is limited to recognized default-company sidecars and known local metadata/cover/progress files. Global reading history, collections and centralized/hash metadata are intentionally not purged. Unknown content is retained. Interrupted cleanup requires a fresh preview/confirmation; bounded JSON checkpoints are not executable deletion authority. These safeguards do not constitute cross-process or power-loss filesystem transactions.

## Translation and cost controls

The default model is `deepseek-flash`, with thinking disabled. The account must support the configured model. Only official DeepSeek HTTPS Chat Completions endpoints are accepted; custom credential destinations and redirects are rejected.

Default per-run limits: **one filing, 20 attempted requests, 48,000 protected input bytes**. Request presets are 5, 10 or 20. Each request allows at most 4,096 output tokens. These are **not monetary limits**, and the input counter excludes system-prompt overhead. Failed requests may incur charges. There are no automatic retries after a failure.

Large filings can require several separately confirmed runs. Text nodes are currently translated individually, not batched. Cached blocks are validated and reused. A completed Chinese edition is not silently replaced when the model changes.

Keys remain in KOReader's local settings, not in an encrypted vault. The editor does not preload the stored Key. Protect the device and settings backups. No Key belongs in an issue, source tree or EPUB.

## Upgrading from the aggregate-book version

The original `sec_watchlist` setting remains untouched. A separate `sec_watchlist_filings` setting inherits subscriptions but starts an independent per-filing baseline. The first incremental run takes only the configured recent filings; it does not backfill the full history.

Legacy EPUBs and sidecars remain in place. They are not automatically imported as translation snapshots. Search for and download the desired individual filing to translate it.

## Validation

The released 0.2.0 version was installed and loaded on the test Kindle; the separate 0.2.1 deployment record describes cleanup validation and its remaining boundaries. Validation includes offline engine/orchestration/state tests; the actual `main.lua` under native Kindle JSON, lfs and SHA dependencies; native libarchive EPUB creation; and screen captures plus native input-event testing of menus, search, exact-filing download and reading.

A real Apple 10-Q filed on 2026-07-31 was downloaded through the production UI. ZIP/XML, navigation, 70 tables, embedded source imagery and the cover passed independent checks. Tests and the explicit-sandbox shell entry point are in `tools/verify/`.

**No paid DeepSeek request was made for release validation.** Deterministic fixture translations prove plumbing and preservation checks, not model quality. Numeric/placeholder checks cannot establish financial semantic accuracy. Chinese output is a reading aid, not a replacement for SEC originals.

Simulated interruption tests do not establish power-loss/fsync durability. Arbitrary SEC HTML, other devices, all font sizes and all third-party patches are not covered by the test sample. Upstream/network failures and unavailable images are reported rather than concealed.

## License

The existing [AGPL-3.0 license](LICENSE) is unchanged. KOReader and SEC are not affiliated with or endorsing this plugin. Filings remain attributable to their original issuers and SEC source links.
