# Rolling upgrade (minor or LTS patch)

Automation: `ansible/playbooks/rolling_upgrade.yml` (`-e target=replica_r2`, then `replica_r1` after 24 h, then `keeper`).
Bump `ch_version` in `ansible/inventories/<env>/group_vars/all.yml` in a PR; staging soaks 7 days first.

## Procedure

1. Confirm release notes for backward-incompatible changes and test in staging for 7 days.
2. For each shard, on replica `r2` first: drain from chproxy, run `SYSTEM STOP MERGES`, wait for running queries to finish (max 10 min), upgrade the package, restart.
3. Verify `SELECT version()`, `system.replicas` (`is_readonly = 0`, `absolute_delay < 60`), then return the replica to chproxy.
4. Repeat for `r1` after the whole cluster's `r2` replicas have run for 24 hours. Upgrade Keeper last, followers first, leader last.
