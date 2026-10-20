# Restore test: finance/ledger

2026-10-20 16:51. Result: **PASS**.

| Step | Result |
|---|---|
| Test data written inside the VM | md5 0701e37875eaab21889d6a91c40429ac |
| Backup (RBD snapshot, export, gzip to the host) | 9 s, 39M, `ledger-ironcloud-20261020T135049Z.raw.gz` |
| Damage: test data overwritten with zeros | md5 b5cfa9d6c8febd618f91ac2843d50a1c |
| Restore (stop, swap image, start) until SSH answers | 49 s |
| Test data after restore | md5 0701e37875eaab21889d6a91c40429ac |

The backup is crash-consistent: the snapshot is taken while the VM runs, as if its power had been cut at that moment.
The replaced image was removed after the checksum matched.
