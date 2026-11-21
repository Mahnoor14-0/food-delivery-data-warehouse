-- =====================================================================
-- 05_load_dim_static.sql  -  dim_date, dim_time_of_day and the small lookup dimensions
-- Surrogate key mapping: business code (NK) -> channel_key / payment_method_key / ... (IDENTITY)
-- Special members: -1 = Unknown. Re-runnable (ON CONFLICT ... DO UPDATE = Type 1).
-- =====================================================================
SET search_path = project_dw;

-- ---- dim_date : 2020-01-01 .. 2029-12-31 (3,653 days) + unknown member
INSERT INTO dim_date
SELECT to_char(d,'YYYYMMDD')::int, d::date, extract(isodow FROM d)::smallint, btrim(to_char(d,'Day')), extract(day FROM d)::smallint,
       extract(doy FROM d)::smallint, extract(week FROM d)::smallint, date_trunc('week', d)::date, extract(month FROM d)::smallint,
       btrim(to_char(d,'Month')), to_char(d,'YYYY-MM'), extract(quarter FROM d)::smallint, 'Q' || extract(quarter FROM d),
       extract(year FROM d)::smallint, extract(isodow FROM d) >= 6, h.holiday_date IS NOT NULL, h.holiday_name, {{BATCH_ID}}, now()
FROM generate_series(DATE '2020-01-01', DATE '2029-12-31', interval '1 day') AS d
LEFT JOIN project_staging.stg_holiday h ON h.holiday_date = d::date
ON CONFLICT (date_key) DO NOTHING;
INSERT INTO dim_date VALUES (-1, DATE '1900-01-01', 0, 'Unknown', 0, 0, 0, DATE '1900-01-01', 0, 'Unknown', 'Unknown', 0, 'NA', 1900, FALSE, FALSE, NULL, {{BATCH_ID}}, now())
ON CONFLICT (date_key) DO NOTHING;

-- ---- dim_time_of_day : 24 hours + unknown
INSERT INTO dim_time_of_day
SELECT h, lpad(h::text,2,'0') || ':00-' || lpad(h::text,2,'0') || ':59',
       CASE WHEN h % 12 = 0 THEN 12 ELSE h % 12 END || CASE WHEN h < 12 THEN ' AM' ELSE ' PM' END,
       CASE WHEN h BETWEEN 5 AND 10 THEN 'Breakfast' WHEN h BETWEEN 11 AND 14 THEN 'Lunch' WHEN h BETWEEN 15 AND 18 THEN 'Afternoon Snack'
            WHEN h BETWEEN 19 AND 22 THEN 'Dinner' ELSE 'Late Night' END,
       h BETWEEN 12 AND 14 OR h BETWEEN 19 AND 22, h >= 23 OR h <= 4, {{BATCH_ID}}, now()
FROM generate_series(0, 23) AS h
ON CONFLICT (hour_key) DO NOTHING;
INSERT INTO dim_time_of_day VALUES (-1, 'Unknown', 'N/A', 'Unknown', FALSE, FALSE, {{BATCH_ID}}, now()) ON CONFLICT (hour_key) DO NOTHING;

-- ---- unknown members first (key = -1) for every lookup dimension
INSERT INTO dim_order_channel (channel_key, channel_code, channel_name, platform_type, is_self_service, etl_batch_id)
OVERRIDING SYSTEM VALUE VALUES (-1, 'UNKNOWN', 'Unknown', 'Unknown', FALSE, {{BATCH_ID}}) ON CONFLICT DO NOTHING;
INSERT INTO dim_payment_method (payment_method_key, payment_method_code, payment_method_name, payment_type, is_prepaid, is_online_payment, etl_batch_id)
OVERRIDING SYSTEM VALUE VALUES (-1, 'UNKNOWN', 'Unknown', 'Unknown', FALSE, FALSE, {{BATCH_ID}}) ON CONFLICT DO NOTHING;
INSERT INTO dim_order_status (order_status_key, order_status_code, order_status_name, status_group, is_final_status, counts_as_revenue, etl_batch_id)
OVERRIDING SYSTEM VALUE VALUES (-1, 'UNKNOWN', 'Unknown', 'Unknown', FALSE, FALSE, {{BATCH_ID}}) ON CONFLICT DO NOTHING;
INSERT INTO dim_cancellation_reason (cancellation_reason_key, reason_code, reason_name, reason_category, cancelled_by, is_preventable, etl_batch_id)
OVERRIDING SYSTEM VALUE VALUES (-1, 'UNKNOWN', 'Unknown', 'Unknown', 'Unknown', FALSE, {{BATCH_ID}}) ON CONFLICT DO NOTHING;

-- ---- lookup dimensions from staged reference files (Type 1)
INSERT INTO dim_order_channel (channel_code, channel_name, platform_type, is_self_service, etl_batch_id)
SELECT channel_code, channel_name, platform_type, is_self_service, {{BATCH_ID}} FROM project_staging.stg_order_channel
ON CONFLICT (channel_code) DO UPDATE SET channel_name = EXCLUDED.channel_name, platform_type = EXCLUDED.platform_type,
       is_self_service = EXCLUDED.is_self_service, etl_batch_id = EXCLUDED.etl_batch_id, etl_load_ts = now();

INSERT INTO dim_payment_method (payment_method_code, payment_method_name, payment_type, is_prepaid, is_online_payment, etl_batch_id)
SELECT payment_method_code, payment_method_name, payment_type, is_prepaid, is_online_payment, {{BATCH_ID}} FROM project_staging.stg_payment_method
ON CONFLICT (payment_method_code) DO UPDATE SET payment_method_name = EXCLUDED.payment_method_name, payment_type = EXCLUDED.payment_type,
       is_prepaid = EXCLUDED.is_prepaid, is_online_payment = EXCLUDED.is_online_payment, etl_batch_id = EXCLUDED.etl_batch_id, etl_load_ts = now();

INSERT INTO dim_order_status (order_status_code, order_status_name, status_group, is_final_status, counts_as_revenue, etl_batch_id)
SELECT order_status_code, order_status_name, status_group, is_final_status, counts_as_revenue, {{BATCH_ID}} FROM project_staging.stg_order_status
ON CONFLICT (order_status_code) DO UPDATE SET order_status_name = EXCLUDED.order_status_name, status_group = EXCLUDED.status_group,
       is_final_status = EXCLUDED.is_final_status, counts_as_revenue = EXCLUDED.counts_as_revenue, etl_batch_id = EXCLUDED.etl_batch_id, etl_load_ts = now();

INSERT INTO dim_cancellation_reason (reason_code, reason_name, reason_category, cancelled_by, is_preventable, etl_batch_id)
SELECT reason_code, reason_name, reason_category, cancelled_by, is_preventable, {{BATCH_ID}} FROM project_staging.stg_cancellation_reason
ON CONFLICT (reason_code) DO UPDATE SET reason_name = EXCLUDED.reason_name, reason_category = EXCLUDED.reason_category,
       cancelled_by = EXCLUDED.cancelled_by, is_preventable = EXCLUDED.is_preventable, etl_batch_id = EXCLUDED.etl_batch_id, etl_load_ts = now();
