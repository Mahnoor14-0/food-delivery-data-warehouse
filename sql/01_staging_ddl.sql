-- =====================================================================
-- 01_staging_ddl.sql  -  STAGING SCHEMA (project_staging)
-- Two tiers per source file:
--   raw_*  : exact copy of the file, every column TEXT (lossless landing)
--   stg_*  : cleaned + typed (duplicates removed, NULLs handled, text
--            standardised, data types converted)  -> input to the DW loads
-- plus control tables for batches and the cleaning log.
-- =====================================================================
SET search_path = project_staging;

-- ---------------------------------------------------------------- control
CREATE TABLE etl_batch (
    batch_id     INT PRIMARY KEY,
    batch_label  VARCHAR(60)  NOT NULL,
    started_at   TIMESTAMP    NOT NULL DEFAULT now(),
    finished_at  TIMESTAMP,
    status       VARCHAR(12)  NOT NULL DEFAULT 'RUNNING'
);

CREATE TABLE etl_cleaning_log (
    log_id        SERIAL PRIMARY KEY,
    batch_id      INT,
    source_table  VARCHAR(60)  NOT NULL,
    rule_id       VARCHAR(12)  NOT NULL,
    rule_category VARCHAR(30)  NOT NULL,      -- Duplicates | NULL handling | Text standardisation | Type conversion | Validity | Derivation
    rule_text     TEXT         NOT NULL,
    rows_in       BIGINT,
    rows_affected BIGINT       NOT NULL,
    logged_at     TIMESTAMP    NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- RAW tier (all TEXT)
-- Public dataset 1: Kaggle "Food Delivery Dataset" (Zomato-style, ~45.6k orders)
CREATE TABLE raw_zomato_delivery (
    src_row_no INT GENERATED ALWAYS AS IDENTITY,
    id TEXT, delivery_person_id TEXT, delivery_person_age TEXT, delivery_person_ratings TEXT,
    restaurant_latitude TEXT, restaurant_longitude TEXT,
    delivery_location_latitude TEXT, delivery_location_longitude TEXT,
    order_date TEXT, time_orderd TEXT, time_order_picked TEXT,
    weather_conditions TEXT, road_traffic_density TEXT, vehicle_condition TEXT,
    type_of_order TEXT, type_of_vehicle TEXT, multiple_deliveries TEXT, festival TEXT,
    city TEXT, time_taken_min TEXT
);
-- Public dataset 2: Kaggle "Indian Food 101" (255 dishes)
CREATE TABLE raw_indian_food (
    src_row_no INT GENERATED ALWAYS AS IDENTITY,
    name TEXT, ingredients TEXT, diet TEXT, prep_time TEXT, cook_time TEXT,
    flavor_profile TEXT, course TEXT, state TEXT, region TEXT
);
-- Reference / master files
CREATE TABLE raw_ref_order_channel (channel_code TEXT, channel_name TEXT, platform_type TEXT, is_self_service TEXT);
CREATE TABLE raw_ref_payment_method (payment_method_code TEXT, payment_method_name TEXT, payment_type TEXT, is_prepaid TEXT, is_online_payment TEXT);
CREATE TABLE raw_ref_order_status (order_status_code TEXT, order_status_name TEXT, status_group TEXT, is_final_status TEXT, counts_as_revenue TEXT);
CREATE TABLE raw_ref_cancellation_reason (reason_code TEXT, reason_name TEXT, reason_category TEXT, cancelled_by TEXT, is_preventable TEXT);
CREATE TABLE raw_ref_city_master (city_code TEXT, city_name TEXT, region TEXT, country TEXT);
CREATE TABLE raw_ref_holiday (holiday_date TEXT, holiday_name TEXT);
-- Source-system extracts (CRM / RPP / DISP / OMS / MKT)
CREATE TABLE raw_crm_customer_snapshot (
    snapshot_date TEXT, customer_id TEXT, full_name TEXT, gender TEXT, dob TEXT, signup_date TEXT,
    acquisition_channel TEXT, customer_segment TEXT, loyalty_tier TEXT, is_subscriber TEXT,
    home_zone TEXT, home_city TEXT);
CREATE TABLE raw_rpp_restaurant_snapshot (
    snapshot_date TEXT, restaurant_id TEXT, restaurant_name TEXT, brand_name TEXT, chain_type TEXT,
    primary_cuisine TEXT, secondary_cuisine TEXT, is_cloud_kitchen TEXT, onboarding_date TEXT,
    city TEXT, zone_name TEXT, price_tier TEXT, partner_tier TEXT, commission_rate_pct TEXT, contract_status TEXT);
CREATE TABLE raw_rpp_menu_item (
    menu_item_id TEXT, restaurant_id TEXT, item_name TEXT, item_category TEXT, cuisine_type TEXT,
    dietary_type TEXT, spice_level TEXT, is_combo_meal TEXT, list_price TEXT, is_active TEXT);
CREATE TABLE raw_disp_courier (
    courier_id TEXT, courier_name TEXT, vehicle_type TEXT, employment_type TEXT,
    hire_date TEXT, base_city TEXT, courier_status TEXT);
CREATE TABLE raw_oms_zone_master (
    zone_id TEXT, zone_name TEXT, zone_type TEXT, service_tier TEXT, city TEXT, region TEXT,
    country TEXT, centroid_latitude TEXT, centroid_longitude TEXT);
CREATE TABLE raw_oms_order (
    batch_id TEXT, order_id TEXT, customer_id TEXT, restaurant_id TEXT, courier_id TEXT,
    pickup_zone_id TEXT, dropoff_zone_id TEXT, channel_code TEXT, payment_method_code TEXT,
    order_status_code TEXT, cancellation_reason_code TEXT, promotion_id TEXT,
    placed_at TEXT, accepted_at TEXT, ready_at TEXT, picked_up_at TEXT, closed_at TEXT,
    items_count TEXT, order_subtotal TEXT, order_discount TEXT, delivery_fee TEXT, tip TEXT,
    refund TEXT, delivery_distance_km TEXT, promised_delivery_minutes TEXT, customer_rating TEXT);
CREATE TABLE raw_oms_order_line (order_id TEXT, line_no TEXT, menu_item_id TEXT, qty TEXT, unit_price TEXT);
CREATE TABLE raw_mkt_promotion (
    promotion_id TEXT, promotion_code TEXT, promotion_name TEXT, campaign_name TEXT, promotion_type TEXT,
    discount_value TEXT, discount_unit TEXT, funded_by TEXT, target_segment TEXT, min_order_amount TEXT,
    start_date TEXT, end_date TEXT);
CREATE TABLE raw_mkt_promotion_target (promotion_id TEXT, customer_id TEXT, issued_at TEXT, expires_at TEXT);
CREATE TABLE raw_rpp_availability_log (
    log_date TEXT, restaurant_id TEXT, scheduled_open_minutes TEXT, online_minutes TEXT,
    active_menu_items TEXT, unavailable_menu_items TEXT, open_complaints TEXT);

-- ---------------------------------------------------------------- STG tier (cleaned + typed)
CREATE TABLE stg_zomato_delivery (
    order_id            VARCHAR(20) PRIMARY KEY,
    courier_id          VARCHAR(20) NOT NULL,
    city_code           VARCHAR(10) NOT NULL,
    restaurant_id       VARCHAR(20) NOT NULL,          -- derived: <city_code>-R<nn> from courier id
    courier_age         SMALLINT,
    courier_rating      NUMERIC(3,1),
    rest_lat            NUMERIC(9,6),
    rest_lon            NUMERIC(9,6),
    drop_lat            NUMERIC(9,6),
    drop_lon            NUMERIC(9,6),
    distance_km         NUMERIC(6,2),
    placed_ts           TIMESTAMP NOT NULL,
    picked_up_ts        TIMESTAMP,
    transit_minutes     SMALLINT  NOT NULL,            -- Time_taken (min) = pick-up -> delivery
    weather             VARCHAR(20),
    road_traffic        VARCHAR(10),
    vehicle_condition   SMALLINT,
    order_type          VARCHAR(10),
    vehicle_type        VARCHAR(15),
    multiple_deliveries SMALLINT,
    festival            BOOLEAN,
    city_type           VARCHAR(15),
    f_placed_ts_imputed   BOOLEAN NOT NULL DEFAULT FALSE,
    f_coord_sign_fixed    BOOLEAN NOT NULL DEFAULT FALSE,
    f_coord_from_master   BOOLEAN NOT NULL DEFAULT FALSE,
    f_coord_unrecoverable BOOLEAN NOT NULL DEFAULT FALSE,
    f_rating_invalid      BOOLEAN NOT NULL DEFAULT FALSE,
    f_age_invalid         BOOLEAN NOT NULL DEFAULT FALSE,
    src_row_no          INT NOT NULL
);

CREATE TABLE stg_indian_food (
    dish_name VARCHAR(120) PRIMARY KEY, diet VARCHAR(15), flavor_profile VARCHAR(15),
    course VARCHAR(20), state VARCHAR(40), region VARCHAR(20), cuisine_type VARCHAR(30),
    prep_time_min SMALLINT, cook_time_min SMALLINT);

CREATE TABLE stg_order_channel      AS SELECT channel_code::varchar(10) channel_code, channel_name::varchar(30) channel_name, platform_type::varchar(15) platform_type, (is_self_service='TRUE') is_self_service FROM raw_ref_order_channel WITH NO DATA;
CREATE TABLE stg_payment_method     AS SELECT payment_method_code::varchar(10) payment_method_code, payment_method_name::varchar(30) payment_method_name, payment_type::varchar(15) payment_type, (is_prepaid='TRUE') is_prepaid, (is_online_payment='TRUE') is_online_payment FROM raw_ref_payment_method WITH NO DATA;
CREATE TABLE stg_order_status       AS SELECT order_status_code::varchar(15) order_status_code, order_status_name::varchar(30) order_status_name, status_group::varchar(12) status_group, (is_final_status='TRUE') is_final_status, (counts_as_revenue='TRUE') counts_as_revenue FROM raw_ref_order_status WITH NO DATA;
CREATE TABLE stg_cancellation_reason AS SELECT reason_code::varchar(15) reason_code, reason_name::varchar(50) reason_name, reason_category::varchar(15) reason_category, cancelled_by::varchar(12) cancelled_by, (is_preventable='TRUE') is_preventable FROM raw_ref_cancellation_reason WITH NO DATA;
CREATE TABLE stg_city_master        AS SELECT city_code::varchar(10) city_code, city_name::varchar(50) city_name, region::varchar(50) region, country::varchar(50) country FROM raw_ref_city_master WITH NO DATA;
CREATE TABLE stg_holiday            AS SELECT holiday_date::date holiday_date, holiday_name::varchar(50) holiday_name FROM raw_ref_holiday WITH NO DATA;

CREATE TABLE stg_customer_snapshot (
    snapshot_date DATE NOT NULL, customer_id VARCHAR(20) NOT NULL, customer_name VARCHAR(100) NOT NULL,
    gender VARCHAR(10) NOT NULL, age_band VARCHAR(10) NOT NULL, signup_date DATE NOT NULL,
    acquisition_channel VARCHAR(20) NOT NULL, customer_segment VARCHAR(15) NOT NULL,
    loyalty_tier VARCHAR(10) NOT NULL, is_subscriber BOOLEAN NOT NULL,
    home_zone VARCHAR(50) NOT NULL, home_city VARCHAR(50) NOT NULL,
    PRIMARY KEY (snapshot_date, customer_id));

CREATE TABLE stg_restaurant_snapshot (
    snapshot_date DATE NOT NULL, restaurant_id VARCHAR(20) NOT NULL, restaurant_name VARCHAR(100) NOT NULL,
    brand_name VARCHAR(100) NOT NULL, chain_type VARCHAR(15) NOT NULL, primary_cuisine VARCHAR(30) NOT NULL,
    secondary_cuisine VARCHAR(30) NOT NULL, is_cloud_kitchen BOOLEAN NOT NULL, onboarding_date DATE NOT NULL,
    city VARCHAR(50) NOT NULL, zone_name VARCHAR(50) NOT NULL, price_tier VARCHAR(10) NOT NULL,
    partner_tier VARCHAR(10) NOT NULL, commission_rate_pct NUMERIC(5,2) NOT NULL, contract_status VARCHAR(12) NOT NULL,
    PRIMARY KEY (snapshot_date, restaurant_id));

CREATE TABLE stg_menu_item (
    menu_item_id VARCHAR(20) PRIMARY KEY, owner_restaurant_id VARCHAR(20) NOT NULL, item_name VARCHAR(120) NOT NULL,
    item_category VARCHAR(20) NOT NULL, cuisine_type VARCHAR(30) NOT NULL, dietary_type VARCHAR(10) NOT NULL,
    spice_level VARCHAR(10) NOT NULL, is_combo_meal BOOLEAN NOT NULL, list_price NUMERIC(10,2) NOT NULL, is_active BOOLEAN NOT NULL);

CREATE TABLE stg_courier (
    courier_id VARCHAR(20) PRIMARY KEY, courier_name VARCHAR(100) NOT NULL, vehicle_type VARCHAR(15) NOT NULL,
    employment_type VARCHAR(12) NOT NULL, hire_date DATE NOT NULL, experience_band VARCHAR(12) NOT NULL,
    base_city VARCHAR(50) NOT NULL, courier_status VARCHAR(10) NOT NULL);

CREATE TABLE stg_zone (
    zone_id VARCHAR(10) PRIMARY KEY, zone_name VARCHAR(50) NOT NULL, zone_type VARCHAR(15) NOT NULL,
    service_tier VARCHAR(10) NOT NULL, city VARCHAR(50) NOT NULL, region VARCHAR(50) NOT NULL,
    country VARCHAR(50) NOT NULL, centroid_latitude NUMERIC(9,6) NOT NULL, centroid_longitude NUMERIC(9,6) NOT NULL);

CREATE TABLE stg_order (
    batch_id INT NOT NULL, order_id VARCHAR(20) NOT NULL, customer_id VARCHAR(20), restaurant_id VARCHAR(20) NOT NULL,
    courier_id VARCHAR(20), pickup_zone_id VARCHAR(10), dropoff_zone_id VARCHAR(10),
    channel_code VARCHAR(10), payment_method_code VARCHAR(10), order_status_code VARCHAR(15) NOT NULL,
    cancellation_reason_code VARCHAR(15), promotion_id VARCHAR(20),
    placed_at TIMESTAMP NOT NULL, accepted_at TIMESTAMP, ready_at TIMESTAMP, picked_up_at TIMESTAMP, closed_at TIMESTAMP,
    items_count SMALLINT NOT NULL, order_subtotal NUMERIC(12,2) NOT NULL, order_discount NUMERIC(12,2) NOT NULL,
    delivery_fee NUMERIC(12,2) NOT NULL, tip NUMERIC(12,2) NOT NULL, refund NUMERIC(12,2) NOT NULL,
    delivery_distance_km NUMERIC(6,2), promised_delivery_minutes SMALLINT NOT NULL, customer_rating SMALLINT,
    PRIMARY KEY (batch_id, order_id));

CREATE TABLE stg_order_line (
    order_id VARCHAR(20) NOT NULL, line_no SMALLINT NOT NULL, menu_item_id VARCHAR(20) NOT NULL,
    qty INT NOT NULL, unit_price NUMERIC(10,2) NOT NULL, PRIMARY KEY (order_id, line_no));

CREATE TABLE stg_promotion (
    promotion_id VARCHAR(20) PRIMARY KEY, promotion_code VARCHAR(20) NOT NULL, promotion_name VARCHAR(100) NOT NULL,
    campaign_name VARCHAR(100) NOT NULL, promotion_type VARCHAR(20) NOT NULL, discount_value NUMERIC(10,2) NOT NULL,
    discount_unit VARCHAR(8) NOT NULL, funded_by VARCHAR(12) NOT NULL, target_segment VARCHAR(15) NOT NULL,
    min_order_amount NUMERIC(10,2) NOT NULL, start_date DATE NOT NULL, end_date DATE NOT NULL);

CREATE TABLE stg_promotion_target (
    promotion_id VARCHAR(20) NOT NULL, customer_id VARCHAR(20) NOT NULL, issued_at DATE NOT NULL, expires_at DATE NOT NULL,
    PRIMARY KEY (promotion_id, customer_id, issued_at));

CREATE TABLE stg_availability_log (
    log_date DATE NOT NULL, restaurant_id VARCHAR(20) NOT NULL, scheduled_open_minutes SMALLINT NOT NULL,
    online_minutes SMALLINT NOT NULL, active_menu_items SMALLINT NOT NULL, unavailable_menu_items SMALLINT NOT NULL,
    open_complaints SMALLINT NOT NULL, PRIMARY KEY (log_date, restaurant_id));
