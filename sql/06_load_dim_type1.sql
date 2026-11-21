-- =====================================================================
-- 06_load_dim_type1.sql  -  dim_location, dim_courier, dim_menu_item, dim_promotion (SCD Type 1 = overwrite)
-- Business key -> surrogate key: the IDENTITY column generates a new key only for NEW natural keys;
-- existing keys are updated in place (ON CONFLICT on the natural key).
-- =====================================================================
SET search_path = project_dw;

INSERT INTO dim_location (location_key, zone_id, zone_name, zone_type, service_tier, city, region, country, etl_batch_id)
OVERRIDING SYSTEM VALUE VALUES (-1, 'UNKNOWN', 'Unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown', {{BATCH_ID}}) ON CONFLICT DO NOTHING;
INSERT INTO dim_courier (courier_key, courier_id, courier_name, vehicle_type, employment_type, hire_date, experience_band, base_city, courier_status, etl_batch_id)
OVERRIDING SYSTEM VALUE VALUES (-1, 'UNASSIGNED', 'Not assigned', 'Unknown', 'Unknown', DATE '1900-01-01', 'Unknown', 'Unknown', 'Unknown', {{BATCH_ID}}) ON CONFLICT DO NOTHING;
INSERT INTO dim_menu_item (menu_item_key, menu_item_id, item_name, item_category, cuisine_type, dietary_type, spice_level, is_combo_meal, list_price, owner_restaurant_id, is_active, etl_batch_id)
OVERRIDING SYSTEM VALUE VALUES (-1, 'UNKNOWN', 'Unknown item', 'Unknown', 'Unknown', 'Unknown', 'Unknown', FALSE, 0, 'UNKNOWN', FALSE, {{BATCH_ID}}) ON CONFLICT DO NOTHING;
INSERT INTO dim_promotion (promotion_key, promotion_id, promotion_code, promotion_name, campaign_name, promotion_type, discount_value, discount_unit, funded_by, target_segment, min_order_amount, start_date, end_date, is_active, etl_batch_id)
OVERRIDING SYSTEM VALUE VALUES
 (-1, 'UNKNOWN', 'UNKNOWN', 'Unknown promotion', 'Unknown', 'Unknown', 0, 'None', 'None', 'None', 0, DATE '1900-01-01', DATE '1900-01-01', FALSE, {{BATCH_ID}}),
 ( 0, 'NONE',    'NONE',    'No promotion',      'None',    'None',    0, 'None', 'None', 'None', 0, DATE '1900-01-01', DATE '9999-12-31', FALSE, {{BATCH_ID}})
ON CONFLICT DO NOTHING;

INSERT INTO dim_location (zone_id, zone_name, zone_type, service_tier, city, region, country, centroid_latitude, centroid_longitude, etl_batch_id)
SELECT zone_id, zone_name, zone_type, service_tier, city, region, country, centroid_latitude, centroid_longitude, {{BATCH_ID}} FROM project_staging.stg_zone
ON CONFLICT (zone_id) DO UPDATE SET zone_name = EXCLUDED.zone_name, zone_type = EXCLUDED.zone_type, service_tier = EXCLUDED.service_tier,
       city = EXCLUDED.city, region = EXCLUDED.region, country = EXCLUDED.country, centroid_latitude = EXCLUDED.centroid_latitude,
       centroid_longitude = EXCLUDED.centroid_longitude, etl_batch_id = EXCLUDED.etl_batch_id, etl_load_ts = now();

INSERT INTO dim_courier (courier_id, courier_name, vehicle_type, employment_type, hire_date, experience_band, base_city, courier_status, etl_batch_id)
SELECT courier_id, courier_name, vehicle_type, employment_type, hire_date, experience_band, base_city, courier_status, {{BATCH_ID}} FROM project_staging.stg_courier
ON CONFLICT (courier_id) DO UPDATE SET courier_name = EXCLUDED.courier_name, vehicle_type = EXCLUDED.vehicle_type, employment_type = EXCLUDED.employment_type,
       hire_date = EXCLUDED.hire_date, experience_band = EXCLUDED.experience_band, base_city = EXCLUDED.base_city,
       courier_status = EXCLUDED.courier_status, etl_batch_id = EXCLUDED.etl_batch_id, etl_load_ts = now();

INSERT INTO dim_menu_item (menu_item_id, item_name, item_category, cuisine_type, dietary_type, spice_level, is_combo_meal, list_price, owner_restaurant_id, is_active, etl_batch_id)
SELECT menu_item_id, item_name, item_category, cuisine_type, dietary_type, spice_level, is_combo_meal, list_price, owner_restaurant_id, is_active, {{BATCH_ID}} FROM project_staging.stg_menu_item
ON CONFLICT (menu_item_id) DO UPDATE SET item_name = EXCLUDED.item_name, item_category = EXCLUDED.item_category, cuisine_type = EXCLUDED.cuisine_type,
       dietary_type = EXCLUDED.dietary_type, spice_level = EXCLUDED.spice_level, is_combo_meal = EXCLUDED.is_combo_meal, list_price = EXCLUDED.list_price,
       is_active = EXCLUDED.is_active, etl_batch_id = EXCLUDED.etl_batch_id, etl_load_ts = now();

INSERT INTO dim_promotion (promotion_id, promotion_code, promotion_name, campaign_name, promotion_type, discount_value, discount_unit, funded_by, target_segment,
                           min_order_amount, start_date, end_date, is_active, etl_batch_id)
SELECT promotion_id, promotion_code, promotion_name, campaign_name, promotion_type, discount_value, discount_unit, funded_by, target_segment,
       min_order_amount, start_date, end_date,
       (SELECT max(placed_at)::date FROM project_staging.stg_order) BETWEEN start_date AND end_date, {{BATCH_ID}}
FROM project_staging.stg_promotion
ON CONFLICT (promotion_id) DO UPDATE SET promotion_code = EXCLUDED.promotion_code, promotion_name = EXCLUDED.promotion_name, campaign_name = EXCLUDED.campaign_name,
       promotion_type = EXCLUDED.promotion_type, discount_value = EXCLUDED.discount_value, discount_unit = EXCLUDED.discount_unit, funded_by = EXCLUDED.funded_by,
       target_segment = EXCLUDED.target_segment, min_order_amount = EXCLUDED.min_order_amount, start_date = EXCLUDED.start_date, end_date = EXCLUDED.end_date,
       is_active = EXCLUDED.is_active, etl_batch_id = EXCLUDED.etl_batch_id, etl_load_ts = now();
