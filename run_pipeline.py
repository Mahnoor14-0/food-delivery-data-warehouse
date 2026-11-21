"""
End-to-end ETL orchestrator:  Source files -> project_staging -> project_dw -> project_reporting

    python run_pipeline.py                    # full rebuild (drops + recreates the 3 schemas)
    python run_pipeline.py --reuse-extracts   # skip the simulator, reuse data/source_extracts/*.csv
    python run_pipeline.py --reports          # also build the two PDF reports at the end

Prerequisite: an empty PostgreSQL database (see README) and the connection settings in config.py / env vars.
"""
import argparse
import time
from config import RAW_DIR, REF_DIR, EXTRACT_DIR
from etl.common import connect, run_sql_file, copy_csv, scalar

BATCH_ID = 1


def step(title):
    print(f"\n=== {title}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reuse-extracts", action="store_true", help="do not regenerate the simulated source extracts")
    ap.add_argument("--reports", action="store_true", help="build the PDF reports after the load")
    args = ap.parse_args()
    t0 = time.time()
    conn = connect()

    step("1. Schemas + staging tables")
    run_sql_file(conn, "00_create_schemas.sql")
    run_sql_file(conn, "01_staging_ddl.sql")
    with conn.cursor() as cur:
        cur.execute("INSERT INTO project_staging.etl_batch (batch_id, batch_label) VALUES (%s, %s)", (BATCH_ID, "Initial full load"))
    conn.commit()

    step("2. Load PUBLIC source files -> raw tier, then clean -> stg tier")
    copy_csv(conn, "project_staging.raw_zomato_delivery", RAW_DIR / "zomato_delivery_raw.csv",
             ["id", "delivery_person_id", "delivery_person_age", "delivery_person_ratings", "restaurant_latitude", "restaurant_longitude",
              "delivery_location_latitude", "delivery_location_longitude", "order_date", "time_orderd", "time_order_picked",
              "weather_conditions", "road_traffic_density", "vehicle_condition", "type_of_order", "type_of_vehicle",
              "multiple_deliveries", "festival", "city", "time_taken_min"])
    copy_csv(conn, "project_staging.raw_indian_food", RAW_DIR / "indian_food_101.csv",
             ["name", "ingredients", "diet", "prep_time", "cook_time", "flavor_profile", "course", "state", "region"])
    run_sql_file(conn, "02_staging_clean_public.sql")

    step("3. Source-system extracts (CRM / RPP / DISP / OMS / MKT)")
    if args.reuse_extracts and (EXTRACT_DIR / "oms_order.csv").exists():
        print("  reusing existing extracts")
    else:
        from etl.generate_source_extracts import main as generate
        generate()

    step("4. Load extracts + reference files -> raw tier, clean -> stg tier, write cleaning log")
    refs = {"raw_ref_order_channel": ("ref_order_channel.csv", ["channel_code", "channel_name", "platform_type", "is_self_service"]),
            "raw_ref_payment_method": ("ref_payment_method.csv", ["payment_method_code", "payment_method_name", "payment_type", "is_prepaid", "is_online_payment"]),
            "raw_ref_order_status": ("ref_order_status.csv", ["order_status_code", "order_status_name", "status_group", "is_final_status", "counts_as_revenue"]),
            "raw_ref_cancellation_reason": ("ref_cancellation_reason.csv", ["reason_code", "reason_name", "reason_category", "cancelled_by", "is_preventable"]),
            "raw_ref_city_master": ("ref_city_master.csv", ["city_code", "city_name", "region", "country"]),
            "raw_ref_holiday": ("ref_holiday.csv", ["holiday_date", "holiday_name"])}
    for tbl, (f, cols) in refs.items():
        copy_csv(conn, f"project_staging.{tbl}", REF_DIR / f, cols)
    ext = {"raw_crm_customer_snapshot": ("crm_customer_snapshot.csv", "snapshot_date customer_id full_name gender dob signup_date acquisition_channel customer_segment loyalty_tier is_subscriber home_zone home_city"),
           "raw_rpp_restaurant_snapshot": ("rpp_restaurant_snapshot.csv", "snapshot_date restaurant_id restaurant_name brand_name chain_type primary_cuisine secondary_cuisine is_cloud_kitchen onboarding_date city zone_name price_tier partner_tier commission_rate_pct contract_status"),
           "raw_rpp_menu_item": ("rpp_menu_item.csv", "menu_item_id restaurant_id item_name item_category cuisine_type dietary_type spice_level is_combo_meal list_price is_active"),
           "raw_disp_courier": ("disp_courier.csv", "courier_id courier_name vehicle_type employment_type hire_date base_city courier_status"),
           "raw_oms_zone_master": ("oms_zone_master.csv", "zone_id zone_name zone_type service_tier city region country centroid_latitude centroid_longitude"),
           "raw_oms_order": ("oms_order.csv", "batch_id order_id customer_id restaurant_id courier_id pickup_zone_id dropoff_zone_id channel_code payment_method_code order_status_code cancellation_reason_code promotion_id placed_at accepted_at ready_at picked_up_at closed_at items_count order_subtotal order_discount delivery_fee tip refund delivery_distance_km promised_delivery_minutes customer_rating"),
           "raw_oms_order_line": ("oms_order_line.csv", "order_id line_no menu_item_id qty unit_price"),
           "raw_mkt_promotion": ("mkt_promotion.csv", "promotion_id promotion_code promotion_name campaign_name promotion_type discount_value discount_unit funded_by target_segment min_order_amount start_date end_date"),
           "raw_mkt_promotion_target": ("mkt_promotion_target.csv", "promotion_id customer_id issued_at expires_at"),
           "raw_rpp_availability_log": ("rpp_availability_log.csv", "log_date restaurant_id scheduled_open_minutes online_minutes active_menu_items unavailable_menu_items open_complaints")}
    for tbl, (f, cols) in ext.items():
        copy_csv(conn, f"project_staging.{tbl}", EXTRACT_DIR / f, cols.split())
    run_sql_file(conn, "03_staging_clean_extracts.sql")

    step("5. Data warehouse schema + dimension loads")
    run_sql_file(conn, "04_dw_ddl.sql")
    tok = {"BATCH_ID": BATCH_ID}
    run_sql_file(conn, "05_load_dim_static.sql", tok)
    run_sql_file(conn, "06_load_dim_type1.sql", tok)
    run_sql_file(conn, "07_load_dim_scd2.sql", tok)
    with conn.cursor() as cur:
        cur.execute("SELECT DISTINCT snapshot_date FROM project_staging.stg_restaurant_snapshot ORDER BY 1")
        rsnaps = [r[0] for r in cur.fetchall()]
        cur.execute("SELECT DISTINCT snapshot_date FROM project_staging.stg_customer_snapshot ORDER BY 1")
        csnaps = [r[0] for r in cur.fetchall()]
    for d in rsnaps:
        with conn.cursor() as cur:
            cur.execute("SELECT project_dw.load_dim_restaurant_scd2(%s, %s)", (d, BATCH_ID))
        conn.commit()
    for d in csnaps:
        with conn.cursor() as cur:
            cur.execute("SELECT project_dw.load_dim_customer_scd2(%s, %s)", (d, BATCH_ID))
        conn.commit()
    print(f"  SCD2 snapshots loaded: restaurants {rsnaps}, customers {csnaps}")

    step("6. Fact loads")
    run_sql_file(conn, "08_load_fact_order_item.sql", tok)
    run_sql_file(conn, "09_load_fact_delivery.sql", tok)
    run_sql_file(conn, "10_load_fact_snapshot_and_eligibility.sql", tok)

    step("7. Reporting views + data-quality validation")
    run_sql_file(conn, "11_reporting_views.sql")
    run_sql_file(conn, "12_data_quality_checks.sql")
    with conn.cursor() as cur:
        cur.execute("UPDATE project_staging.etl_batch SET finished_at = now(), status = 'SUCCESS' WHERE batch_id = %s", (BATCH_ID,))
        cur.execute("SELECT status, count(*) FROM project_dw.dq_result GROUP BY 1 ORDER BY 1")
        print("  DQ summary:", dict(cur.fetchall()))
        cur.execute("SELECT check_name, rows_failed FROM project_dw.dq_result WHERE status = 'FAIL'")
        for name, n in cur.fetchall():
            print(f"   FAIL: {name} ({n} rows)")
    conn.commit()
    if args.reports:
        step("8. PDF reports")
        from etl.build_reports import build
        build()
    print(f"\nDone in {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()
