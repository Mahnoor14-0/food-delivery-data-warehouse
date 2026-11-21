-- =====================================================================
-- 12_data_quality_checks.sql  -  DATA QUALITY VALIDATION
-- Results are written to project_dw.dq_result (PASS / FAIL / INFO) and read by etl/build_reports.py.
--   Completeness : no NULL foreign keys, share of Unknown (-1) members
--   Integrity    : fact rows without a matching dimension = 0, SCD2 consistency, special members
--   Uniqueness   : grain checks from the Phase 1 Grain Definition Document
--   Accuracy     : reconciliations (order vs line amounts, staging vs DW, snapshot vs delivery, net sales vs source)
--   Business rules: BR-02 ... BR-09 and lifecycle consistency
-- =====================================================================
SET search_path = project_dw;
TRUNCATE dq_result RESTART IDENTITY;

CREATE OR REPLACE FUNCTION dq_add(p_cat TEXT, p_name TEXT, p_tbl TEXT, p_checked BIGINT, p_failed BIGINT, p_tol NUMERIC DEFAULT 0) RETURNS VOID AS $$
    INSERT INTO project_dw.dq_result (category, check_name, table_name, rows_checked, rows_failed, tolerance) VALUES (p_cat, p_name, p_tbl, p_checked, p_failed, p_tol);
$$ LANGUAGE sql;

-- ------------------------------------------------------------- 1. COMPLETENESS
DO $$
DECLARE r RECORD; total BIGINT; nulls BIGINT; unk BIGINT;
BEGIN
    FOR r IN SELECT table_name, column_name FROM information_schema.columns
             WHERE table_schema = 'project_dw' AND table_name LIKE 'fact\_%' AND column_name LIKE '%\_key'
             ORDER BY table_name, ordinal_position LOOP
        EXECUTE format('SELECT count(*), count(*) FILTER (WHERE %I IS NULL), count(*) FILTER (WHERE %I = -1) FROM project_dw.%I', r.column_name, r.column_name, r.table_name)
          INTO total, nulls, unk;
        PERFORM dq_add('Completeness', 'No NULL foreign key: ' || r.column_name, r.table_name, total, nulls, 0);
        IF unk > 0 THEN
            PERFORM dq_add('Completeness (info)', 'Rows mapped to Unknown member (-1): ' || r.column_name, r.table_name, total, unk, NULL);
        END IF;
    END LOOP;
END $$;

SELECT dq_add('Completeness', 'Mandatory attributes present (customer, restaurant, courier, location)', 'dimensions',
    (SELECT count(*) FROM dim_customer) + (SELECT count(*) FROM dim_restaurant) + (SELECT count(*) FROM dim_courier) + (SELECT count(*) FROM dim_location),
    (SELECT count(*) FROM dim_customer WHERE customer_name IS NULL OR customer_segment IS NULL)
  + (SELECT count(*) FROM dim_restaurant WHERE restaurant_name IS NULL OR commission_rate_pct IS NULL)
  + (SELECT count(*) FROM dim_courier WHERE vehicle_type IS NULL) + (SELECT count(*) FROM dim_location WHERE city IS NULL), 0);
SELECT dq_add('Completeness (info)', 'Delivered orders without customer rating (rating is optional)', 'fact_delivery',
    (SELECT count(*) FROM fact_delivery WHERE cancelled_flag = 0), (SELECT count(*) FROM fact_delivery WHERE cancelled_flag = 0 AND customer_rating IS NULL), NULL);

-- ------------------------------------------------------------- 2. INTEGRITY (fact -> dimension)
DO $$
DECLARE r RECORD; total BIGINT; orphan BIGINT;
BEGIN
    FOR r IN SELECT c.conrelid::regclass::text AS fact, a.attname AS fk, c.confrelid::regclass::text AS dim, af.attname AS pk
             FROM pg_constraint c
             JOIN pg_attribute a  ON a.attrelid = c.conrelid  AND a.attnum = c.conkey[1]
             JOIN pg_attribute af ON af.attrelid = c.confrelid AND af.attnum = c.confkey[1]
             WHERE c.contype = 'f' AND c.connamespace = 'project_dw'::regnamespace AND c.conrelid::regclass::text LIKE '%fact\_%'
             ORDER BY 1, 2 LOOP
        EXECUTE format('SELECT count(*), count(*) FILTER (WHERE d.%I IS NULL) FROM %s f LEFT JOIN %s d ON d.%I = f.%I', r.pk, r.fact, r.dim, r.pk, r.fk)
          INTO total, orphan;
        PERFORM dq_add('Integrity', 'Fact rows without matching dimension: ' || r.fk || ' -> ' || r.dim, r.fact, total, orphan, 0);
    END LOOP;
END $$;

SELECT dq_add('Integrity', 'Exactly one current version per customer', 'dim_customer', (SELECT count(DISTINCT customer_id) FROM dim_customer),
    (SELECT count(*) FROM (SELECT customer_id FROM dim_customer GROUP BY 1 HAVING count(*) FILTER (WHERE is_current) <> 1) x), 0);
SELECT dq_add('Integrity', 'Exactly one current version per restaurant', 'dim_restaurant', (SELECT count(DISTINCT restaurant_id) FROM dim_restaurant),
    (SELECT count(*) FROM (SELECT restaurant_id FROM dim_restaurant GROUP BY 1 HAVING count(*) FILTER (WHERE is_current) <> 1) x), 0);
SELECT dq_add('Integrity', 'SCD2 versions of a customer do not overlap', 'dim_customer', (SELECT count(*) FROM dim_customer),
    (SELECT count(*) FROM dim_customer a JOIN dim_customer b ON a.customer_id = b.customer_id AND a.version_number < b.version_number
      AND a.effective_end_date >= b.effective_start_date), 0);
SELECT dq_add('Integrity', 'SCD2 versions of a restaurant do not overlap', 'dim_restaurant', (SELECT count(*) FROM dim_restaurant),
    (SELECT count(*) FROM dim_restaurant a JOIN dim_restaurant b ON a.restaurant_id = b.restaurant_id AND a.version_number < b.version_number
      AND a.effective_end_date >= b.effective_start_date), 0);
SELECT dq_add('Integrity', 'Special members present (-1 in all key dimensions, 0 = No promotion)', 'dimensions', 12,
    12 - ((SELECT count(*) FROM dim_customer WHERE customer_key = -1) + (SELECT count(*) FROM dim_restaurant WHERE restaurant_key = -1)
        + (SELECT count(*) FROM dim_menu_item WHERE menu_item_key = -1) + (SELECT count(*) FROM dim_courier WHERE courier_key = -1)
        + (SELECT count(*) FROM dim_location WHERE location_key = -1) + (SELECT count(*) FROM dim_order_channel WHERE channel_key = -1)
        + (SELECT count(*) FROM dim_payment_method WHERE payment_method_key = -1) + (SELECT count(*) FROM dim_order_status WHERE order_status_key = -1)
        + (SELECT count(*) FROM dim_cancellation_reason WHERE cancellation_reason_key = -1) + (SELECT count(*) FROM dim_promotion WHERE promotion_key = -1)
        + (SELECT count(*) FROM dim_promotion WHERE promotion_key = 0) + (SELECT count(*) FROM dim_date WHERE date_key = -1)), 0);
SELECT dq_add('Integrity', 'Natural keys unique in Type 1 dimensions', 'dimensions',
    (SELECT count(*) FROM dim_courier) + (SELECT count(*) FROM dim_menu_item) + (SELECT count(*) FROM dim_location) + (SELECT count(*) FROM dim_promotion),
    (SELECT count(*) - count(DISTINCT courier_id) FROM dim_courier) + (SELECT count(*) - count(DISTINCT menu_item_id) FROM dim_menu_item)
  + (SELECT count(*) - count(DISTINCT zone_id) FROM dim_location) + (SELECT count(*) - count(DISTINCT promotion_id) FROM dim_promotion), 0);

-- ------------------------------------------------------------- 3. GRAIN (uniqueness, Phase 1 section 3)
SELECT dq_add('Grain', 'fact_order_item: one row per (order_id, order_line_number)', 'fact_order_item', (SELECT count(*) FROM fact_order_item),
    (SELECT count(*) FROM (SELECT 1 FROM fact_order_item GROUP BY order_id, order_line_number HAVING count(*) > 1) x), 0);
SELECT dq_add('Grain', 'fact_delivery: one row per order_id', 'fact_delivery', (SELECT count(*) FROM fact_delivery),
    (SELECT count(*) FROM (SELECT 1 FROM fact_delivery GROUP BY order_id HAVING count(*) > 1) x), 0);
SELECT dq_add('Grain', 'fact_restaurant_daily_snapshot: one row per (date, restaurant)', 'fact_restaurant_daily_snapshot', (SELECT count(*) FROM fact_restaurant_daily_snapshot),
    (SELECT count(*) FROM (SELECT 1 FROM fact_restaurant_daily_snapshot GROUP BY snapshot_date_key, restaurant_key HAVING count(*) > 1) x), 0);
SELECT dq_add('Grain', 'fact_promotion_eligibility: one row per (promotion, customer, issue date)', 'fact_promotion_eligibility', (SELECT count(*) FROM fact_promotion_eligibility),
    (SELECT count(*) FROM (SELECT 1 FROM fact_promotion_eligibility GROUP BY promotion_key, customer_key, issue_date_key HAVING count(*) > 1) x), 0);
SELECT dq_add('Grain', 'Snapshot: one row per restaurant-day for every logged day (zero-order days present)', 'fact_restaurant_daily_snapshot',
    (SELECT count(*) FROM project_staging.stg_availability_log), (SELECT count(*) FROM project_staging.stg_availability_log) - (SELECT count(*) FROM fact_restaurant_daily_snapshot), 0);

-- ------------------------------------------------------------- 4. ACCURACY / RECONCILIATION
SELECT dq_add('Accuracy', 'Row count: staged orders = fact_delivery rows', 'fact_delivery', (SELECT count(*) FROM project_staging.stg_order),
    abs((SELECT count(*) FROM project_staging.stg_order) - (SELECT count(*) FROM fact_delivery)), 0);
SELECT dq_add('Accuracy', 'Row count: staged order lines = fact_order_item rows', 'fact_order_item', (SELECT count(*) FROM project_staging.stg_order_line),
    abs((SELECT count(*) FROM project_staging.stg_order_line) - (SELECT count(*) FROM fact_order_item)), 0);
SELECT dq_add('Accuracy', 'Revenue reconciliation: SUM(order_subtotal) in fact_delivery = SUM(gross_item_amount) in fact_order_item (orders that differ)', 'fact_delivery',
    (SELECT count(*) FROM fact_delivery),
    (SELECT count(*) FROM fact_delivery d JOIN (SELECT order_id, SUM(gross_item_amount) g FROM fact_order_item GROUP BY order_id) i USING (order_id)
      WHERE d.order_subtotal_amount <> i.g), 0);
SELECT dq_add('Accuracy', 'BR-05: allocated line discounts sum to the order discount (orders that differ)', 'fact_order_item', (SELECT count(*) FROM fact_delivery),
    (SELECT count(*) FROM fact_delivery d JOIN (SELECT order_id, SUM(item_discount_amount) x FROM fact_order_item GROUP BY order_id) i USING (order_id)
      WHERE d.order_discount_amount <> i.x), 0);
SELECT dq_add('Accuracy', 'items_count in fact_delivery = SUM(quantity) of the order lines (orders that differ)', 'fact_delivery', (SELECT count(*) FROM fact_delivery),
    (SELECT count(*) FROM fact_delivery d JOIN (SELECT order_id, SUM(quantity) q FROM fact_order_item GROUP BY order_id) i USING (order_id) WHERE d.items_count <> i.q), 0);
SELECT dq_add('Accuracy', 'order_total = subtotal - discount + fee + tip (orders that differ)', 'fact_delivery', (SELECT count(*) FROM fact_delivery),
    (SELECT count(*) FROM fact_delivery WHERE order_total_amount <> order_subtotal_amount - order_discount_amount + delivery_fee_amount + tip_amount), 0);
SELECT dq_add('Accuracy', 'Net sales: DW vs independent calculation from staging (0.1% tolerance, BRD non-functional requirement)', 'fact_order_item',
    1, (abs(dw.v - src.v) > 0.001 * src.v)::int, 0)
FROM (SELECT SUM(i.net_item_amount) v FROM fact_order_item i JOIN dim_order_status s USING (order_status_key) WHERE s.status_group = 'Completed') dw,
     (SELECT SUM(o.order_subtotal - o.order_discount) v FROM project_staging.stg_order o JOIN project_staging.stg_order_status s USING (order_status_code) WHERE s.status_group = 'Completed') src;
SELECT dq_add('Accuracy', 'Snapshot reconciliation: SUM(orders_received_count) = orders in fact_delivery', 'fact_restaurant_daily_snapshot',
    (SELECT count(*) FROM fact_delivery), abs((SELECT SUM(orders_received_count) FROM fact_restaurant_daily_snapshot) - (SELECT count(*) FROM fact_delivery)), 0);
SELECT dq_add('Accuracy', 'Public data fidelity: transit_lag_minutes = Time_taken (min) of the public file (orders that differ)', 'fact_delivery',
    (SELECT count(*) FROM fact_delivery f JOIN project_staging.stg_zomato_delivery z USING (order_id)),
    (SELECT count(*) FROM fact_delivery f JOIN project_staging.stg_zomato_delivery z USING (order_id) WHERE f.transit_lag_minutes <> z.transit_minutes), 0);
SELECT dq_add('Accuracy', 'Public data fidelity: pick-up timestamp and courier identical to the public file (orders that differ)', 'fact_delivery',
    (SELECT count(*) FROM fact_delivery f JOIN project_staging.stg_zomato_delivery z USING (order_id)),
    (SELECT count(*) FROM fact_delivery f JOIN project_staging.stg_zomato_delivery z USING (order_id) JOIN dim_courier c ON c.courier_key = f.courier_key
      WHERE f.courier_picked_up_ts <> z.picked_up_ts OR c.courier_id <> z.courier_id), 0);
SELECT dq_add('Accuracy', 'Commission = net_item_amount x commission rate valid on the order date (BR-03) (lines that differ)', 'fact_order_item', (SELECT count(*) FROM fact_order_item),
    (SELECT count(*) FROM fact_order_item i JOIN dim_restaurant r ON r.restaurant_key = i.restaurant_key
      WHERE i.platform_commission_amount <> ROUND(i.net_item_amount * r.commission_rate_pct / 100, 2)), 0);

-- ------------------------------------------------------------- 5. BUSINESS RULES / CONSISTENCY
SELECT dq_add('Business rules', 'Milestones in order: placed <= accepted <= ready <= picked up <= closed (violations)', 'fact_delivery', (SELECT count(*) FROM fact_delivery),
    (SELECT count(*) FROM fact_delivery WHERE restaurant_accepted_ts < order_placed_ts OR food_ready_ts < restaurant_accepted_ts
        OR courier_picked_up_ts < food_ready_ts OR order_closed_ts < courier_picked_up_ts OR order_closed_ts < order_placed_ts), 0);
SELECT dq_add('Business rules', 'Date and hour keys agree with the timestamps (violations)', 'fact_delivery', (SELECT count(*) FROM fact_delivery),
    (SELECT count(*) FROM fact_delivery WHERE order_placed_date_key <> to_char(order_placed_ts, 'YYYYMMDD')::int
        OR order_placed_hour_key <> extract(hour FROM order_placed_ts)
        OR (order_closed_ts IS NULL AND (order_closed_date_key <> -1 OR order_closed_hour_key <> -1))), 0);
SELECT dq_add('Business rules', 'BR-04: on-time flag only for delivered orders and = (total <= promised) (violations)', 'fact_delivery', (SELECT count(*) FROM fact_delivery),
    (SELECT count(*) FROM fact_delivery f JOIN dim_order_status s USING (order_status_key)
      WHERE (s.status_group <> 'Completed' AND f.delivered_on_time_flag IS NOT NULL)
         OR (s.status_group = 'Completed' AND f.delivered_on_time_flag IS DISTINCT FROM (f.total_delivery_minutes <= f.promised_delivery_minutes)::int)), 0);
SELECT dq_add('Business rules', 'cancelled_flag = 1 exactly for Cancelled / Failed statuses (violations)', 'fact_delivery', (SELECT count(*) FROM fact_delivery),
    (SELECT count(*) FROM fact_delivery f JOIN dim_order_status s USING (order_status_key) WHERE f.cancelled_flag <> (s.status_group IN ('Cancelled', 'Failed'))::int), 0);
SELECT dq_add('Business rules', 'BR-07: courier_key = -1 only when the order never reached pick-up (violations)', 'fact_delivery', (SELECT count(*) FROM fact_delivery),
    (SELECT count(*) FROM fact_delivery WHERE (courier_key = -1 AND courier_picked_up_ts IS NOT NULL) OR (courier_key <> -1 AND courier_picked_up_ts IS NULL)), 0);
SELECT dq_add('Business rules', 'Lifecycle: acceptance + prep + pick-up wait + transit = total delivery minutes (+/- 0.05) for delivered orders', 'fact_delivery',
    (SELECT count(*) FROM fact_delivery WHERE total_delivery_minutes IS NOT NULL),
    (SELECT count(*) FROM fact_delivery WHERE total_delivery_minutes IS NOT NULL
      AND abs(acceptance_lag_minutes + prep_lag_minutes + pickup_wait_lag_minutes + transit_lag_minutes - total_delivery_minutes) > 0.05), 0);
SELECT dq_add('Business rules', 'Cancelled / failed orders are stored (lost revenue measurable) and have no revenue status (BR-02)', 'fact_order_item', (SELECT count(*) FROM fact_order_item),
    (SELECT CASE WHEN count(*) = 0 THEN 1 ELSE 0 END FROM fact_order_item i JOIN dim_order_status s USING (order_status_key) WHERE s.status_group IN ('Cancelled', 'Failed')), 0);
SELECT dq_add('Business rules', 'Value ranges: ratings 1-5, amounts >= 0, quantity >= 1, promised minutes > 0 (violations)', 'fact tables',
    (SELECT count(*) FROM fact_delivery) + (SELECT count(*) FROM fact_order_item),
    (SELECT count(*) FROM fact_delivery WHERE customer_rating NOT BETWEEN 1 AND 5 OR order_subtotal_amount < 0 OR tip_amount < 0 OR refund_amount < 0 OR promised_delivery_minutes <= 0)
  + (SELECT count(*) FROM fact_order_item WHERE quantity < 1 OR gross_item_amount < 0 OR net_item_amount < 0 OR item_discount_amount < 0), 0);
SELECT dq_add('Business rules', 'Snapshot: online_minutes <= scheduled_open_minutes and unavailable <= active items (violations)', 'fact_restaurant_daily_snapshot',
    (SELECT count(*) FROM fact_restaurant_daily_snapshot),
    (SELECT count(*) FROM fact_restaurant_daily_snapshot WHERE online_minutes > scheduled_open_minutes OR unavailable_menu_items_count > active_menu_items_count), 0);
SELECT dq_add('Business rules', 'Promotion redemption only inside [issue, expiry] and only by targeted customers (violating orders)', 'fact_order_item',
    (SELECT count(DISTINCT order_id) FROM fact_order_item WHERE promotion_key > 0),
    (SELECT count(*) FROM (SELECT DISTINCT i.order_id, i.promotion_key, c.customer_id, dd.full_date FROM fact_order_item i
        JOIN dim_customer c ON c.customer_key = i.customer_key JOIN dim_date dd ON dd.date_key = i.order_date_key WHERE i.promotion_key > 0) o
      WHERE NOT EXISTS (SELECT 1 FROM fact_promotion_eligibility e JOIN dim_customer ec ON ec.customer_key = e.customer_key
                         JOIN dim_date di ON di.date_key = e.issue_date_key JOIN dim_date dx ON dx.date_key = e.expiry_date_key
                         WHERE e.promotion_key = o.promotion_key AND ec.customer_id = o.customer_id AND o.full_date BETWEEN di.full_date AND dx.full_date)), 0);
SELECT dq_add('Business rules', 'SCD2: customer / restaurant version used by a fact row was valid on the order date (violations)', 'fact_order_item', (SELECT count(*) FROM fact_order_item),
    (SELECT count(*) FROM fact_order_item i JOIN dim_date d ON d.date_key = i.order_date_key JOIN dim_customer c ON c.customer_key = i.customer_key
      WHERE i.customer_key > 0 AND d.full_date NOT BETWEEN c.effective_start_date AND c.effective_end_date)
  + (SELECT count(*) FROM fact_order_item i JOIN dim_date d ON d.date_key = i.order_date_key JOIN dim_restaurant r ON r.restaurant_key = i.restaurant_key
      WHERE i.restaurant_key > 0 AND d.full_date NOT BETWEEN r.effective_start_date AND r.effective_end_date), 0);
SELECT dq_add('Business rules (info)', 'SCD2: customers with more than one version', 'dim_customer', (SELECT count(DISTINCT customer_id) FROM dim_customer),
    (SELECT count(*) FROM (SELECT customer_id FROM dim_customer GROUP BY 1 HAVING count(*) > 1) x), NULL);
SELECT dq_add('Business rules (info)', 'SCD2: restaurants with more than one version (tier / commission change)', 'dim_restaurant', (SELECT count(DISTINCT restaurant_id) FROM dim_restaurant),
    (SELECT count(*) FROM (SELECT restaurant_id FROM dim_restaurant GROUP BY 1 HAVING count(*) > 1) x), NULL);

-- ------------------------------------------------------------- table row counts (info, used by the report)
SELECT dq_add('Row count (info)', t.tbl, t.tbl, t.n, t.n, NULL) FROM (
    SELECT 'dim_date' tbl, count(*) n FROM dim_date UNION ALL SELECT 'dim_time_of_day', count(*) FROM dim_time_of_day
    UNION ALL SELECT 'dim_customer', count(*) FROM dim_customer UNION ALL SELECT 'dim_restaurant', count(*) FROM dim_restaurant
    UNION ALL SELECT 'dim_menu_item', count(*) FROM dim_menu_item UNION ALL SELECT 'dim_courier', count(*) FROM dim_courier
    UNION ALL SELECT 'dim_location', count(*) FROM dim_location UNION ALL SELECT 'dim_order_channel', count(*) FROM dim_order_channel
    UNION ALL SELECT 'dim_payment_method', count(*) FROM dim_payment_method UNION ALL SELECT 'dim_order_status', count(*) FROM dim_order_status
    UNION ALL SELECT 'dim_cancellation_reason', count(*) FROM dim_cancellation_reason UNION ALL SELECT 'dim_promotion', count(*) FROM dim_promotion
    UNION ALL SELECT 'fact_order_item', count(*) FROM fact_order_item UNION ALL SELECT 'fact_delivery', count(*) FROM fact_delivery
    UNION ALL SELECT 'fact_restaurant_daily_snapshot', count(*) FROM fact_restaurant_daily_snapshot
    UNION ALL SELECT 'fact_promotion_eligibility', count(*) FROM fact_promotion_eligibility) t;

SELECT category, status, count(*) FROM dq_result GROUP BY 1, 2 ORDER BY 1, 2;