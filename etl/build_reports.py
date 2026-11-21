"""Builds the two Phase 2 PDF deliverables from the logs the pipeline writes into PostgreSQL:
   reports/Data_Cleaning_Report.pdf   (project_staging.etl_cleaning_log + stg/raw profiling)
   reports/Data_Quality_Report.pdf    (project_dw.dq_result, SCD log, row counts)"""
import sys
from datetime import date
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import cm
from reportlab.platypus import Image, PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from config import REPORT_DIR
from etl.common import connect

NAVY, GREY = colors.HexColor("#1F3A5F"), colors.HexColor("#F2F4F7")
SS = getSampleStyleSheet()
H1 = ParagraphStyle("H1", parent=SS["Heading1"], textColor=NAVY, fontSize=17, spaceAfter=8)
H2 = ParagraphStyle("H2", parent=SS["Heading2"], textColor=NAVY, fontSize=12.5, spaceBefore=10, spaceAfter=5)
BODY = ParagraphStyle("B", parent=SS["BodyText"], fontSize=9.2, leading=12.5)
CELL = ParagraphStyle("C", parent=BODY, fontSize=7.8, leading=9.6)
CELLB = ParagraphStyle("CB", parent=CELL, fontName="Helvetica-Bold", textColor=colors.white)
TITLE = ParagraphStyle("T", parent=SS["Title"], textColor=NAVY, fontSize=24, leading=28)
AUTHORS = "Eman Faisal (24L-2514) &nbsp;&nbsp;|&nbsp;&nbsp; Mahnoor Fatima (24L-2533)"


def tbl(rows, widths, header=True, zebra=True):
    data = [[Paragraph(str(c), CELLB if (header and i == 0) else CELL) for c in r] for i, r in enumerate(rows)]
    t = Table(data, colWidths=widths, repeatRows=1 if header else 0)
    st = [("GRID", (0, 0), (-1, -1), 0.25, colors.HexColor("#C9CED6")), ("VALIGN", (0, 0), (-1, -1), "TOP"),
          ("TOPPADDING", (0, 0), (-1, -1), 2.5), ("BOTTOMPADDING", (0, 0), (-1, -1), 2.5)]
    if header:
        st.append(("BACKGROUND", (0, 0), (-1, 0), NAVY))
    if zebra:
        st += [("BACKGROUND", (0, i), (-1, i), GREY) for i in range(2, len(rows), 2)]
    t.setStyle(TableStyle(st))
    return t


def cover(title, subtitle):
    return [Spacer(1, 3.5 * cm), Paragraph(title, TITLE), Paragraph(subtitle, ParagraphStyle("s", parent=BODY, fontSize=12, alignment=1)),
            Spacer(1, 1 * cm),
            tbl([["Course / Phase", "DL3004 Final Project - Phase 2: Physical Data Warehouse Implementation & ETL Pipeline"],
                 ["Project", "Food Delivery & Restaurant Performance Analytics Data Warehouse (fictional company: SwiftBite Delivery)"],
                 ["Prepared by", AUTHORS], ["Date", date.today().strftime("%d %B %Y")],
                 ["Platform", "PostgreSQL - schemas project_staging / project_dw / project_reporting"]], [4 * cm, 12.5 * cm], header=False, zebra=False),
            PageBreak()]


def q(conn, sql):
    return pd.read_sql(sql, conn)


def fmt(n):
    try:
        return f"{int(n):,}"
    except Exception:
        return str(n)


def build():
    REPORT_DIR.mkdir(exist_ok=True)
    conn = connect()
    build_cleaning(conn)
    build_quality(conn)
    conn.close()
    print("  reports written to", REPORT_DIR)


# ------------------------------------------------------------------------------------------------ cleaning report
def build_cleaning(conn):
    log = q(conn, "SELECT source_table, rule_id, rule_category, rule_text, rows_in, rows_affected FROM project_staging.etl_cleaning_log ORDER BY source_table, rule_id")
    raw_n = q(conn, "SELECT (SELECT count(*) FROM project_staging.raw_zomato_delivery) a, (SELECT count(*) FROM project_staging.stg_zomato_delivery) b, "
                    "(SELECT count(*) FROM project_staging.raw_indian_food) c, (SELECT count(*) FROM project_staging.stg_indian_food) d").iloc[0]
    story = cover("Data Cleaning Report", "Staging layer: raw files to clean, typed tables")
    story += [Paragraph("1. Purpose and approach", H1),
              Paragraph("The staging schema keeps every source file twice: an untouched <b>raw_*</b> copy (all columns TEXT) and a cleaned, typed <b>stg_*</b> table that feeds the warehouse loads. "
                        "Cleaning follows the Phase 2 brief: remove duplicates, handle NULL values, standardise text and convert data types. Every rule is implemented in SQL "
                        "(<i>02_staging_clean_public.sql</i>, <i>03_staging_clean_extracts.sql</i>) and its effect is counted in <i>project_staging.etl_cleaning_log</i>, which is the source of every number below.", BODY),
              Paragraph("2. Data sources (what is real and what is simulated)", H2),
              tbl([["Source", "Origin", "Rows (raw to clean)", "Used for"],
                   ["Kaggle <i>Food Delivery Dataset</i> (Zomato-style orders)", "PUBLIC (Option A), real", f"{fmt(raw_n.a)} to {fmt(raw_n.b)}",
                    "Real order ids, couriers, restaurants (from courier id), coordinates, order / pick-up times, transit minutes, order type, vehicle type, city"],
                   ["Kaggle <i>Indian Food 101</i>", "PUBLIC (Option A), real", f"{fmt(raw_n.c)} to {fmt(raw_n.d)}", "dim_menu_item (dish, diet, flavour, course, cuisine)"],
                   ["CRM, RPP, DISP, OMS, MKT extracts", "SIMULATED (seeded Python, built on the real orders)",
                    "see section 4", "Customers, order lines, payments, channels, promotions, cancellations, restaurant attributes and availability log. No public dataset contains these."]],
                  [4.2 * cm, 3.4 * cm, 3 * cm, 6 * cm]),
              Spacer(1, 4),
              Paragraph("The public files provide the real operational backbone of the warehouse. Attributes that no public dataset carries were generated with a fixed random seed "
                        "(<i>etl/generate_source_extracts.py</i>) so the run is reproducible; the simulated order milestones (accepted / ready) are placed inside the real order-to-pick-up window.", BODY),
              Paragraph("3. Cleaning rules applied to the public delivery dataset", H1)]
    for src, title in (("zomato_delivery", "3.1 Kaggle Food Delivery Dataset"), ("indian_food_101", "3.2 Indian Food 101")):
        d = log[log.source_table == src]
        story += [Paragraph(title, H2), tbl([["Rule", "Category", "What was done", "Rows affected"]] +
                                              [[r.rule_id, r.rule_category, r.rule_text, fmt(r.rows_affected)] for r in d.itertuples()], [1.2 * cm, 3 * cm, 10 * cm, 2.4 * cm])]
    story += [Paragraph("Key assumption: meaning of <i>Time_taken (min)</i>", H2),
              Paragraph("The file documents the order time and the pick-up time but not what Time_taken measures. Rule Z17 counts orders whose order-to-pick-up lag is longer than Time_taken; "
                        "if Time_taken were order-to-delivery these orders would be delivered <i>before</i> being picked up. Because that is impossible, Time_taken is treated as <b>pick-up to delivery (transit) time</b>, "
                        "so total_delivery_minutes = lag + Time_taken. The warehouse stores it as transit_lag_minutes and the data-quality report reconciles it back to the public file.", BODY),
              Paragraph("4. Cleaning rules applied to the source-system extracts", H1)]
    d = log[~log.source_table.isin(["zomato_delivery", "indian_food_101"])]
    story += [tbl([["Source", "Rule", "Category", "What was done", "Rows in", "Rows affected"]] +
                  [[r.source_table, r.rule_id, r.rule_category, r.rule_text, fmt(r.rows_in), fmt(r.rows_affected)] for r in d.itertuples()],
                  [3.0 * cm, 1.1 * cm, 2.6 * cm, 6.4 * cm, 1.7 * cm, 1.9 * cm]),
              Spacer(1, 4),
              Paragraph("The CRM extract contains a small, deliberately injected set of defects (stray spaces and mixed case in city names, blank gender, re-sent rows) so that the standardisation and "
                        "de-duplication rules (C01-C03) have real work to do. They are documented here for transparency.", BODY)]
    # chart
    pub = log[log.source_table == "zomato_delivery"].copy()
    pub = pub[pub.rule_id.isin(["Z02", "Z04", "Z05", "Z06", "Z07", "Z08", "Z09", "Z10", "Z11", "Z13"])]
    fig, ax = plt.subplots(figsize=(7.2, 3.3))
    ax.barh(pub.rule_id[::-1], pub.rows_affected[::-1], color="#1F3A5F")
    ax.set_xlabel("rows affected"); ax.set_title("Public delivery dataset: rows touched per cleaning rule")
    for i, v in enumerate(pub.rows_affected[::-1]):
        ax.text(v, i, f" {int(v):,}", va="center", fontsize=7)
    plt.tight_layout(); png = REPORT_DIR / "cleaning_rules.png"; plt.savefig(png, dpi=160); plt.close()
    story += [Paragraph("5. Summary", H1), Image(str(png), width=15.5 * cm, height=7.1 * cm),
              Paragraph("Result: no order was lost to cleaning except rows rejected by rule Z16 (see table). Repairs are flagged in the stg_zomato_delivery columns <i>f_*</i>, so every correction is traceable. "
                        "Where a value cannot be repaired honestly (restaurants whose coordinates are all zero) the location is left NULL and the warehouse maps it to the Unknown member (-1) instead of inventing a position.", BODY)]
    SimpleDocTemplate(str(REPORT_DIR / "Data_Cleaning_Report.pdf"), pagesize=A4, leftMargin=2 * cm, rightMargin=2 * cm, topMargin=1.8 * cm, bottomMargin=1.8 * cm,
                      title="Data Cleaning Report", author="Eman Faisal, Mahnoor Fatima").build(story)


# ------------------------------------------------------------------------------------------------ quality report
def build_quality(conn):
    dq = q(conn, "SELECT category, check_name, table_name, rows_checked, rows_failed, status FROM project_dw.dq_result ORDER BY check_id")
    counts = dq[dq.category == "Row count (info)"][["table_name", "rows_checked"]]
    scd = q(conn, "SELECT dim_name, snapshot_date, versions_expired, versions_inserted FROM project_dw.etl_scd_log ORDER BY dim_name, snapshot_date")
    kpi = q(conn, "SELECT kpi, value FROM project_reporting.kpi_summary")
    main = dq[~dq.category.str.contains("info", case=False)]
    n_pass, n_fail = int((main.status == "PASS").sum()), int((main.status == "FAIL").sum())
    story = cover("Data Quality Report", "Validation of the loaded data warehouse")
    story += [Paragraph("1. Summary", H1),
              Paragraph(f"<b>{len(main)}</b> automated checks were run by <i>sql/12_data_quality_checks.sql</i> after the load: <b>{n_pass} passed</b> and <b>{n_fail} failed</b>. "
                        "Results are stored in <i>project_dw.dq_result</i>. Informational metrics (INFO) report volumes and Unknown-member usage and do not pass or fail.", BODY)]
    cat = main.groupby(["category", "status"]).size().unstack(fill_value=0)
    for c in ("PASS", "FAIL"):
        if c not in cat:
            cat[c] = 0
    story += [tbl([["Category", "Checks", "Passed", "Failed"]] + [[i, int(r.PASS + r.FAIL), int(r.PASS), int(r.FAIL)] for i, r in cat.iterrows()], [7 * cm, 3 * cm, 3 * cm, 3 * cm])]
    fig, ax = plt.subplots(figsize=(6.5, 2.8))
    ax.bar(cat.index, cat.PASS, color="#2E7D32", label="PASS"); ax.bar(cat.index, cat.FAIL, bottom=cat.PASS, color="#C62828", label="FAIL")
    ax.legend(); ax.set_title("Checks per category"); plt.xticks(fontsize=7); plt.tight_layout()
    png = REPORT_DIR / "dq_summary.png"; plt.savefig(png, dpi=160); plt.close()
    story += [Spacer(1, 6), Image(str(png), width=14 * cm, height=6 * cm), Paragraph("2. Warehouse volumes", H2),
              tbl([["Table", "Rows"]] + [[r.table_name, fmt(r.rows_checked)] for r in counts.itertuples()], [8 * cm, 3 * cm]),
              Paragraph("The Phase 2 brief asks for 100+ dimension records and 10,000+ fact records. dim_customer, dim_restaurant, dim_menu_item, dim_courier, dim_location, dim_promotion and dim_date each exceed 100 rows; "
                        "all four fact tables exceed 10,000 rows. The small lookup dimensions (channel, payment method, order status, cancellation reason, time of day) are inherently small domains defined in Phase 1.", BODY),
              PageBreak(), Paragraph("3. Detailed results", H1)]
    for c in main.category.unique():
        d = main[main.category == c]
        story += [Paragraph(c, H2), tbl([["Check", "Table", "Rows checked", "Rows failed", "Result"]] +
                                         [[r.check_name, r.table_name, fmt(r.rows_checked), fmt(r.rows_failed), f"<b>{r.status}</b>"] for r in d.itertuples()],
                                         [8.6 * cm, 3 * cm, 2 * cm, 1.8 * cm, 1.4 * cm])]
    info = dq[dq.category.str.contains("info", case=False) & (dq.category != "Row count (info)")]
    story += [Paragraph("4. Informational metrics", H1),
              Paragraph("Unknown-member usage shows where a business key could not be matched or was legitimately absent (guest customers, orders never assigned to a courier, "
                        "unrecoverable restaurant coordinates, milestones not reached). These rows are kept and mapped to -1 so that no fact row has a NULL foreign key.", BODY),
              tbl([["Metric", "Table", "Rows", "Of"]] + [[r.check_name, r.table_name, fmt(r.rows_failed), fmt(r.rows_checked)] for r in info.itertuples()], [9 * cm, 3.6 * cm, 2 * cm, 2 * cm]),
              Paragraph("5. Slowly changing dimension (Type 2) load log", H1),
              tbl([["Dimension", "Snapshot", "Versions expired", "Versions inserted"]] + [[r.dim_name, str(r.snapshot_date), fmt(r.versions_expired), fmt(r.versions_inserted)] for r in scd.itertuples()],
                  [5 * cm, 3.5 * cm, 3.5 * cm, 3.5 * cm]),
              Paragraph("6. KPI sanity values from the reporting layer", H1),
              tbl([["KPI", "Value"]] + [[r.kpi, f"{float(r.value):,.2f}"] for r in kpi.itertuples()], [8 * cm, 4 * cm])]
    SimpleDocTemplate(str(REPORT_DIR / "Data_Quality_Report.pdf"), pagesize=A4, leftMargin=2 * cm, rightMargin=2 * cm, topMargin=1.8 * cm, bottomMargin=1.8 * cm,
                      title="Data Quality Report", author="Eman Faisal, Mahnoor Fatima").build(story)


if __name__ == "__main__":
    build()
