# Structure-correction corpus v1

This directory contains deterministic, manually authored regression fixtures for `WrongLayoutCorrectionEngine`. It is test data, not captured product input.

## Provenance and fixed conditions

- Corpus version: `v1`
- Authored: 2026-07-20 KST
- Provenance: every row was written for this repository; no third-party corpus text is included.
- License: MIT, under the repository root `LICENSE`.
- Base commit: `9cc455c46e2a471a18fb288208c291ece65f62e6`; the authoring worktree contained uncommitted design and implementation changes.
- Random seed: `20260720`. Version 1 uses no random selection; the seed is reserved for deterministic future sampling and shuffling.
- Authoring environment: macOS 26.3.1 (25D2128), Xcode 26.5 (17F42), `C.UTF-8` process locale.
- Encoding: UTF-8, LF line endings, one header row, tab-separated fields.
- Input sources: `latin_to_korean` means an Apple ABC/U.S.-compatible physical QWERTY source; `korean_to_latin` means Korean Two-Set.
- System language evidence: `tune.tsv` and `holdout.tsv` use unavailable evidence. `system-evidence.tsv` injects each row's explicit English/Korean hit-or-miss and authoritative state; it never calls the live spell service, so user dictionaries, warm-up, and timeouts cannot change the test.
- Boundary: every fixture is evaluated at a space boundary.
- Split policy: policy-shaping examples are in `tune.tsv`; `holdout.tsv` contains separate regressions and must not be moved into tune merely to accommodate a rule change. `system-evidence.tsv` is a separate 20-row truth table for the two-language evidence policy.

## Fields

| Field | Meaning |
|---|---|
| `id` | Stable, unique row identifier. |
| `direction` | `latin_to_korean` or `korean_to_latin`; also selects the simulated input source. |
| `physical_keys` | ASCII QWERTY letter keys, with uppercase characters representing physical Shift. |
| `english_evidence` | `system-evidence.tsv` only: injected English `hit` or `miss`. |
| `korean_evidence` | `system-evidence.tsv` only: injected Korean `hit` or `miss`. |
| `authoritative` | `system-evidence.tsv` only: whether both injected answers are trustworthy (`yes`/`no`). |
| `expected_action` | `correct` when a decision is required, otherwise `preserve`. |
| `expected_original` | Text expected to be visible in the active source layout. Positive rows are checked against the engine decision. |
| `expected_replacement` | Exact target text for `correct`, or `-` for `preserve`. |
| `category` | Stable grouping label for later sliced reports. |

The runner reports a correction decision as the positive class. For each direction it calculates TP, FP, FN, TN, precision, recall, and F1. It also verifies the exact original, replacement, and direction on positive rows. Candidate strings are only emitted by XCTest when an assertion fails; no application telemetry or logging is added.

## SHA-256

Hashes cover the exact checked-in TSV bytes, including the final LF.

| File | SHA-256 |
|---|---|
| `tune.tsv` | `23863ab6c83b8a6362242b40017e0c002a0bb44d90818d1dfb54719bd0dd366e` |
| `holdout.tsv` | `241d2df99ad5daec87c4486e3896bb1b70d8d8784178d48dc5d687568fb4e47b` |
| `system-evidence.tsv` | `b546086992de8218409fbb9b4aab546ed801de74c035116c41e94ec0846ccef9` |
