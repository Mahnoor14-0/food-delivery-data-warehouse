"""Shared helpers: DB connection, SQL file runner, CSV -> staging COPY loader."""
import io
import time
import psycopg2
from config import DB, SQL_DIR


def connect():
    conn = psycopg2.connect(**DB)
    conn.autocommit = False
    return conn


def run_sql_file(conn, name, tokens=None, quiet=False):
    """Execute a whole .sql file. {{TOKEN}} placeholders are substituted from `tokens`."""
    text = (SQL_DIR / name).read_text(encoding="utf-8")
    for k, v in (tokens or {}).items():
        text = text.replace("{{%s}}" % k, str(v))
    t0 = time.time()
    with conn.cursor() as cur:
        cur.execute(text)
    conn.commit()
    if not quiet:
        print(f"  [sql] {name:<40s} {time.time() - t0:6.1f}s")


def copy_csv(conn, table, csv_path, columns, skip_header=True):
    """Bulk-load a CSV into a raw_* table with COPY (all columns TEXT)."""
    cols = ", ".join(columns)
    sql = f"COPY {table} ({cols}) FROM STDIN WITH (FORMAT csv, HEADER {'true' if skip_header else 'false'}, NULL '')"
    with conn.cursor() as cur, open(csv_path, "r", encoding="utf-8", newline="") as f:
        cur.copy_expert(sql, f)
        n = cur.rowcount
    conn.commit()
    with conn.cursor() as cur:
        cur.execute(f'ANALYZE {table}')
    conn.commit()
    print(f"  [copy] {csv_path.name:<34s} -> {table:<34s} {n:>9,d} rows")
    return n


def scalar(conn, sql, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()[0]
