-- =====================================================================
-- 02_staging_clean_public.sql
-- STAGING TRANSFORMS for the two PUBLIC datasets
--   raw_zomato_delivery -> stg_zomato_delivery   (Kaggle Food Delivery Dataset)
--   raw_indian_food     -> stg_indian_food       (Kaggle Indian Food 101)
-- Cleaning rules (every rule is counted in etl_cleaning_log):
--   Remove duplicates | Handle NULLs | Standardise text | Convert data types |
--   Validity repairs  | Derivations
-- =====================================================================
SET search_path = project_staging;

-- ---------------------------------------------------------------- helper functions
CREATE OR REPLACE FUNCTION fn_clean_txt(p TEXT) RETURNS TEXT AS $$
    SELECT CASE WHEN p IS NULL OR btrim(p) = '' OR lower(btrim(p)) IN ('nan','null','none','na','n/a') THEN NULL ELSE btrim(p) END
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION fn_to_num(p TEXT) RETURNS NUMERIC AS $$
    SELECT CASE WHEN fn_clean_txt(p) ~ '^-?\d+(\.\d+)?$' THEN fn_clean_txt(p)::numeric ELSE NULL END
$$ LANGUAGE sql IMMUTABLE;

-- Parses 'HH:MM', 'HH:MM:SS' (hours may be >= 24) and Excel day-fractions ('0.833333333' = 20:00, '1' = 24:00)
CREATE OR REPLACE FUNCTION fn_parse_tod(p TEXT) RETURNS INTERVAL AS $$
DECLARE t TEXT := fn_clean_txt(p); f NUMERIC;
BEGIN
    IF t IS NULL THEN RETURN NULL; END IF;
    IF t ~ '^\d{1,2}:\d{2}(:\d{2})?$' THEN
        RETURN make_interval(hours => split_part(t,':',1)::int, mins => split_part(t,':',2)::int);
    ELSIF t ~ '^\d+(\.\d+)?$' THEN
        f := t::numeric;
        IF f > 1.0001 THEN RETURN NULL; END IF;
        RETURN make_interval(mins => round(f * 1440)::int);       -- minute resolution
    END IF;
    RETURN NULL;
END $$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION fn_haversine_km(lat1 NUMERIC, lon1 NUMERIC, lat2 NUMERIC, lon2 NUMERIC) RETURNS NUMERIC AS $$
    SELECT CASE WHEN lat1 IS NULL OR lon1 IS NULL OR lat2 IS NULL OR lon2 IS NULL THEN NULL
    ELSE round((2 * 6371 * asin(sqrt(
        power(sin(radians(lat2 - lat1) / 2), 2) +
        cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2))))::numeric, 2) END
$$ LANGUAGE sql IMMUTABLE;

-- ---------------------------------------------------------------- public dataset 1: delivery orders
TRUNCATE stg_zomato_delivery;
ANALYZE raw_zomato_delivery;

WITH
numbered AS MATERIALIZED (            -- RULE Z01: remove duplicate order ids (keep first occurrence)
    SELECT r.*, ROW_NUMBER() OVER (PARTITION BY btrim(id) ORDER BY src_row_no) AS rn
    FROM raw_zomato_delivery r WHERE fn_clean_txt(id) IS NOT NULL
),
typed AS MATERIALIZED (               -- RULE Z02: convert data types, tolerate junk values
    SELECT src_row_no,
           btrim(id)                                         AS order_id,
           btrim(delivery_person_id)                         AS courier_id,
           substring(btrim(delivery_person_id) FROM '^(.*?)RES')              AS city_code,
           substring(btrim(delivery_person_id) FROM '^(.*?)RES') || '-R' ||
               substring(btrim(delivery_person_id) FROM 'RES(\d+)DEL')        AS restaurant_id,
           fn_to_num(delivery_person_age)                    AS age_raw,
           fn_to_num(delivery_person_ratings)                AS rating_raw,
           fn_to_num(restaurant_latitude)                    AS rl,   fn_to_num(restaurant_longitude)        AS ro,
           fn_to_num(delivery_location_latitude)             AS dl,   fn_to_num(delivery_location_longitude) AS dlo,
           CASE WHEN fn_clean_txt(order_date) ~ '^\d{2}-\d{2}-\d{4}$' THEN to_date(btrim(order_date),'DD-MM-YYYY') END AS od,
           fn_parse_tod(time_orderd)                         AS tod_o,
           fn_parse_tod(time_order_picked)                   AS tod_p,
           fn_clean_txt(weather_conditions)                  AS weather,
           fn_clean_txt(road_traffic_density)                AS traffic,
           fn_to_num(vehicle_condition)                      AS vcond,
           fn_clean_txt(type_of_order)                       AS otype,
           lower(fn_clean_txt(type_of_vehicle))              AS vtype,
           fn_to_num(multiple_deliveries)                    AS multi,
           fn_clean_txt(festival)                            AS fest,
           fn_clean_txt(city)                                AS ctype,
           fn_to_num(time_taken_min)                         AS transit
    FROM numbered WHERE rn = 1
),
stamped AS MATERIALIZED (             -- RULE Z03/Z04: build timestamps, midnight roll-over
    SELECT t.*,
           (od + tod_o) AS placed_raw,
           CASE WHEN od IS NULL OR tod_p IS NULL THEN NULL
                WHEN tod_o IS NOT NULL AND (od + tod_p) - (od + tod_o) < interval '-12 hours' THEN (od + tod_p) + interval '1 day'
                ELSE (od + tod_p) END AS picked_adj
    FROM typed t
),
lagstat AS MATERIALIZED (             -- median order->pick-up lag used to impute a missing order time (RULE Z05)
    SELECT COALESCE(percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM (picked_adj - placed_raw))/60), 10) AS med_lag_min
    FROM stamped WHERE placed_raw IS NOT NULL AND picked_adj IS NOT NULL AND picked_adj - placed_raw BETWEEN interval '0' AND interval '60 minutes'
),
rest_master AS MATERIALIZED (         -- restaurant coordinates are constant per restaurant -> median of the valid rows
    SELECT restaurant_id,
           (percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(rl)))::numeric AS m_lat,
           (percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(ro)))::numeric AS m_lon
    FROM typed WHERE rl IS NOT NULL AND ro IS NOT NULL AND abs(rl) > 1 AND abs(ro) > 1
    GROUP BY restaurant_id
),
repaired AS (
    SELECT s.*, m.m_lat, m.m_lon, ls.med_lag_min,
           (s.rl IS NOT NULL AND s.ro IS NOT NULL AND abs(s.rl) > 1 AND abs(s.ro) > 1) AS rest_ok
    FROM stamped s CROSS JOIN lagstat ls LEFT JOIN rest_master m USING (restaurant_id)
)
INSERT INTO stg_zomato_delivery (
    order_id, courier_id, city_code, restaurant_id, courier_age, courier_rating,
    rest_lat, rest_lon, drop_lat, drop_lon, distance_km, placed_ts, picked_up_ts, transit_minutes,
    weather, road_traffic, vehicle_condition, order_type, vehicle_type, multiple_deliveries, festival, city_type,
    f_placed_ts_imputed, f_coord_sign_fixed, f_coord_from_master, f_coord_unrecoverable, f_rating_invalid, f_age_invalid, src_row_no)
SELECT order_id, courier_id, city_code, restaurant_id,
       CASE WHEN age_raw >= 18 THEN age_raw::smallint END,                     -- Z08 couriers must be adults
       CASE WHEN rating_raw BETWEEN 1 AND 5 THEN rating_raw::numeric(3,1) END,  -- Z07 rating scale is 1-5
       CASE WHEN rest_ok THEN abs(rl) ELSE m_lat END::numeric(9,6),
       CASE WHEN rest_ok THEN abs(ro) ELSE m_lon END::numeric(9,6),
       CASE WHEN rest_ok THEN dl WHEN m_lat IS NOT NULL THEN (CASE WHEN dl >= 1 THEN dl ELSE m_lat + dl END) END::numeric(9,6),
       CASE WHEN rest_ok THEN dlo WHEN m_lon IS NOT NULL THEN (CASE WHEN dlo >= 1 THEN dlo ELSE m_lon + dlo END) END::numeric(9,6),
       fn_haversine_km(CASE WHEN rest_ok THEN abs(rl) ELSE m_lat END, CASE WHEN rest_ok THEN abs(ro) ELSE m_lon END,
                       CASE WHEN rest_ok THEN dl WHEN m_lat IS NOT NULL THEN (CASE WHEN dl >= 1 THEN dl ELSE m_lat + dl END) END,
                       CASE WHEN rest_ok THEN dlo WHEN m_lon IS NOT NULL THEN (CASE WHEN dlo >= 1 THEN dlo ELSE m_lon + dlo END) END),
       COALESCE(placed_raw, picked_adj - make_interval(mins => round(med_lag_min)::int)),
       CASE WHEN picked_adj >= COALESCE(placed_raw, picked_adj - make_interval(mins => round(med_lag_min)::int)) THEN picked_adj END,
       transit::smallint,
       COALESCE(initcap(weather), 'Unknown'),
       COALESCE(initcap(traffic), 'Unknown'),
       vcond::smallint,
       initcap(otype),
       CASE vtype WHEN 'motorcycle' THEN 'Motorbike' WHEN 'scooter' THEN 'Scooter'
                  WHEN 'electric_scooter' THEN 'EV Scooter' WHEN 'bicycle' THEN 'Bicycle' ELSE 'Unknown' END,
       multi::smallint,
       CASE lower(fest) WHEN 'yes' THEN TRUE WHEN 'no' THEN FALSE END,
       COALESCE(CASE WHEN lower(ctype) = 'metropolitian' THEN 'Metropolitan' ELSE initcap(ctype) END, 'Unknown'),
       (placed_raw IS NULL),
       (rest_ok AND (rl < 0 OR ro < 0)),
       (NOT rest_ok AND m_lat IS NOT NULL),
       (NOT rest_ok AND m_lat IS NULL),
       (rating_raw IS NOT NULL AND rating_raw NOT BETWEEN 1 AND 5),
       (age_raw IS NOT NULL AND age_raw < 18),
       src_row_no
FROM repaired
WHERE od IS NOT NULL AND (placed_raw IS NOT NULL OR picked_adj IS NOT NULL)      -- Z09 reject rows with no usable date/time
  AND transit BETWEEN 1 AND 300                                                  -- Z10 reject impossible durations
  AND courier_id ~ '^[A-Z]+RES\d+DEL\d+$';                                        -- Z11 courier id must follow CITYRESnnDELnn

-- ---------------------------------------------------------------- public dataset 2: Indian Food 101 (menu catalogue)
TRUNCATE stg_indian_food;
INSERT INTO stg_indian_food (dish_name, diet, flavor_profile, course, state, region, cuisine_type, prep_time_min, cook_time_min)
SELECT DISTINCT ON (lower(btrim(name)))
       initcap(btrim(name)),
       CASE lower(btrim(diet)) WHEN 'vegetarian' THEN 'Veg' WHEN 'non vegetarian' THEN 'Non-Veg' ELSE 'Veg' END,
       COALESCE(initcap(fn_clean_txt(NULLIF(btrim(flavor_profile),'-1'))), 'Unknown'),
       CASE lower(btrim(course)) WHEN 'main course' THEN 'Main' WHEN 'dessert' THEN 'Dessert'
                                 WHEN 'snack' THEN 'Starter' WHEN 'starter' THEN 'Starter' ELSE 'Main' END,
       COALESCE(NULLIF(btrim(state),'-1'), 'Unknown'),
       COALESCE(NULLIF(btrim(region),'-1'), 'Unknown'),
       CASE
         WHEN btrim(state) IN ('Punjab','Haryana','Delhi') THEN 'Punjabi'
         WHEN btrim(state) = 'Gujarat' THEN 'Gujarati'
         WHEN btrim(state) = 'Maharashtra' THEN 'Maharashtrian'
         WHEN btrim(state) IN ('Tamil Nadu','Kerala','Karnataka','Andhra Pradesh','Telangana') THEN 'South Indian'
         WHEN btrim(state) IN ('West Bengal','Odisha','Assam','Tripura','Manipur','Bihar','Jharkhand') THEN 'Bengali & East Indian'
         WHEN btrim(state) = 'Rajasthan' THEN 'Rajasthani'
         WHEN btrim(state) IN ('Uttar Pradesh','Madhya Pradesh','Uttarakhand') THEN 'Mughlai & Awadhi'
         ELSE 'Regional Indian' END,
       NULLIF(fn_to_num(NULLIF(btrim(prep_time),'-1')), NULL)::smallint,
       NULLIF(fn_to_num(NULLIF(btrim(cook_time),'-1')), NULL)::smallint
FROM raw_indian_food
WHERE fn_clean_txt(name) IS NOT NULL
ORDER BY lower(btrim(name)), src_row_no;
