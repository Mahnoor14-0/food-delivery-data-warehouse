-- =====================================================================
-- 08_load_fact_order_item.sql  -  TRANSACTION fact, grain = one order line
-- Business key -> surrogate key mapping:
--   customer_id   -> customer_key   (SCD2: version valid on the order date)
--   restaurant_id -> restaurant_key (SCD2: version valid on the order date, also gives the commission rate, BR-03)
--   menu_item_id, zone_id, channel/payment/status codes, promotion_id -> current surrogate keys
--   anything that cannot be matched maps to the Unknown member (-1); "no promotion" maps to 0
-- BR-05: the order-level discount is allocated to lines in proportion to gross_item_amount;
--        the last line takes the rounding remainder so allocated amounts always sum to the order discount.
-- Re-runnable: ON CONFLICT updates only the status key (amounts never change after loading).
-- =====================================================================
SET search_path = project_dw;

INSERT INTO fact_order_item (order_id, order_line_number, order_date_key, order_hour_key, customer_key, restaurant_key, menu_item_key,
                             delivery_location_key, channel_key, payment_method_key, order_status_key, promotion_key, quantity, unit_price,
                             gross_item_amount, item_discount_amount, net_item_amount, platform_commission_amount, etl_batch_id)
WITH ord AS (
    SELECT * FROM project_staging.stg_order WHERE batch_id = {{BATCH_ID}}
), lines AS (
    SELECT l.order_id, l.line_no, l.menu_item_id, l.qty, l.unit_price, l.qty * l.unit_price AS gross,
           SUM(l.qty * l.unit_price) OVER (PARTITION BY l.order_id) AS tot_gross,
           ROW_NUMBER() OVER (PARTITION BY l.order_id ORDER BY l.line_no DESC) AS rn_last
    FROM project_staging.stg_order_line l WHERE l.order_id IN (SELECT order_id FROM ord)
), alloc AS (
    SELECT ln.*, o.order_discount,
           CASE WHEN ln.rn_last = 1
                THEN o.order_discount - COALESCE(SUM(ROUND(o.order_discount * ln.gross / NULLIF(ln.tot_gross, 0), 2))
                         OVER (PARTITION BY ln.order_id ORDER BY ln.line_no ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
                ELSE ROUND(o.order_discount * ln.gross / NULLIF(ln.tot_gross, 0), 2) END AS disc
    FROM lines ln JOIN ord o USING (order_id)
)
SELECT a.order_id, a.line_no, dd.date_key, extract(hour FROM o.placed_at)::smallint,
       COALESCE(dc.customer_key, -1), COALESCE(dr.restaurant_key, -1), COALESCE(mi.menu_item_key, -1), COALESCE(dl.location_key, -1),
       COALESCE(ch.channel_key, -1), COALESCE(pm.payment_method_key, -1), COALESCE(st.order_status_key, -1),
       CASE WHEN o.promotion_id IS NULL THEN 0 ELSE COALESCE(pr.promotion_key, -1) END,
       a.qty, a.unit_price, a.gross, COALESCE(a.disc, 0), a.gross - COALESCE(a.disc, 0),
       ROUND((a.gross - COALESCE(a.disc, 0)) * COALESCE(dr.commission_rate_pct, 0) / 100, 2), {{BATCH_ID}}
FROM alloc a
JOIN ord o ON o.order_id = a.order_id
JOIN dim_date dd ON dd.full_date = o.placed_at::date
LEFT JOIN dim_customer   dc ON dc.customer_id = o.customer_id   AND o.placed_at::date BETWEEN dc.effective_start_date AND dc.effective_end_date
LEFT JOIN dim_restaurant dr ON dr.restaurant_id = o.restaurant_id AND o.placed_at::date BETWEEN dr.effective_start_date AND dr.effective_end_date
LEFT JOIN dim_menu_item  mi ON mi.menu_item_id = a.menu_item_id
LEFT JOIN dim_location   dl ON dl.zone_id = o.dropoff_zone_id
LEFT JOIN dim_order_channel ch ON ch.channel_code = o.channel_code
LEFT JOIN dim_payment_method pm ON pm.payment_method_code = o.payment_method_code
LEFT JOIN dim_order_status st ON st.order_status_code = o.order_status_code
LEFT JOIN dim_promotion pr ON pr.promotion_id = o.promotion_id
ON CONFLICT (order_id, order_line_number) DO UPDATE
    SET order_status_key = EXCLUDED.order_status_key, etl_batch_id = EXCLUDED.etl_batch_id, etl_load_ts = now();

ANALYZE fact_order_item;
