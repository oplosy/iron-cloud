# Cost Plan

Estimated as of 2026-10-19. Prices are ranges from public listings and must be re-checked before buying.

**Assumptions:** 1 USD ≈ 49.2 TRY, 1 EUR ≈ 57 TRY, electricity ≈ 4.5 TRY/kWh (taxes included). All software (OpenStack/Kolla-Ansible, Ceph, OpenTofu, Ansible, Prometheus, FreeIPA) is open source: **0 TRY**.

## Requirements

The demo needs 3 nodes: Ceph monitor quorum, Galera quorum and an HA control plane all need 3. Each node runs the control plane, compute and storage together (hyperconverged).

| Per node | Minimum | Why |
|---|---|---|
| CPU | 6 cores with VT-x | Control services + Ceph OSD + a few tenant VMs |
| RAM | 32 GB | ~12 GB OpenStack services, ~6 GB Ceph (OSD + mon/mgr), ~12 GB tenant VMs |
| Boot disk | 256 GB SSD | OS + Kolla container images + logs |
| OSD disk | 1 TB SSD, separate | Ceph needs a raw dedicated disk |
| Network | 1 GbE | Management, storage and tenant traffic separated by VLANs |

Shared: one managed switch with 802.1Q VLAN support.

## Options

### A. This laptop only (nested virtualization)

Current machine: i7-11800H (8C/16T), 32 GB RAM (2 slots, max 64 GB), 512 GB SSD with 152 GB free.

| Item | TRY |
|---|---|
| Phase 0: single all-in-one VM (fits in 32 GB) | 0 |
| 2×32 GB DDR4-3200 SODIMM (used–new) | 10,000 – 23,000 |
| 1 TB NVMe for VM disks (if a second M.2 slot exists; verify) | 3,000 – 5,000 |
| **Total for 3-node nested** | **13,000 – 28,000** |

Limits: 3×18 GB VMs leave ~10 GB for Windows; tenant VMs run nested twice and are slow; "power off a node" is a VM power-off, not a real hardware failure.

### B. 3 used mini PCs (recommended)

Models: Lenovo ThinkCentre M720q/M920q, HP EliteDesk 800 G4, Dell OptiPlex 7060 Micro (i5-8500T, 6 cores).

| Item | Qty | Unit TRY | Total TRY |
|---|---|---|---|
| Used mini PC, i5-8500T / 8 GB / 256 GB | 3 | 10,000 – 14,000 | 30,000 – 42,000 |
| 2×16 GB DDR4-3200 SODIMM (used–new) | 3 | 5,500 – 12,000 | 16,500 – 36,000 |
| 1 TB SSD for Ceph OSD | 3 | 3,000 – 5,000 | 9,000 – 15,000 |
| 8-port managed 1 GbE switch (VLAN) | 1 | 1,500 – 2,500 | 1,500 – 2,500 |
| Patch cables | 4 | ~100 | 400 |
| **One-time total** | | | **~57,000 – 96,000** (typical ~70,000) |

Running cost: ~80 W average for 3 nodes + switch ≈ 58 kWh/month ≈ **~260 TRY/month** while running 24/7; less if powered off between sessions.

Why recommended: the demo's core claim is surviving a real physical node failure, which only real hardware proves. The hardware keeps resale value and has no monthly bill.

### C. Rented dedicated servers

| Setup | Monthly | 6 months |
|---|---|---|
| 1 Hetzner auction server, 64 GB+, nested (€45–65) | 2,600 – 3,700 | 15,600 – 22,200 |
| 3× Hetzner AX42-1 (€97.30 each + €49 setup each) | ~16,600 | ~108,000 |

The single server has option A's limits at A's price over 6 months, and nothing is left at the end. Three dedicated servers cost more than B within ~4 months. Not recommended.

## Spending schedule

| Phase | Work | Spend |
|---|---|---|
| 0 | Kolla all-in-one on this laptop; write the Ansible/OpenTofu code | 0 |
| 1a | Buy **one** mini PC; check VT-x, NIC driver, M.2/SATA slots, RAM fit | ~23,000 |
| 1b | Buy the remaining 2 nodes + switch; 3-node HA OpenStack + Ceph | ~48,000 |
| 2–3 | Self-service flow, isolation tests, failure demo | ~260/month electricity |

Buying one node first means a wrong model costs one machine, not three.

## Sources

- [Hetzner price adjustment, 15 June 2026](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)
- [Hetzner auction listing (Serverhunter)](https://www.serverhunter.com/offer/hetzner-server-auction-2405915)
- [Avantaj Bilişim used mini PCs](https://www.avantajbilisim.com/2.el-mini-pc)
- [DDR4 SODIMM 32 GB price history (Pangoly)](https://pangoly.com/en/price-history/crucial-32gb-single-ddr4-3200-sodimm)
- [eBay used M920q listings](https://www.ebay.com/shop/lenovo-thinkcentre-m920q-tiny?_nkw=lenovo+thinkcentre+m920q+tiny)
- [USD/TRY, 7 Oct 2026 (Türkgün)](https://www.turkgun.com/ekonomi/dolar-bugun-ne-kadar-7-ekim-2026-dolar-euro-kuru-kac-tl/405055)
- [Residential electricity tariffs 2026 (Verinokta)](https://verinokta.com/fiyatlar/elektrik-tarifeleri/)

SSD and switch prices were not verified against a 2026 listing.
