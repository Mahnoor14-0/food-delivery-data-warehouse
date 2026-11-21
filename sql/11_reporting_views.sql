-- =====================================================================
-- 11_reporting_views.sql  -  REPORTING SCHEMA: one view per business question (Q1-Q12) + KPI summary.
-- Every view uses only star joins (fact -> dimensions), as required by Phase 1 objective O1.
-- =====================================================================
SET search_path = project_reporting;

-- Q1  monthly net sales, orders, AOV, MoM growth, same month last year
CREATE VIEW q01_monthly_sales_trend AS
WITH m AS (
    SELECT d.year_month, d.year_number, d.month_number,
           SUM(i.gross_item_amount) AS gmv,
           SUM(i.net_item_amount) FILTER (WHERE s.status_group = 'Completed') AS net_sales,
           COUNT(DISTINCT i.order_id) FILTER (WHERE s.status_group = 'Completed') AS completed_orders
    FROM project_dw.fact_order_item i
    JOIN project_dw.dim_date d ON d.date_key = i.order_date_key
    JOIN project_dw.dim_order_status s ON s.order_status_key = i.order_status_key
    GROUP BY d.year_month, d.year_number, d.month_number)
SELECT year_month, gmv, net_sales, completed_orders, ROUND(net_sales / NULLIF(completed_orders, 0), 2) AS avg_order_value,
       ROUND(100.0 * (net_sales - LAG(net_sales) OVER w) / NULLIF(LAG(net_sales) OVER w, 0), 2) AS mom_growth_pct,
       LAG(net_sales, 12) OVER w AS net_sales_same_month_last_year
FROM m WINDOW w AS (ORDER BY year_number, month_number);

-- Q2  cuisine / category / item revenue and mix by day part
CREATE VIEW q02_sales_by_cuisine_daypart AS
SELECT mi.cuisine_type, mi.item_category, t.day_part, SUM(i.quantity) AS quantity_sold, SUM(i.net_item_amount) AS net_sales,
       ROUND(100.0 * SUM(i.net_item_amount) / SUM(SUM(i.net_item_amount)) OVER (PARTITION BY t.day_part), 2) AS share_of_daypart_sales_pct
FROM project_dw.fact_order_item i
JOIN project_dw.dim_menu_item mi ON mi.menu_item_key = i.menu_item_key
JOIN project_dw.dim_time_of_day t ON t.hour_key = i.order_hour_key
JOIN project_dw.dim_order_status s ON s.order_status_key = i.order_status_key AND s.status_group = 'Completed'
GROUP BY mi.cuisine_type, mi.item_category, t.day_part;

CREATE VIEW q02_top_menu_items AS
SELECT mi.item_name, mi.cuisine_type, mi.item_category, SUM(i.quantity) AS quantity_sold, SUM(i.net_item_amount) AS net_sales,
       RANK() OVER (ORDER BY SUM(i.net_item_amount) DESC) AS sales_rank
FROM project_dw.fact_order_item i
JOIN project_dw.dim_menu_item mi ON mi.menu_item_key = i.menu_item_key
JOIN project_dw.dim_order_status s ON s.order_status_key = i.order_status_key AND s.status_group = 'Completed'
GROUP BY mi.item_name, mi.cuisine_type, mi.item_category;

-- Q3  region > city > zone performance
CREATE VIEW q03_zone_performance AS
SELECT l.region, l.city, l.zone_name, l.service_tier, SUM(i.net_item_amount) AS net_sales,
       COUNT(DISTINCT c.customer_id) AS active_customers,
       ROUND(SUM(i.net_item_amount) / NULLIF(COUNT(DISTINCT c.customer_id), 0), 2) AS sales_per_customer
FROM project_dw.fact_order_item i
JOIN project_dw.dim_location l ON l.location_key = i.delivery_location_key
JOIN project_dw.dim_customer c ON c.customer_key = i.customer_key
JOIN project_dw.dim_order_status s ON s.order_status_key = i.order_status_key AND s.status_group = 'Completed'
GROUP BY l.region, l.city, l.zone_name, l.service_tier;

-- Q4  restaurant ranking: net sales, commission, rating, partner tier
CREATE VIEW q04_restaurant_ranking AS
WITH sales AS (
    SELECT r.restaurant_id, SUM(i.net_item_amount) AS net_sales, SUM(i.platform_commission_amount) AS commission_revenue, COUNT(DISTINCT i.order_id) AS orders
    FROM project_dw.fact_order_item i
    JOIN project_dw.dim_restaurant r ON r.restaurant_key = i.restaurant_key
    JOIN project_dw.dim_order_status s ON s.order_status_key = i.order_status_key AND s.status_group = 'Completed'
    GROUP BY r.restaurant_id),
rating AS (
    SELECT r.restaurant_id, ROUND(AVG(f.customer_rating), 2) AS avg_rating
    FROM project_dw.fact_delivery f JOIN project_dw.dim_restaurant r ON r.restaurant_key = f.restaurant_key GROUP BY r.restaurant_id)
SELECT c.restaurant_id, c.restaurant_name, c.city, c.partner_tier, c.price_tier, s.net_sales, s.commission_revenue, s.orders, g.avg_rating,
       RANK() OVER (ORDER BY s.net_sales DESC) AS sales_rank,
       (s.orders >= (SELECT percentile_cont(0.75) WITHIN GROUP (ORDER BY orders) FROM sales)
        AND g.avg_rating < (SELECT avg(avg_rating) FROM rating)) AS high_volume_low_rating
FROM project_dw.dim_restaurant c JOIN sales s ON s.restaurant_id = c.restaurant_id LEFT JOIN rating g ON g.restaurant_id = c.restaurant_id
WHERE c.is_current;

-- Q5  preparation / acceptance time, peak vs off-peak
CREATE VIEW q05_prep_time_by_restaurant AS
SELECT r.restaurant_id, r.restaurant_name, r.city, t.is_peak_hour, COUNT(*) AS orders_prepared,
       ROUND(AVG(f.prep_lag_minutes), 2) AS avg_prep_minutes, ROUND(AVG(f.acceptance_lag_minutes), 2) AS avg_acceptance_minutes
FROM project_dw.fact_delivery f
JOIN project_dw.dim_restaurant r ON r.restaurant_key = f.restaurant_key
JOIN project_dw.dim_time_of_day t ON t.hour_key = f.order_placed_hour_key
WHERE f.prep_lag_minutes IS NOT NULL
GROUP BY r.restaurant_id, r.restaurant_name, r.city, t.is_peak_hour;

-- Q6  restaurant availability, unavailable items, cancellations
CREATE VIEW q06_restaurant_availability AS
SELECT r.restaurant_id, r.restaurant_name, r.city, COUNT(*) AS days_observed,
       ROUND(100.0 * SUM(s.online_minutes) / NULLIF(SUM(s.scheduled_open_minutes), 0), 2) AS availability_pct,
       COUNT(*) FILTER (WHERE s.online_minutes = 0) AS days_fully_offline,
       ROUND(AVG(s.unavailable_menu_items_count), 1) AS avg_unavailable_items, SUM(s.orders_cancelled_count) AS orders_cancelled,
       SUM(s.orders_received_count) AS orders_received
FROM project_dw.fact_restaurant_daily_snapshot s
JOIN project_dw.dim_restaurant r ON r.restaurant_key = s.restaurant_key
GROUP BY r.restaurant_id, r.restaurant_name, r.city;

-- Q7  customer lifetime value (observed)
CREATE VIEW q07_customer_lifetime_value AS
SELECT c.customer_id, c.customer_name, c.customer_segment, c.loyalty_tier, c.acquisition_channel, c.home_city,
       COUNT(DISTINCT i.order_id) AS orders, SUM(i.net_item_amount) AS lifetime_value,
       RANK() OVER (ORDER BY SUM(i.net_item_amount) DESC) AS ltv_rank
FROM project_dw.fact_order_item i
JOIN project_dw.dim_customer c ON c.customer_key = i.customer_key AND c.is_current
JOIN project_dw.dim_order_status s ON s.order_status_key = i.order_status_key AND s.status_group = 'Completed'
WHERE c.customer_key > 0
GROUP BY c.customer_id, c.customer_name, c.customer_segment, c.loyalty_tier, c.acquisition_channel, c.home_city;

-- Q8  order frequency per segment (segment AS IT WAS on the order date = Type 2 payoff)
CREATE VIEW q08_segment_order_frequency AS
SELECT d.year_month, c.customer_segment, COUNT(DISTINCT f.order_id) AS orders, COUNT(DISTINCT c.customer_id) AS active_customers,
       ROUND(COUNT(DISTINCT f.order_id)::numeric / NULLIF(COUNT(DISTINCT c.customer_id), 0), 2) AS orders_per_active_customer
FROM project_dw.fact_delivery f
JOIN project_dw.dim_customer c ON c.customer_key = f.customer_key
JOIN project_dw.dim_date d ON d.date_key = f.order_placed_date_key
JOIN project_dw.dim_order_status s ON s.order_status_key = f.order_status_key AND s.status_group = 'Completed'
WHERE c.customer_key > 0
GROUP BY d.year_month, c.customer_segment;

-- Q9  delivery time / on-time % by zone, hour and vehicle
CREATE VIEW q09_delivery_performance AS
SELECT l.city, l.zone_name, t.hour_label, k.vehicle_type, COUNT(*) AS delivered_orders,
       ROUND(AVG(f.total_delivery_minutes), 2) AS avg_delivery_minutes, ROUND(100.0 * SUM(f.delivered_on_time_flag) / COUNT(*), 2) AS on_time_pct,
       ROUND(AVG(f.delivery_distance_km), 2) AS avg_distance_km
FROM project_dw.fact_delivery f
JOIN project_dw.dim_location l ON l.location_key = f.dropoff_location_key
JOIN project_dw.dim_time_of_day t ON t.hour_key = f.order_placed_hour_key
JOIN project_dw.dim_courier k ON k.courier_key = f.courier_key
JOIN project_dw.dim_order_status s ON s.order_status_key = f.order_status_key AND s.status_group = 'Completed'
GROUP BY l.city, l.zone_name, t.hour_label, k.vehicle_type;

CREATE VIEW q09_courier_productivity AS
SELECT k.courier_id, k.courier_name, k.vehicle_type, COUNT(*) AS deliveries, COUNT(DISTINCT f.order_placed_date_key) AS active_days,
       ROUND(COUNT(*)::numeric / COUNT(DISTINCT f.order_placed_date_key), 2) AS deliveries_per_day,
       ROUND(100.0 * SUM(f.delivered_on_time_flag) / COUNT(*), 2) AS on_time_pct
FROM project_dw.fact_delivery f
JOIN project_dw.dim_courier k ON k.courier_key = f.courier_key AND k.courier_key > 0
JOIN project_dw.dim_order_status s ON s.order_status_key = f.order_status_key AND s.status_group = 'Completed'
GROUP BY k.courier_id, k.courier_name, k.vehicle_type;

-- Q10  minutes per lifecycle stage (bottleneck)
CREATE VIEW q10_stage_delays AS
SELECT r.city, r.restaurant_id, l.zone_name, COUNT(*) AS orders,
       ROUND(AVG(f.acceptance_lag_minutes), 2) AS avg_acceptance, ROUND(AVG(f.prep_lag_minutes), 2) AS avg_preparation,
       ROUND(AVG(f.pickup_wait_lag_minutes), 2) AS avg_pickup_wait, ROUND(AVG(f.transit_lag_minutes), 2) AS avg_transit,
       ROUND(AVG(f.delay_minutes), 2) AS avg_delay_vs_promise
FROM project_dw.fact_delivery f
JOIN project_dw.dim_restaurant r ON r.restaurant_key = f.restaurant_key
JOIN project_dw.dim_location l ON l.location_key = f.dropoff_location_key
JOIN project_dw.dim_order_status s ON s.order_status_key = f.order_status_key AND s.status_group = 'Completed'
GROUP BY r.city, r.restaurant_id, l.zone_name;

-- Q11  cancellation rate by reason + lost revenue (order lines of cancelled / failed orders)
CREATE VIEW q11_cancellations_by_reason AS
WITH lost AS (
    SELECT fd.cancellation_reason_key, SUM(i.net_item_amount) AS lost_revenue
    FROM project_dw.fact_order_item i
    JOIN project_dw.fact_delivery fd ON fd.order_id = i.order_id
    JOIN project_dw.dim_order_status s ON s.order_status_key = i.order_status_key AND s.status_group IN ('Cancelled', 'Failed')
    GROUP BY fd.cancellation_reason_key),
cnt AS (
    SELECT cancellation_reason_key, COUNT(*) AS orders, SUM(cancelled_flag) AS cancelled_orders, SUM(refund_amount) AS refund_amount
    FROM project_dw.fact_delivery GROUP BY cancellation_reason_key)
SELECT r.reason_category, r.reason_name, r.is_preventable, c.cancelled_orders,
       ROUND(100.0 * c.cancelled_orders / (SELECT COUNT(*) FROM project_dw.fact_delivery), 3) AS pct_of_all_orders,
       l.lost_revenue, c.refund_amount
FROM cnt c JOIN project_dw.dim_cancellation_reason r ON r.cancellation_reason_key = c.cancellation_reason_key
LEFT JOIN lost l ON l.cancellation_reason_key = c.cancellation_reason_key WHERE c.cancelled_orders > 0;

CREATE VIEW q11_cancellation_rate_by_dimension AS
SELECT 'restaurant' AS dimension, r.restaurant_id AS member, COUNT(*) AS orders, SUM(f.cancelled_flag) AS cancelled, ROUND(100.0 * SUM(f.cancelled_flag) / COUNT(*), 2) AS cancellation_rate_pct
FROM project_dw.fact_delivery f JOIN project_dw.dim_restaurant r ON r.restaurant_key = f.restaurant_key GROUP BY r.restaurant_id
UNION ALL
SELECT 'payment_method', p.payment_method_name, COUNT(*), SUM(f.cancelled_flag), ROUND(100.0 * SUM(f.cancelled_flag) / COUNT(*), 2)
FROM project_dw.fact_delivery f JOIN project_dw.dim_payment_method p ON p.payment_method_key = f.payment_method_key GROUP BY p.payment_method_name
UNION ALL
SELECT 'hour_of_day', t.hour_label, COUNT(*), SUM(f.cancelled_flag), ROUND(100.0 * SUM(f.cancelled_flag) / COUNT(*), 2)
FROM project_dw.fact_delivery f JOIN project_dw.dim_time_of_day t ON t.hour_key = f.order_placed_hour_key GROUP BY t.hour_label
UNION ALL
SELECT 'zone', l.zone_name, COUNT(*), SUM(f.cancelled_flag), ROUND(100.0 * SUM(f.cancelled_flag) / COUNT(*), 2)
FROM project_dw.fact_delivery f JOIN project_dw.dim_location l ON l.location_key = f.dropoff_location_key GROUP BY l.zone_name;

-- Q12  promotion redemption (offered vs redeemed) and promo vs non-promo orders
CREATE VIEW q12_promotion_redemption AS
WITH offered AS (
    SELECT promotion_key, SUM(eligibility_count) AS offered FROM project_dw.fact_promotion_eligibility GROUP BY promotion_key),
redeemed AS (
    SELECT i.promotion_key, COUNT(DISTINCT c.customer_id) AS redeeming_customers, COUNT(DISTINCT i.order_id) AS promo_orders,
           SUM(i.net_item_amount) AS net_sales, SUM(i.item_discount_amount) AS discount_cost
    FROM project_dw.fact_order_item i JOIN project_dw.dim_customer c ON c.customer_key = i.customer_key
    WHERE i.promotion_key > 0 GROUP BY i.promotion_key)
SELECT p.campaign_name, p.promotion_code, p.promotion_type, p.target_segment, o.offered, COALESCE(r.redeeming_customers, 0) AS redeeming_customers,
       ROUND(100.0 * COALESCE(r.redeeming_customers, 0) / NULLIF(o.offered, 0), 2) AS redemption_rate_pct,
       COALESCE(r.promo_orders, 0) AS promo_orders, r.net_sales, r.discount_cost
FROM offered o JOIN project_dw.dim_promotion p ON p.promotion_key = o.promotion_key LEFT JOIN redeemed r ON r.promotion_key = o.promotion_key;

CREATE VIEW q12_promo_vs_non_promo AS
SELECT CASE WHEN fd.promotion_key > 0 THEN 'Promotion order' ELSE 'No promotion' END AS order_type, COUNT(*) AS orders,
       ROUND(AVG(fd.order_subtotal_amount - fd.order_discount_amount), 2) AS avg_order_value, SUM(fd.order_subtotal_amount - fd.order_discount_amount) AS net_sales,
       SUM(fd.order_discount_amount) AS discount_cost
FROM project_dw.fact_delivery fd JOIN project_dw.dim_order_status s ON s.order_status_key = fd.order_status_key AND s.status_group = 'Completed'
GROUP BY 1;

-- KPI catalogue (Business Requirements Document, section 6)
CREATE VIEW kpi_summary AS
SELECT 'GMV'                  AS kpi, SUM(gross_item_amount)::numeric AS value FROM project_dw.fact_order_item
UNION ALL SELECT 'Net Sales', SUM(i.net_item_amount) FROM project_dw.fact_order_item i JOIN project_dw.dim_order_status s ON s.order_status_key = i.order_status_key AND s.status_group = 'Completed'
UNION ALL SELECT 'Orders', COUNT(*) FROM project_dw.fact_delivery
UNION ALL SELECT 'On-Time Delivery %', ROUND(100.0 * SUM(delivered_on_time_flag) / COUNT(delivered_on_time_flag), 2) FROM project_dw.fact_delivery
UNION ALL SELECT 'Cancellation Rate %', ROUND(100.0 * SUM(cancelled_flag) / COUNT(*), 2) FROM project_dw.fact_delivery
UNION ALL SELECT 'Average Delivery Time (min)', ROUND(AVG(total_delivery_minutes), 2) FROM project_dw.fact_delivery
UNION ALL SELECT 'Average Prep Time (min)', ROUND(AVG(prep_lag_minutes), 2) FROM project_dw.fact_delivery
UNION ALL SELECT 'Restaurant Availability %', ROUND(100.0 * SUM(online_minutes) / SUM(scheduled_open_minutes), 2) FROM project_dw.fact_restaurant_daily_snapshot
UNION ALL SELECT 'Platform Commission Revenue', SUM(i.platform_commission_amount) FROM project_dw.fact_order_item i JOIN project_dw.dim_order_status s ON s.order_status_key = i.order_status_key AND s.status_group = 'Completed';
