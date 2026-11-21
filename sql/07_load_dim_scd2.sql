-- =====================================================================
-- 07_load_dim_scd2.sql  -  SCD TYPE 2 for dim_customer and dim_restaurant
-- The functions are called once per monthly snapshot (oldest first) by run_pipeline.py:
--     SELECT project_dw.load_dim_customer_scd2(DATE '2022-03-01', 1);
-- Steps:  1) Type 1 attributes are overwritten on every version
--         2) a CHANGED tracked attribute expires the current row (end date = snapshot - 1, is_current = FALSE)
--         3) a new version row is inserted (start = snapshot date, version_number + 1)
--         4) brand-new business keys get version 1 (start = LEAST(snapshot date, signup/onboarding date))
-- Facts later pick the version whose [effective_start, effective_end] contains the order date (BR-03, BR-09).
-- =====================================================================
SET search_path = project_dw;

CREATE OR REPLACE FUNCTION load_dim_customer_scd2(p_snap DATE, p_batch INT) RETURNS VOID AS $$
DECLARE n_exp INT; n_ins INT; n_new INT;
BEGIN
    CREATE TEMP TABLE _src ON COMMIT DROP AS
    SELECT s.*, CASE WHEN months < 4 THEN '0-3m' WHEN months < 13 THEN '4-12m' WHEN months < 25 THEN '13-24m' ELSE '25m+' END AS tenure_band
    FROM (SELECT c.*, (extract(year FROM age(p_snap, signup_date)) * 12 + extract(month FROM age(p_snap, signup_date)))::int AS months
          FROM project_staging.stg_customer_snapshot c WHERE snapshot_date = p_snap) s;

    -- 1) Type 1 attributes (overwrite on all versions of the member)
    UPDATE dim_customer d SET customer_name = s.customer_name, gender = s.gender, age_band = s.age_band, signup_date = s.signup_date,
           acquisition_channel = s.acquisition_channel, tenure_band = s.tenure_band
    FROM _src s WHERE d.customer_id = s.customer_id AND d.customer_key > 0;

    -- 2) expire current versions whose Type 2 attributes changed
    WITH chg AS (
        SELECT d.customer_key FROM dim_customer d JOIN _src s ON s.customer_id = d.customer_id
        WHERE d.is_current AND ROW(d.customer_segment, d.loyalty_tier, d.is_subscriber, d.home_zone, d.home_city)
              IS DISTINCT FROM ROW(s.customer_segment, s.loyalty_tier, s.is_subscriber, s.home_zone, s.home_city))
    UPDATE dim_customer d SET effective_end_date = p_snap - 1, is_current = FALSE FROM chg WHERE d.customer_key = chg.customer_key;
    GET DIAGNOSTICS n_exp = ROW_COUNT;

    -- 3) + 4) insert new versions / new members (members without a current row)
    INSERT INTO dim_customer (customer_id, customer_name, gender, age_band, signup_date, tenure_band, acquisition_channel, customer_segment, loyalty_tier,
                              is_subscriber, home_zone, home_city, effective_start_date, effective_end_date, is_current, version_number, etl_batch_id)
    SELECT s.customer_id, s.customer_name, s.gender, s.age_band, s.signup_date, s.tenure_band, s.acquisition_channel, s.customer_segment, s.loyalty_tier,
           s.is_subscriber, s.home_zone, s.home_city,
           CASE WHEN pv.max_v IS NULL THEN LEAST(p_snap, s.signup_date) ELSE p_snap END, DATE '9999-12-31', TRUE, COALESCE(pv.max_v, 0) + 1, p_batch
    FROM _src s LEFT JOIN (SELECT customer_id, max(version_number) AS max_v FROM dim_customer GROUP BY customer_id) pv ON pv.customer_id = s.customer_id
    WHERE NOT EXISTS (SELECT 1 FROM dim_customer d WHERE d.customer_id = s.customer_id AND d.is_current);
    GET DIAGNOSTICS n_ins = ROW_COUNT;
    SELECT count(*) INTO n_new FROM dim_customer WHERE version_number = 1 AND etl_batch_id = p_batch AND effective_start_date = LEAST(p_snap, signup_date) AND customer_id IN (SELECT customer_id FROM _src);
    INSERT INTO etl_scd_log (dim_name, snapshot_date, versions_expired, versions_inserted, brand_new_members) VALUES ('dim_customer', p_snap, n_exp, n_ins, n_new);
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION load_dim_restaurant_scd2(p_snap DATE, p_batch INT) RETURNS VOID AS $$
DECLARE n_exp INT; n_ins INT; n_new INT;
BEGIN
    CREATE TEMP TABLE _rsrc ON COMMIT DROP AS SELECT * FROM project_staging.stg_restaurant_snapshot WHERE snapshot_date = p_snap;

    UPDATE dim_restaurant d SET restaurant_name = s.restaurant_name, brand_name = s.brand_name, chain_type = s.chain_type, primary_cuisine = s.primary_cuisine,
           secondary_cuisine = s.secondary_cuisine, is_cloud_kitchen = s.is_cloud_kitchen, onboarding_date = s.onboarding_date, city = s.city, zone_name = s.zone_name
    FROM _rsrc s WHERE d.restaurant_id = s.restaurant_id AND d.restaurant_key > 0;

    WITH chg AS (
        SELECT d.restaurant_key FROM dim_restaurant d JOIN _rsrc s ON s.restaurant_id = d.restaurant_id
        WHERE d.is_current AND ROW(d.price_tier, d.partner_tier, d.commission_rate_pct, d.contract_status)
              IS DISTINCT FROM ROW(s.price_tier, s.partner_tier, s.commission_rate_pct, s.contract_status))
    UPDATE dim_restaurant d SET effective_end_date = p_snap - 1, is_current = FALSE FROM chg WHERE d.restaurant_key = chg.restaurant_key;
    GET DIAGNOSTICS n_exp = ROW_COUNT;

    INSERT INTO dim_restaurant (restaurant_id, restaurant_name, brand_name, chain_type, primary_cuisine, secondary_cuisine, is_cloud_kitchen, onboarding_date, city,
                                zone_name, price_tier, partner_tier, commission_rate_pct, contract_status, effective_start_date, effective_end_date, is_current,
                                version_number, etl_batch_id)
    SELECT s.restaurant_id, s.restaurant_name, s.brand_name, s.chain_type, s.primary_cuisine, s.secondary_cuisine, s.is_cloud_kitchen, s.onboarding_date, s.city,
           s.zone_name, s.price_tier, s.partner_tier, s.commission_rate_pct, s.contract_status,
           CASE WHEN pv.max_v IS NULL THEN LEAST(p_snap, s.onboarding_date) ELSE p_snap END, DATE '9999-12-31', TRUE, COALESCE(pv.max_v, 0) + 1, p_batch
    FROM _rsrc s LEFT JOIN (SELECT restaurant_id, max(version_number) AS max_v FROM dim_restaurant GROUP BY restaurant_id) pv ON pv.restaurant_id = s.restaurant_id
    WHERE NOT EXISTS (SELECT 1 FROM dim_restaurant d WHERE d.restaurant_id = s.restaurant_id AND d.is_current);
    GET DIAGNOSTICS n_ins = ROW_COUNT;
    SELECT count(*) INTO n_new FROM dim_restaurant WHERE version_number = 1 AND etl_batch_id = p_batch AND restaurant_id IN (SELECT restaurant_id FROM _rsrc);
    INSERT INTO etl_scd_log (dim_name, snapshot_date, versions_expired, versions_inserted, brand_new_members) VALUES ('dim_restaurant', p_snap, n_exp, n_ins, n_new);
END $$ LANGUAGE plpgsql;

-- unknown members (key -1) so a fact row never has a NULL / orphan foreign key
INSERT INTO dim_customer (customer_key, customer_id, customer_name, gender, age_band, signup_date, tenure_band, acquisition_channel, customer_segment, loyalty_tier,
                          is_subscriber, home_zone, home_city, effective_start_date, effective_end_date, is_current, version_number, etl_batch_id)
OVERRIDING SYSTEM VALUE VALUES (-1, 'GUEST', 'Guest / unknown customer', 'Unknown', 'Unknown', DATE '1900-01-01', 'Unknown', 'Unknown', 'Unknown', 'None', FALSE,
        'Unknown', 'Unknown', DATE '1900-01-01', DATE '9999-12-31', TRUE, 1, {{BATCH_ID}}) ON CONFLICT DO NOTHING;
INSERT INTO dim_restaurant (restaurant_key, restaurant_id, restaurant_name, brand_name, chain_type, primary_cuisine, secondary_cuisine, is_cloud_kitchen, onboarding_date,
                            city, zone_name, price_tier, partner_tier, commission_rate_pct, contract_status, effective_start_date, effective_end_date, is_current, version_number, etl_batch_id)
OVERRIDING SYSTEM VALUE VALUES (-1, 'UNKNOWN', 'Unknown restaurant', 'Unknown', 'Unknown', 'Unknown', 'Unknown', FALSE, DATE '1900-01-01', 'Unknown', 'Unknown',
        'Unknown', 'Unknown', 0, 'Unknown', DATE '1900-01-01', DATE '9999-12-31', TRUE, 1, {{BATCH_ID}}) ON CONFLICT DO NOTHING;
