---
name: Access request
about: Request a ClickHouse role (granted through an AD group, not by hand)
labels: access
---

**Role requested** (e.g. role_bi_analyst, role_pii_reader)

**Business justification**

**Duration** (role_pii_reader is time-boxed, max 30 days)

**Approver** (data owner for the datasets involved)

Access is granted by adding you to AD group `CH-Prod-<role>`; ClickHouse maps the group automatically.
