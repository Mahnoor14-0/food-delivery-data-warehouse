-- =====================================================================
-- 03_staging_clean_extracts.sql
-- raw_* -> stg_* for reference files and the CRM / RPP / DISP / OMS / MKT extracts,
-- followed by the cleaning log for ALL staging rules (public + extracts).
-- Rules: remove duplicates | handle NULLs | standardise text | convert types
-- =====================================================================
SET search_path = project_staging;

CREATE OR REPLACE FUNCTION fn_bool(p TEXT) RETURNS BOOLEAN AS $$
    SELECT lower(btrim(p)) IN ('true','t','1','yes','y')
$$ LANGUAGE sql IMMUTABLE;

TRUNCATE stg_order_channel, stg_payment_method, stg_order_status, stg_cancellation_reason, stg_city_master, stg_holiday,
         stg_customer_snapshot, stg_restaurant_snapshot, stg_menu_item, stg_courier, stg_zone, stg_order, stg_order_line,
         stg_promotion, stg_promotion_target, stg_availability_log;

-- ------------------------------------------------------------- reference data
INSERT INTO stg_order_channel SELECT upper(btrim(channel_code)), btrim(channel_name), btrim(platform_type), fn_bool(is_self_service) FROM raw_ref_order_channel;
INSERT INTO stg_payment_method SELECT upper(btrim(payment_method_code)), btrim(payment_method_name), btrim(payment_type), fn_bool(is_prepaid), fn_bool(is_online_payment) FROM raw_ref_payment_method;
INSERT INTO stg_order_status SELECT upper(btrim(order_status_code)), btrim(order_status_name), btrim(status_group), fn_bool(is_final_status), fn_bool(counts_as_revenue) FROM raw_ref_order_status;
INSERT INTO stg_cancellation_reason SELECT upper(btrim(reason_code)), btrim(reason_name), btrim(reason_category), btrim(cancelled_by), fn_bool(is_preventable) FROM raw_ref_cancellation_reason;
INSERT INTO stg_city_master SELECT upper(btrim(city_code)), btrim(city_name), btrim(region), btrim(country) FROM raw_ref_city_master;
INSERT INTO stg_holiday SELECT to_date(btrim(holiday_date),'YYYY-MM-DD'), btrim(holiday_name) FROM raw_ref_holiday;

-- ------------------------------------------------------------- zones & couriers & menu & promotions
INSERT INTO stg_zone
SELECT DISTINCT ON (btrim(zone_id)) btrim(zone_id), initcap(btrim(zone_name)), initcap(btrim(zone_type)), initcap(btrim(service_tier)),
       btrim(city), btrim(region), btrim(country), fn_to_num(centroid_latitude), fn_to_num(centroid_longitude)
FROM raw_oms_zone_master WHERE fn_clean_txt(zone_id) IS NOT NULL ORDER BY btrim(zone_id);

INSERT INTO stg_order
SELECT DISTINCT ON (fn_to_num(batch_id)::int, btrim(order_id))
       fn_to_num(batch_id)::int, btrim(order_id), fn_clean_txt(customer_id), btrim(restaurant_id), fn_clean_txt(courier_id),
       fn_clean_txt(pickup_zone_id), fn_clean_txt(dropoff_zone_id), upper(fn_clean_txt(channel_code)), upper(fn_clean_txt(payment_method_code)),
       upper(btrim(order_status_code)), upper(fn_clean_txt(cancellation_reason_code)), fn_clean_txt(promotion_id),
       NULLIF(btrim(placed_at),'')::timestamp, NULLIF(btrim(accepted_at),'')::timestamp, NULLIF(btrim(ready_at),'')::timestamp,
       NULLIF(btrim(picked_up_at),'')::timestamp, NULLIF(btrim(closed_at),'')::timestamp,
       fn_to_num(items_count)::smallint, COALESCE(fn_to_num(order_subtotal),0), COALESCE(fn_to_num(order_discount),0),
       COALESCE(fn_to_num(delivery_fee),0), COALESCE(fn_to_num(tip),0), COALESCE(fn_to_num(refund),0),
       fn_to_num(delivery_distance_km), fn_to_num(promised_delivery_minutes)::smallint,
       CASE WHEN fn_to_num(customer_rating) BETWEEN 1 AND 5 THEN fn_to_num(customer_rating)::smallint END
FROM raw_oms_order WHERE fn_clean_txt(order_id) IS NOT NULL
ORDER BY fn_to_num(batch_id)::int, btrim(order_id), ctid;

INSERT INTO stg_order_line
SELECT DISTINCT ON (btrim(order_id), fn_to_num(line_no)::int)
       btrim(order_id), fn_to_num(line_no)::smallint, btrim(menu_item_id), fn_to_num(qty)::int, fn_to_num(unit_price)
FROM raw_oms_order_line WHERE fn_to_num(qty) >= 1
ORDER BY btrim(order_id), fn_to_num(line_no)::int, ctid;

INSERT INTO stg_courier
SELECT DISTINCT ON (btrim(courier_id)) btrim(courier_id), btrim(courier_name), btrim(vehicle_type), btrim(employment_type),
       to_date(btrim(hire_date),'YYYY-MM-DD'),
       CASE WHEN (SELECT max(placed_at)::date FROM stg_order) - to_date(btrim(hire_date),'YYYY-MM-DD') < 183 THEN 'Under 6m'
            WHEN (SELECT max(placed_at)::date FROM stg_order) - to_date(btrim(hire_date),'YYYY-MM-DD') < 365 THEN '6-12m'
            WHEN (SELECT max(placed_at)::date FROM stg_order) - to_date(btrim(hire_date),'YYYY-MM-DD') < 730 THEN '1-2y' ELSE '2y+' END,
       btrim(base_city), initcap(btrim(courier_status))
FROM raw_disp_courier ORDER BY btrim(courier_id), ctid;

INSERT INTO stg_menu_item
SELECT DISTINCT ON (btrim(menu_item_id)) btrim(menu_item_id), btrim(restaurant_id), btrim(item_name), btrim(item_category), btrim(cuisine_type),
       btrim(dietary_type), btrim(spice_level), fn_bool(is_combo_meal), fn_to_num(list_price), fn_bool(is_active)
FROM raw_rpp_menu_item ORDER BY btrim(menu_item_id), ctid;

INSERT INTO stg_promotion
SELECT DISTINCT ON (btrim(promotion_id)) btrim(promotion_id), upper(btrim(promotion_code)), btrim(promotion_name), btrim(campaign_name), btrim(promotion_type),
       fn_to_num(discount_value), btrim(discount_unit), btrim(funded_by), btrim(target_segment), fn_to_num(min_order_amount),
       to_date(btrim(start_date),'YYYY-MM-DD'), to_date(btrim(end_date),'YYYY-MM-DD')
FROM raw_mkt_promotion ORDER BY btrim(promotion_id), ctid;

INSERT INTO stg_promotion_target
SELECT DISTINCT btrim(promotion_id), btrim(customer_id), to_date(btrim(issued_at),'YYYY-MM-DD'), to_date(btrim(expires_at),'YYYY-MM-DD')
FROM raw_mkt_promotion_target;

INSERT INTO stg_availability_log
SELECT DISTINCT ON (to_date(btrim(log_date),'YYYY-MM-DD'), btrim(restaurant_id))
       to_date(btrim(log_date),'YYYY-MM-DD'), btrim(restaurant_id), fn_to_num(scheduled_open_minutes)::smallint, fn_to_num(online_minutes)::smallint,
       fn_to_num(active_menu_items)::smallint, fn_to_num(unavailable_menu_items)::smallint, COALESCE(fn_to_num(open_complaints),0)::smallint
FROM raw_rpp_availability_log ORDER BY to_date(btrim(log_date),'YYYY-MM-DD'), btrim(restaurant_id), ctid;

-- ------------------------------------------------------------- CRM + RPP snapshots (feed the Type 2 loads)
INSERT INTO stg_customer_snapshot
SELECT DISTINCT ON (snap, btrim(r.customer_id))
       snap, btrim(r.customer_id), btrim(r.full_name),
       CASE WHEN fn_clean_txt(r.gender) IS NULL THEN 'Unknown' ELSE initcap(btrim(r.gender)) END,          -- NULL handling
       CASE WHEN a < 25 THEN '18-24' WHEN a < 35 THEN '25-34' WHEN a < 45 THEN '35-44' WHEN a < 55 THEN '45-54' ELSE '55+' END,
       to_date(btrim(r.signup_date),'YYYY-MM-DD'), initcap(btrim(r.acquisition_channel)), initcap(btrim(r.customer_segment)),
       initcap(btrim(r.loyalty_tier)), fn_bool(r.is_subscriber), initcap(btrim(r.home_zone)),
       COALESCE(cm.city_name, initcap(btrim(r.home_city)))                                                 -- text standardisation
FROM (SELECT r.*, r.ctid AS row_tid, to_date(btrim(snapshot_date),'YYYY-MM-DD') AS snap,
             extract(year FROM age(to_date(btrim(snapshot_date),'YYYY-MM-DD'), to_date(btrim(dob),'YYYY-MM-DD')))::int AS a
      FROM raw_crm_customer_snapshot r) r
LEFT JOIN stg_city_master cm ON lower(cm.city_name) = lower(btrim(r.home_city))
ORDER BY snap, btrim(r.customer_id), r.row_tid;

INSERT INTO stg_restaurant_snapshot
SELECT DISTINCT ON (to_date(btrim(snapshot_date),'YYYY-MM-DD'), btrim(restaurant_id))
       to_date(btrim(snapshot_date),'YYYY-MM-DD'), btrim(restaurant_id), btrim(restaurant_name), btrim(brand_name), btrim(chain_type),
       btrim(primary_cuisine), btrim(secondary_cuisine), fn_bool(is_cloud_kitchen), to_date(btrim(onboarding_date),'YYYY-MM-DD'),
       btrim(city), btrim(zone_name), btrim(price_tier), btrim(partner_tier), fn_to_num(commission_rate_pct), btrim(contract_status)
FROM raw_rpp_restaurant_snapshot
ORDER BY to_date(btrim(snapshot_date),'YYYY-MM-DD'), btrim(restaurant_id), ctid;

ANALYZE;

-- =====================================================================
-- CLEANING LOG  (one row per rule; counts measured from raw vs stg)
-- =====================================================================
DELETE FROM etl_cleaning_log;
INSERT INTO etl_cleaning_log (batch_id, source_table, rule_id, rule_category, rule_text, rows_in, rows_affected)
SELECT 1, 'zomato_delivery', v.rid, v.cat, v.txt, (SELECT count(*) FROM raw_zomato_delivery), v.n FROM (VALUES
 ('Z01','Duplicates','Duplicate order ids removed (first occurrence kept)',
    (SELECT count(*) - count(DISTINCT btrim(id)) FROM raw_zomato_delivery)),
 ('Z02','Type conversion','Times stored as Excel day-fractions (e.g. 0.8333 -> 20:00) converted to HH:MM',
    (SELECT count(*) FROM raw_zomato_delivery WHERE btrim(time_orderd) ~ '^\d+\.\d+$' OR btrim(time_order_picked) ~ '^\d+\.\d+$')),
 ('Z03','Type conversion','Times written as HH:MM:SS or 24:xx converted to timestamps (date + time of day)',
    (SELECT count(*) FROM raw_zomato_delivery WHERE btrim(time_orderd) ~ '^\d{1,2}:\d{2}:\d{2}$' OR btrim(time_order_picked) ~ '^\d{1,2}:\d{2}:\d{2}$')),
 ('Z04','Validity','Orders crossing midnight: pick-up / delivery moved to the next calendar day',
    (SELECT count(*) FROM stg_zomato_delivery WHERE picked_up_ts::date > placed_ts::date)),
 ('Z05','NULL handling','Missing / unparseable order time imputed = pick-up time minus median lag (10 min)',
    (SELECT count(*) FROM stg_zomato_delivery WHERE f_placed_ts_imputed)),
 ('Z06','Validity','Negative (sign-flipped) restaurant coordinates corrected with ABS()',
    (SELECT count(*) FROM stg_zomato_delivery WHERE f_coord_sign_fixed)),
 ('Z07','Validity','Zero (0,0) restaurant coordinates repaired from the restaurant''s own valid rows',
    (SELECT count(*) FROM stg_zomato_delivery WHERE f_coord_from_master)),
 ('Z08','NULL handling','Zero coordinates with no valid row for that restaurant -> location left NULL (maps to Unknown member -1)',
    (SELECT count(*) FROM stg_zomato_delivery WHERE f_coord_unrecoverable)),
 ('Z09','Validity','Courier rating outside the 1-5 scale set to NULL',
    (SELECT count(*) FROM stg_zomato_delivery WHERE f_rating_invalid)),
 ('Z10','Validity','Courier age below 18 set to NULL',
    (SELECT count(*) FROM stg_zomato_delivery WHERE f_age_invalid)),
 ('Z11','Text standardisation','City type typo "Metropolitian" corrected to "Metropolitan"',
    (SELECT count(*) FROM raw_zomato_delivery WHERE lower(btrim(city)) = 'metropolitian')),
 ('Z12','Text standardisation','Vehicle type codes mapped to Phase 1 names (motorcycle -> Motorbike, electric_scooter -> EV Scooter ...)',
    (SELECT count(*) FROM stg_zomato_delivery WHERE vehicle_type <> 'Unknown')),
 ('Z13','NULL handling','Missing weather / traffic / city type replaced by the label "Unknown"',
    (SELECT count(*) FROM stg_zomato_delivery WHERE weather = 'Unknown' OR road_traffic = 'Unknown' OR city_type = 'Unknown')),
 ('Z14','Derivation','Restaurant id derived from courier id (CITYRESnnDELnn -> CITY-Rnn)',
    (SELECT count(*) FROM stg_zomato_delivery)),
 ('Z15','Derivation','Delivery distance (km) derived with the haversine formula from repaired coordinates',
    (SELECT count(distinct order_id) FROM stg_zomato_delivery WHERE distance_km IS NOT NULL)),
 ('Z16','Validity','Rows rejected (no usable date/time, impossible duration or malformed courier id)',
    (SELECT (SELECT count(DISTINCT btrim(id)) FROM raw_zomato_delivery) - (SELECT count(*) FROM stg_zomato_delivery))),
 ('Z17','Validity','Evidence for the Time_taken assumption: orders where order->pick-up lag exceeds Time_taken (would be impossible if Time_taken were order->delivery)',
    (SELECT count(*) FROM stg_zomato_delivery WHERE extract(epoch FROM (picked_up_ts - placed_ts))/60 > transit_minutes))
) AS v(rid, cat, txt, n);

INSERT INTO etl_cleaning_log (batch_id, source_table, rule_id, rule_category, rule_text, rows_in, rows_affected)
SELECT 1, 'indian_food_101', v.rid, v.cat, v.txt, (SELECT count(*) FROM raw_indian_food), v.n FROM (VALUES
 ('F01','NULL handling','Placeholder -1 in flavour / state / region / times replaced by NULL or "Unknown"',
    (SELECT count(*) FROM raw_indian_food WHERE btrim(flavor_profile) = '-1' OR btrim(state) = '-1' OR btrim(region) = '-1' OR btrim(prep_time) = '-1')),
 ('F02','Text standardisation','Diet / course vocabulary mapped to Phase 1 domain (Veg, Non-Veg; Main, Starter, Dessert)',
    (SELECT count(*) FROM stg_indian_food)),
 ('F03','Derivation','State mapped to a cuisine family (Punjabi, Gujarati, South Indian ...)',
    (SELECT count(*) FROM stg_indian_food))
) AS v(rid, cat, txt, n);

INSERT INTO etl_cleaning_log (batch_id, source_table, rule_id, rule_category, rule_text, rows_in, rows_affected)
SELECT 1, 'crm_customer_snapshot', v.rid, v.cat, v.txt, (SELECT count(*) FROM raw_crm_customer_snapshot), v.n FROM (VALUES
 ('C01','Duplicates','Re-sent snapshot rows removed (same snapshot_date + customer_id)',
    (SELECT (SELECT count(*) FROM raw_crm_customer_snapshot) - (SELECT count(*) FROM stg_customer_snapshot))),
 ('C02','Text standardisation','City names with stray spaces / upper / lower case standardised to the city master (e.g. " lahore " -> Lahore style)',
    (SELECT count(*) FROM raw_crm_customer_snapshot r JOIN stg_city_master c ON lower(btrim(r.home_city)) = lower(c.city_name) WHERE r.home_city <> c.city_name)),
 ('C03','NULL handling','Blank gender replaced by "Unknown"',
    (SELECT count(*) FROM raw_crm_customer_snapshot WHERE fn_clean_txt(gender) IS NULL)),
 ('C04','Derivation','Date of birth converted to age band (PII minimisation: dob is not carried into the DW)',
    (SELECT count(*) FROM stg_customer_snapshot))
) AS v(rid, cat, txt, n);

INSERT INTO etl_cleaning_log (batch_id, source_table, rule_id, rule_category, rule_text, rows_in, rows_affected)
SELECT 1, v.tbl, v.rid, v.cat, v.txt, v.rin, v.n FROM (VALUES
 ('oms_order','O01','Duplicates','Duplicate (batch, order_id) rows removed',
    (SELECT count(*) FROM raw_oms_order), (SELECT (SELECT count(*) FROM raw_oms_order) - (SELECT count(*) FROM stg_order))),
 ('oms_order','O02','Type conversion','Text timestamps / money / counts converted to TIMESTAMP, NUMERIC and SMALLINT',
    (SELECT count(*) FROM raw_oms_order), (SELECT count(*) FROM stg_order)),
 ('oms_order','O03','NULL handling','Guest checkout orders keep customer_id NULL (-> customer_key -1)',
    (SELECT count(*) FROM raw_oms_order), (SELECT count(*) FROM stg_order WHERE customer_id IS NULL)),
 ('oms_order','O04','NULL handling','Orders without a courier (cancelled before pick-up) keep courier_id NULL (-> -1, BR-07)',
    (SELECT count(*) FROM raw_oms_order), (SELECT count(*) FROM stg_order WHERE courier_id IS NULL)),
 ('oms_order','O05','Validity','Customer ratings outside 1-5 set to NULL',
    (SELECT count(*) FROM raw_oms_order), (SELECT count(*) FROM raw_oms_order WHERE fn_to_num(customer_rating) IS NOT NULL AND fn_to_num(customer_rating) NOT BETWEEN 1 AND 5)),
 ('oms_order_line','L01','Duplicates','Duplicate (order_id, line_no) lines removed / invalid quantity rows dropped',
    (SELECT count(*) FROM raw_oms_order_line), (SELECT (SELECT count(*) FROM raw_oms_order_line) - (SELECT count(*) FROM stg_order_line))),
 ('rpp_restaurant_snapshot','R01','Duplicates','Duplicate (snapshot_date, restaurant_id) rows removed',
    (SELECT count(*) FROM raw_rpp_restaurant_snapshot), (SELECT (SELECT count(*) FROM raw_rpp_restaurant_snapshot) - (SELECT count(*) FROM stg_restaurant_snapshot))),
 ('rpp_availability_log','A01','Duplicates','Duplicate (log_date, restaurant_id) rows removed',
    (SELECT count(*) FROM raw_rpp_availability_log), (SELECT (SELECT count(*) FROM raw_rpp_availability_log) - (SELECT count(*) FROM stg_availability_log))),
 ('mkt_promotion_target','M01','Duplicates','Duplicate (promotion, customer, issue date) rows removed',
    (SELECT count(*) FROM raw_mkt_promotion_target), (SELECT (SELECT count(*) FROM raw_mkt_promotion_target) - (SELECT count(*) FROM stg_promotion_target)))
) AS v(tbl, rid, cat, txt, rin, n);