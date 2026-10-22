-- Deterministic sample data for the local cluster and CI integration tests.
-- Run as admin after `make db-init`. Inserts go through Distributed tables synchronously so
-- tests can assert immediately.
SET distributed_foreground_insert = 1;

-- 10,000 events across 100 customers, flowing raw -> analytics -> curated -> marts via MVs.
INSERT INTO raw.events (event_time, customer_id, event_type, event_id, amount, country, payload, _topic, _partition, _offset)
SELECT
  now64(3) - toIntervalSecond(number * 37)                         AS event_time,
  number % 100 + 1                                                 AS customer_id,
  ['view', 'click', 'purchase', 'refund'][number % 4 + 1]          AS event_type,
  generateUUIDv4(number)                                           AS event_id,
  toDecimal64(if(number % 4 = 2, (number % 500) / 10, 0), 4)       AS amount,
  ['US', 'DE', 'IN', 'GB', 'FR'][number % 5 + 1]                   AS country,
  concat('{"session":"', toString(number % 997), '"}')             AS payload,
  'events.v1', number % 6, number
FROM numbers(10000);

-- PII for the same customers (only the pii database holds natural identifiers).
INSERT INTO pii.customers (customer_id, email, phone, full_name, date_of_birth, country, ip_address)
SELECT
  number + 1,
  concat('user', toString(number + 1), '@example.com'),
  concat('+1-555-01', leftPad(toString(number + 1), 2, '0')),
  concat('Customer ', toString(number + 1)),
  toDate('1980-01-01') + number * 97,
  ['US', 'DE', 'IN', 'GB', 'FR'][number % 5 + 1],
  concat('10.0.0.', toString(number + 1))
FROM numbers(100);

-- dev_analyst may see customers 1-10 only.
INSERT INTO governance.user_tenants (user_name, customer_ids) VALUES ('dev_analyst', range(1, 11));
SYSTEM RELOAD DICTIONARY ON CLUSTER '{cluster}' governance.user_tenants_dict;
