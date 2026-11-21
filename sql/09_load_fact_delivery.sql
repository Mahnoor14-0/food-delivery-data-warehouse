-- =====================================================================
-- 09_load_fact_delivery.sql  -  ACCUMULATING SNAPSHOT, grain = one order
-- * one row per order_id; the row is INSERTED when the order first arrives and UPDATED (ON CONFLICT)
--   when later milestones / the final status arrive. Milestones not reached: date key = -1, timestamp NULL.
-- * lag measures are derived from the milestone timestamps (minutes, 2 decimals); NULL when a milestone is missing
-- * BR-04: on-time flag = total_delivery_minutes <= promised_delivery_minutes, NULL for undelivered orders
-- * BR-07: courier_key = -1 when the order never reached a courier; Unknown member (-1) for unmatched keys
-- =====================================================================
SET search_path = project_dw;

INSERT INTO fact_delivery (order_id, customer_key, restaurant_key, courier_key, pickup_location_key, dropoff_location_key, channel_key, payment_method_key,
    order_status_key, cancellation_reason_key, promotion_key, order_placed_date_key, restaurant_accepted_date_key, food_ready_date_key,
    courier_picked_up_date_key, order_closed_date_key, order_placed_hour_key, order_closed_hour_key,
    order_placed_ts, restaurant_accepted_ts, food_ready_ts, courier_picked_up_ts, order_closed_ts,
    items_count, order_subtotal_amount, order_discount_amount, delivery_fee_amount, tip_amount, refund_amount, order_total_amount, delivery_distance_km,
    promised_delivery_minutes, acceptance_lag_minutes, prep_lag_minutes, pickup_wait_lag_minutes, transit_lag_minutes, total_delivery_minutes,
    delay_minutes, delivered_on_time_flag, cancelled_flag, customer_rating, etl_batch_id)
SELECT o.order_id, COALESCE(dc.customer_key, -1), COALESCE(dr.restaurant_key, -1), COALESCE(dk.courier_key, -1),
       COALESCE(lp.location_key, -1), COALESCE(ld.location_key, -1), COALESCE(ch.channel_key, -1), COALESCE(pm.payment_method_key, -1),
       COALESCE(st.order_status_key, -1), COALESCE(cr.cancellation_reason_key, -1), CASE WHEN o.promotion_id IS NULL THEN 0 ELSE COALESCE(pr.promotion_key, -1) END,
       to_char(o.placed_at, 'YYYYMMDD')::int,
       COALESCE(to_char(o.accepted_at, 'YYYYMMDD')::int, -1), COALESCE(to_char(o.ready_at, 'YYYYMMDD')::int, -1),
       COALESCE(to_char(o.picked_up_at, 'YYYYMMDD')::int, -1), COALESCE(to_char(o.closed_at, 'YYYYMMDD')::int, -1),
       extract(hour FROM o.placed_at)::smallint, COALESCE(extract(hour FROM o.closed_at)::smallint, -1),
       o.placed_at, o.accepted_at, o.ready_at, o.picked_up_at, o.closed_at,
       o.items_count, o.order_subtotal, o.order_discount, o.delivery_fee, o.tip, o.refund,
       o.order_subtotal - o.order_discount + o.delivery_fee + o.tip, o.delivery_distance_km, o.promised_delivery_minutes,
       ROUND((extract(epoch FROM o.accepted_at - o.placed_at) / 60)::numeric, 2),
       ROUND((extract(epoch FROM o.ready_at - o.accepted_at) / 60)::numeric, 2),
       ROUND((extract(epoch FROM o.picked_up_at - o.ready_at) / 60)::numeric, 2),
       CASE WHEN st.status_group = 'Completed' THEN ROUND((extract(epoch FROM o.closed_at - o.picked_up_at) / 60)::numeric, 2) END,
       CASE WHEN st.status_group = 'Completed' THEN ROUND((extract(epoch FROM o.closed_at - o.placed_at) / 60)::numeric, 2) END,
       CASE WHEN st.status_group = 'Completed' THEN ROUND((extract(epoch FROM o.closed_at - o.placed_at) / 60)::numeric, 2) - o.promised_delivery_minutes END,
       CASE WHEN st.status_group = 'Completed' THEN (ROUND((extract(epoch FROM o.closed_at - o.placed_at) / 60)::numeric, 2) <= o.promised_delivery_minutes)::int END,
       (st.status_group IN ('Cancelled', 'Failed'))::int, o.customer_rating, {{BATCH_ID}}
FROM project_staging.stg_order o
LEFT JOIN dim_order_status st ON st.order_status_code = o.order_status_code
LEFT JOIN dim_customer   dc ON dc.customer_id = o.customer_id   AND o.placed_at::date BETWEEN dc.effective_start_date AND dc.effective_end_date
LEFT JOIN dim_restaurant dr ON dr.restaurant_id = o.restaurant_id AND o.placed_at::date BETWEEN dr.effective_start_date AND dr.effective_end_date
LEFT JOIN dim_courier dk ON dk.courier_id = o.courier_id
LEFT JOIN dim_location lp ON lp.zone_id = o.pickup_zone_id
LEFT JOIN dim_location ld ON ld.zone_id = o.dropoff_zone_id
LEFT JOIN dim_order_channel ch ON ch.channel_code = o.channel_code
LEFT JOIN dim_payment_method pm ON pm.payment_method_code = o.payment_method_code
LEFT JOIN dim_cancellation_reason cr ON cr.reason_code = o.cancellation_reason_code
LEFT JOIN dim_promotion pr ON pr.promotion_id = o.promotion_id
WHERE o.batch_id = {{BATCH_ID}}
ON CONFLICT (order_id) DO UPDATE SET
    courier_key = EXCLUDED.courier_key, order_status_key = EXCLUDED.order_status_key, cancellation_reason_key = EXCLUDED.cancellation_reason_key,
    restaurant_accepted_date_key = EXCLUDED.restaurant_accepted_date_key, food_ready_date_key = EXCLUDED.food_ready_date_key,
    courier_picked_up_date_key = EXCLUDED.courier_picked_up_date_key, order_closed_date_key = EXCLUDED.order_closed_date_key,
    order_closed_hour_key = EXCLUDED.order_closed_hour_key, restaurant_accepted_ts = EXCLUDED.restaurant_accepted_ts, food_ready_ts = EXCLUDED.food_ready_ts,
    courier_picked_up_ts = EXCLUDED.courier_picked_up_ts, order_closed_ts = EXCLUDED.order_closed_ts, tip_amount = EXCLUDED.tip_amount,
    refund_amount = EXCLUDED.refund_amount, order_total_amount = EXCLUDED.order_total_amount, acceptance_lag_minutes = EXCLUDED.acceptance_lag_minutes,
    prep_lag_minutes = EXCLUDED.prep_lag_minutes, pickup_wait_lag_minutes = EXCLUDED.pickup_wait_lag_minutes, transit_lag_minutes = EXCLUDED.transit_lag_minutes,
    total_delivery_minutes = EXCLUDED.total_delivery_minutes, delay_minutes = EXCLUDED.delay_minutes, delivered_on_time_flag = EXCLUDED.delivered_on_time_flag,
    cancelled_flag = EXCLUDED.cancelled_flag, customer_rating = EXCLUDED.customer_rating, etl_batch_id = EXCLUDED.etl_batch_id, etl_load_ts = now();

ANALYZE fact_delivery;
