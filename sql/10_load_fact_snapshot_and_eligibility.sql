-- =====================================================================
-- 10_load_fact_snapshot_and_eligibility.sql
--  (a) fact_restaurant_daily_snapshot  PERIODIC snapshot, grain = restaurant x day (zero-order days included)
--      availability / menu / complaint measures come from the RPP availability log; order counts, sales, prep time and
--      the running rating come from fact_delivery / fact_order_item (orders counted on their placed date).
--      avg_rating_to_date / review_count_to_date are end-of-day balances (semi-additive).
--  (b) fact_promotion_eligibility      FACTLESS coverage fact, grain = customer x promotion x issue date
-- =====================================================================
SET search_path = project_dw;

INSERT INTO fact_restaurant_daily_snapshot (snapshot_date_key, restaurant_key, scheduled_open_minutes, online_minutes, orders_received_count,
    orders_delivered_count, orders_cancelled_count, gross_sales_amount, avg_food_prep_minutes, active_menu_items_count, unavailable_menu_items_count,
    avg_rating_to_date, review_count_to_date, open_complaints_count, etl_batch_id)
WITH day_orders AS (
    SELECT dr.restaurant_id, dd.full_date AS d, count(*) AS received,
           count(*) FILTER (WHERE s.status_group = 'Completed') AS delivered,
           count(*) FILTER (WHERE s.status_group IN ('Cancelled', 'Failed')) AS cancelled,
           ROUND(avg(f.prep_lag_minutes), 2) AS avg_prep, count(f.customer_rating) AS rev_cnt, COALESCE(sum(f.customer_rating), 0) AS rating_sum
    FROM fact_delivery f
    JOIN dim_restaurant dr ON dr.restaurant_key = f.restaurant_key
    JOIN dim_date dd ON dd.date_key = f.order_placed_date_key
    JOIN dim_order_status s ON s.order_status_key = f.order_status_key
    GROUP BY dr.restaurant_id, dd.full_date
), day_sales AS (
    SELECT dr.restaurant_id, dd.full_date AS d, sum(i.net_item_amount) AS sales
    FROM fact_order_item i
    JOIN dim_restaurant dr ON dr.restaurant_key = i.restaurant_key
    JOIN dim_date dd ON dd.date_key = i.order_date_key
    JOIN dim_order_status s ON s.order_status_key = i.order_status_key AND s.status_group = 'Completed'
    GROUP BY dr.restaurant_id, dd.full_date
), spine AS (
    SELECT a.*, COALESCE(o.received, 0) AS received, COALESCE(o.delivered, 0) AS delivered, COALESCE(o.cancelled, 0) AS cancelled,
           o.avg_prep, COALESCE(o.rev_cnt, 0) AS rev_cnt, COALESCE(o.rating_sum, 0) AS rating_sum, COALESCE(sl.sales, 0) AS sales
    FROM project_staging.stg_availability_log a
    LEFT JOIN day_orders o ON o.restaurant_id = a.restaurant_id AND o.d = a.log_date
    LEFT JOIN day_sales sl ON sl.restaurant_id = a.restaurant_id AND sl.d = a.log_date
), running AS (
    SELECT s.*, SUM(rev_cnt) OVER w AS cum_cnt, SUM(rating_sum) OVER w AS cum_sum
    FROM spine s WINDOW w AS (PARTITION BY restaurant_id ORDER BY log_date)
)
SELECT dd.date_key, dr.restaurant_key, r.scheduled_open_minutes, r.online_minutes, r.received, r.delivered, r.cancelled, r.sales, r.avg_prep,
       r.active_menu_items, r.unavailable_menu_items, CASE WHEN r.cum_cnt > 0 THEN ROUND(r.cum_sum::numeric / r.cum_cnt, 2) END, r.cum_cnt::int,
       r.open_complaints, {{BATCH_ID}}
FROM running r
JOIN dim_date dd ON dd.full_date = r.log_date
JOIN dim_restaurant dr ON dr.restaurant_id = r.restaurant_id AND r.log_date BETWEEN dr.effective_start_date AND dr.effective_end_date
ON CONFLICT (snapshot_date_key, restaurant_key) DO UPDATE SET
    scheduled_open_minutes = EXCLUDED.scheduled_open_minutes, online_minutes = EXCLUDED.online_minutes, orders_received_count = EXCLUDED.orders_received_count,
    orders_delivered_count = EXCLUDED.orders_delivered_count, orders_cancelled_count = EXCLUDED.orders_cancelled_count, gross_sales_amount = EXCLUDED.gross_sales_amount,
    avg_food_prep_minutes = EXCLUDED.avg_food_prep_minutes, active_menu_items_count = EXCLUDED.active_menu_items_count,
    unavailable_menu_items_count = EXCLUDED.unavailable_menu_items_count, avg_rating_to_date = EXCLUDED.avg_rating_to_date,
    review_count_to_date = EXCLUDED.review_count_to_date, open_complaints_count = EXCLUDED.open_complaints_count, etl_batch_id = EXCLUDED.etl_batch_id, etl_load_ts = now();

INSERT INTO fact_promotion_eligibility (promotion_key, customer_key, issue_date_key, expiry_date_key, eligibility_count, etl_batch_id)
SELECT COALESCE(p.promotion_key, -1), COALESCE(c.customer_key, -1), di.date_key, de.date_key, 1, {{BATCH_ID}}
FROM project_staging.stg_promotion_target t
JOIN dim_date di ON di.full_date = t.issued_at
JOIN dim_date de ON de.full_date = t.expires_at
LEFT JOIN dim_promotion p ON p.promotion_id = t.promotion_id
LEFT JOIN dim_customer c ON c.customer_id = t.customer_id AND t.issued_at BETWEEN c.effective_start_date AND c.effective_end_date
ON CONFLICT (promotion_key, customer_key, issue_date_key) DO NOTHING;

ANALYZE fact_restaurant_daily_snapshot;
ANALYZE fact_promotion_eligibility;
