# Stuck mutation

Alert: `ClickHouseStuckMutation`.

## Kill a runaway query

`KILL QUERY WHERE query_id = '...'` (DBA role). If a class of queries repeats, tighten that role's profile in Git rather than killing by hand.

## Procedure

1. `SELECT * FROM system.mutations WHERE is_done = 0` and read `latest_fail_reason`.
2. Fix the cause (often a type error in the expression), then `KILL MUTATION WHERE mutation_id = '...'` and re-issue it corrected.
