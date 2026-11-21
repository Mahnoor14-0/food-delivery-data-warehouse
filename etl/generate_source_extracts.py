"""
Source-system simulator (seed-controlled, reproducible).

The two PUBLIC datasets (Kaggle Food Delivery Dataset + Indian Food 101) are the real backbone.
They contain no customers, order lines, payments, promotions, cancellations, restaurant attributes
or availability logs, so this script SIMULATES those operational extracts (CRM, RPP, DISP, OMS, MKT)
on top of the *cleaned* public orders (project_staging.stg_zomato_delivery).
Every simulated order keeps the real order id, courier, restaurant, coordinates, pick-up time and
transit time of the public file. Output: CSV files in data/source_extracts/.
"""
import math, random, sys
from datetime import date, datetime, timedelta
from pathlib import Path
import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from config import REF_DIR, EXTRACT_DIR, SEED
from etl.common import connect

R = random.Random(SEED)
NP = np.random.default_rng(SEED)
SNAPS = [date(2022, 2, 11), date(2022, 3, 1), date(2022, 4, 1)]
GRID = 0.1
CUISINES = ["Punjabi", "Gujarati", "Maharashtrian", "South Indian", "Bengali & East Indian",
            "Rajasthani", "Mughlai & Awadhi", "Regional Indian"]
LOCAL = {"LUDH": "Punjabi", "SUR": "Gujarati", "VAD": "Gujarati", "MUM": "Maharashtrian", "PUNE": "Maharashtrian",
         "AURG": "Maharashtrian", "CHEN": "South Indian", "COIMB": "South Indian", "KOC": "South Indian",
         "BANG": "South Indian", "MYS": "South Indian", "HYD": "South Indian", "KOL": "Bengali & East Indian",
         "RANCHI": "Bengali & East Indian", "JAP": "Rajasthani", "AGR": "Mughlai & Awadhi", "ALH": "Mughlai & Awadhi",
         "KNP": "Mughlai & Awadhi", "BHP": "Mughlai & Awadhi", "INDO": "Mughlai & Awadhi", "DEH": "Mughlai & Awadhi",
         "GOA": "Regional Indian"}
BRANDS = {"Punjabi": ["Punjabi Tadka", "Dhaba Express", "Amritsari Kitchen", "Sher-e-Punjab"],
          "Gujarati": ["Thali Ghar", "Kathiyawadi Kitchen", "Swad Gujarat"],
          "Maharashtrian": ["Misal House", "Vada Pav Co.", "Pune Pavilion"],
          "South Indian": ["Dosa Plaza", "Udupi Delight", "Idli Junction", "Sambar Station"],
          "Bengali & East Indian": ["Kolkata Kitchen", "Bhoj Bengal", "Mishti & More"],
          "Rajasthani": ["Rajwada Rasoi", "Marwar Thali"],
          "Mughlai & Awadhi": ["Awadhi Darbar", "Nawabi Handi", "Biryani Mahal"],
          "Regional Indian": ["Desi Plate", "Spice Route", "Curry Leaf"]}
PREFIX = ["Annapurna", "Shree", "Royal", "Lucky", "Sunrise", "Moti", "Sagar", "Gupta", "Sharma", "Krishna", "Ganesh", "Zaika"]
SUFFIX = ["Dhaba", "Kitchen", "Bhojanalaya", "Restaurant", "Rasoi", "Corner"]
AREAS = ["Main Road", "City Center", "Station Road", "Mall Road", "MG Road", "Old Town", "Lakeside", "Hi-Tech Park", "Civil Lines", "Market Square"]
F_NAMES = ["Aarti", "Ananya", "Diya", "Isha", "Kavya", "Meera", "Neha", "Pooja", "Priya", "Riya", "Sana", "Shreya", "Sneha", "Tanvi", "Ayesha", "Fatima", "Nisha", "Zoya"]
M_NAMES = ["Aarav", "Arjun", "Bilal", "Dev", "Farhan", "Ishaan", "Karan", "Manav", "Nikhil", "Omar", "Rahul", "Rohan", "Sameer", "Vikram", "Yash", "Imran", "Harsh", "Kabir"]
BEVERAGES = ["Masala Chai", "Filter Coffee", "Sweet Lassi", "Salted Lassi", "Mango Lassi", "Buttermilk (Chaas)", "Fresh Lime Soda",
             "Cold Coffee", "Jaljeera", "Rose Sharbat", "Soft Drink (Cola)", "Mineral Water", "Thandai", "Coconut Water"]
SIDES = ["Raita", "Papad", "Green Salad", "Steamed Rice", "Plain Naan", "Butter Naan", "Tandoori Roti", "Jeera Rice", "Mixed Pickle"]
BASE_PRICE = {"Main": 190, "Starter": 140, "Side": 70, "Dessert": 110, "Beverage": 70, "Combo": 420}
TIER_MULT = {"Budget": 0.8, "Mid": 1.0, "Premium": 1.45}
TMAP = {"Metropolitan": "Core", "Urban": "Expansion", "Semi-Urban": "Remote"}


def pname(gender=None):
    pool = F_NAMES if gender == "Female" else M_NAMES if gender == "Male" else F_NAMES + M_NAMES
    return f"{R.choice(pool)} {chr(65 + R.randrange(26))}."


def r5(x):
    return int(round(x / 5.0) * 5)


def wchoice(items, weights):
    return R.choices(items, weights=weights, k=1)[0]


def snap_index(d):
    d = d if isinstance(d, date) else d.date()
    return 0 if d < SNAPS[1] else 1 if d < SNAPS[2] else 2


def main():
    EXTRACT_DIR.mkdir(parents=True, exist_ok=True)
    conn = connect()
    base = pd.read_sql("SELECT * FROM project_staging.stg_zomato_delivery ORDER BY src_row_no", conn)
    food = pd.read_sql("SELECT * FROM project_staging.stg_indian_food", conn)
    conn.close()
    for c in ["rest_lat", "rest_lon", "drop_lat", "drop_lon", "distance_km", "courier_rating"]:
        base[c] = base[c].astype(float)
    base["placed_ts"] = pd.to_datetime(base["placed_ts"])
    base["picked_up_ts"] = pd.to_datetime(base["picked_up_ts"])
    city = pd.read_csv(REF_DIR / "ref_city_master.csv").set_index("city_code")
    n_real = len(base)
    print(f"public backbone: {n_real:,} orders")

    # ------------------------------------------------------------ zones (0.1 degree grid per city)
    def zkey(cc, la, lo):
        return None if (pd.isna(la) or pd.isna(lo)) else f"{cc}|{int(math.floor(la / GRID))}|{int(math.floor(lo / GRID))}"
    base["pk"] = [zkey(c, a, b) for c, a, b in zip(base.city_code, base.rest_lat, base.rest_lon)]
    base["dk"] = [zkey(c, a, b) for c, a, b in zip(base.city_code, base.drop_lat, base.drop_lon)]
    keys = sorted(set(base.pk.dropna()) | set(base.dk.dropna()))
    tier = pd.concat([pd.DataFrame({"k": base.pk, "t": base.city_type.map(TMAP)}),
                      pd.DataFrame({"k": base.dk, "t": base.city_type.map(TMAP)})]).dropna()
    tier = tier.groupby("k").t.agg(lambda s: s.value_counts().index[0]).to_dict()
    zrows, zid, per_city = [], {}, {}
    for i, k in enumerate(keys):
        cc, ia, io = k.split("|")
        per_city[cc] = per_city.get(cc, 0) + 1
        zid[k] = f"ZN-{i + 1:04d}"
        zrows.append(dict(zone_id=zid[k], zone_name=f"{city.loc[cc, 'city_name']} Zone {per_city[cc]:02d}",
                          zone_type=wchoice(["Residential", "Commercial", "Mixed", "Campus"], [40, 20, 30, 10]),
                          service_tier=tier.get(k, "Core"), city=city.loc[cc, "city_name"], region=city.loc[cc, "region"],
                          country=city.loc[cc, "country"], centroid_latitude=round((int(ia) + 0.5) * GRID, 6),
                          centroid_longitude=round((int(io) + 0.5) * GRID, 6)))
    zones = pd.DataFrame(zrows)
    zname = dict(zip(zones.zone_id, zones.zone_name))
    base["pickup_zone_id"] = base.pk.map(zid)
    base["dropoff_zone_id"] = base.dk.map(zid)
    zones.to_csv(EXTRACT_DIR / "oms_zone_master.csv", index=False)
    print(f"zones: {len(zones)}")

    # ------------------------------------------------------------ couriers
    cour = base.groupby("courier_id").agg(city_code=("city_code", "first"),
                                          vehicle_type=("vehicle_type", lambda s: s.value_counts().index[0])).reset_index()
    cour["courier_name"] = [pname() for _ in range(len(cour))]
    cour["employment_type"] = [wchoice(["Full-time", "Part-time", "Gig"], [25, 25, 50]) for _ in range(len(cour))]
    cour["hire_date"] = [(date(2019, 6, 1) + timedelta(days=R.randrange(0, 1000))).isoformat() for _ in range(len(cour))]
    cour["base_city"] = cour.city_code.map(city.city_name)
    cour["courier_status"] = [wchoice(["Active", "Suspended", "Left"], [96, 2, 2]) for _ in range(len(cour))]
    cour[["courier_id", "courier_name", "vehicle_type", "employment_type", "hire_date", "base_city", "courier_status"]] \
        .to_csv(EXTRACT_DIR / "disp_courier.csv", index=False)

    # ------------------------------------------------------------ restaurants (3 monthly contract snapshots)
    rinfo = base.groupby("restaurant_id").agg(city_code=("city_code", "first"), pk=("pickup_zone_id", "first")).reset_index()
    chains = {c: R.sample(BRANDS[c], len(BRANDS[c])) for c in CUISINES}
    rest = {}
    for _, r in rinfo.iterrows():
        loc = LOCAL.get(r.city_code)
        w = [6 if c == loc else 1 for c in CUISINES]
        w[0] += 3                                   # Punjabi is popular everywhere
        prim = wchoice(CUISINES, w)
        sec = R.choice([c for c in CUISINES if c != prim]) if R.random() < 0.5 else "None"
        chain = R.random() < 0.3
        area = R.choice(AREAS)
        brand = R.choice(chains[prim]) if chain else f"{R.choice(PREFIX)} {R.choice(SUFFIX)}"
        name = f"{brand} - {area}" if chain else brand
        pt = wchoice(["Standard", "Gold", "Platinum"], [55, 30, 15])
        rest[r.restaurant_id] = dict(restaurant_id=r.restaurant_id, restaurant_name=name, brand_name=brand,
                                     chain_type="Chain" if chain else "Independent", primary_cuisine=prim,
                                     secondary_cuisine=sec, is_cloud_kitchen=R.random() < 0.22,
                                     onboarding_date=(date(2018, 1, 1) + timedelta(days=R.randrange(0, 1460))).isoformat(),
                                     city=city.loc[r.city_code, "city_name"], zone_name=zname.get(r.pk, "Unknown"),
                                     price_tier=wchoice(["Budget", "Mid", "Premium"], [30, 50, 20]), partner_tier=pt,
                                     commission_rate_pct=0, contract_status="Active")
    comm = {"Standard": 20, "Gold": 18, "Platinum": 15}
    srows = []
    for si, sd in enumerate(SNAPS):
        for rid, d in rest.items():
            if si > 0:
                if R.random() < 0.10:
                    d["partner_tier"] = R.choice([t for t in comm if t != d["partner_tier"]])
                if R.random() < 0.04:
                    d["price_tier"] = R.choice([t for t in TIER_MULT if t != d["price_tier"]])
            if True:
                d["commission_rate_pct"] = comm[d["partner_tier"]] + (0 if si == 0 else R.choice([-1, 0, 0, 0, 1]))
            srows.append(dict(snapshot_date=sd.isoformat(), **d))
    pd.DataFrame(srows).to_csv(EXTRACT_DIR / "rpp_restaurant_snapshot.csv", index=False)
    rtier0 = {rid: d["price_tier"] for rid, d in rest.items()}
    speed = {rid: float(np.clip(NP.lognormal(0, 0.3), 0.6, 1.8)) for rid in rest}

    # ------------------------------------------------------------ menu (Indian Food 101 + beverages/sides/combos)
    mrows, menu = [], {}
    n_item = 0
    byc = {c: food[food.cuisine_type == c] for c in CUISINES}
    for rid, d in rest.items():
        pool = []
        for cu, k in ((d["primary_cuisine"], 14), (d["secondary_cuisine"], 6)):
            if cu in byc and len(byc[cu]):
                pool += byc[cu].sample(min(k, len(byc[cu])), random_state=R.randrange(10**6)).to_dict("records")
        pool += food.sample(8, random_state=R.randrange(10**6)).to_dict("records")
        seen, items = set(), []
        for p in pool:
            if p["dish_name"] in seen:
                continue
            seen.add(p["dish_name"])
            items.append(dict(name=p["dish_name"], cat=p["course"], cuisine=p["cuisine_type"], diet=p["diet"],
                              spice={"Spicy": "Hot", "Sweet": "Mild", "Bitter": "Medium", "Sour": "Medium"}.get(p["flavor_profile"], "N/A"),
                              combo=False))
        for b in R.sample(BEVERAGES, 5):
            items.append(dict(name=b, cat="Beverage", cuisine="Beverages", diet="Veg", spice="N/A", combo=False))
        for s in R.sample(SIDES, 4):
            items.append(dict(name=s, cat="Side", cuisine="Indian Breads & Sides", diet="Veg", spice="N/A", combo=False))
        for cn in R.sample(["Thali", "Family Feast", "Mini Meal Box"], 2):
            items.append(dict(name=f"{d['primary_cuisine']} {cn}", cat="Combo", cuisine=d["primary_cuisine"],
                              diet="Non-Veg" if R.random() < 0.4 else "Veg", spice="Medium", combo=True))
        menu[rid] = {}
        for it in items:
            n_item += 1
            iid = f"ITM-{n_item:06d}"
            price = r5(BASE_PRICE[it["cat"]] * R.uniform(0.75, 1.35) * TIER_MULT[rtier0[rid]])
            active = R.random() < 0.95
            mrows.append(dict(menu_item_id=iid, restaurant_id=rid, item_name=it["name"], item_category=it["cat"],
                              cuisine_type=it["cuisine"], dietary_type=it["diet"], spice_level=it["spice"],
                              is_combo_meal=it["combo"], list_price=max(price, 20), is_active=active))
            if active:
                menu[rid].setdefault(it["cat"], []).append((iid, max(price, 20)))
    pd.DataFrame(mrows).to_csv(EXTRACT_DIR / "rpp_menu_item.csv", index=False)
    n_active = {rid: sum(len(v) for v in m.values()) for rid, m in menu.items()}
    print(f"restaurants: {len(rest)}, menu items: {len(mrows):,}")

    # ------------------------------------------------------------ availability log (needed first: drives cancellations)
    hol = set(pd.read_csv(REF_DIR / "ref_holiday.csv").holiday_date)
    spine = sorted(base.placed_ts.dt.date.unique())
    rel = {rid: (NP.beta(12, 2) if R.random() < 0.12 else NP.beta(30, 2.2)) for rid in rest}
    arows = []
    for rid, d in rest.items():
        for dt in spine:
            sched = 960 if d["is_cloud_kitchen"] else (600 if dt.isoformat() in hol else 780 if dt.weekday() >= 5 else 720)
            if R.random() < (0.05 if rel[rid] < 0.9 else 0.015):
                online = 0
            else:
                online = int(round(sched * float(np.clip(NP.normal(rel[rid], 0.06), 0.4, 1.0))))
            act = n_active[rid]
            unav = act if online == 0 else int(NP.binomial(act, min(0.04 + 0.25 * (1 - online / sched), 0.6)))
            arows.append(dict(log_date=dt.isoformat(), restaurant_id=rid, scheduled_open_minutes=sched,
                              online_minutes=online, active_menu_items=act, unavailable_menu_items=unav, open_complaints=0))
    avail = pd.DataFrame(arows)
    avail["w"] = (1 - avail.online_minutes / avail.scheduled_open_minutes) + 0.02

    # ------------------------------------------------------------ orders: real + simulated cancellations
    base["status"] = "DELIVERED"
    base["reason"] = "NOT_CXL"
    base["closed_ts"] = base.picked_up_ts + pd.to_timedelta(base.transit_minutes, unit="m")
    base["is_syn"] = False
    n_extra = int(round(n_real * 0.067 / 0.933))
    by_rest = base.groupby("restaurant_id").indices
    reasons = {"CXL_CUST": (["CHG_MIND", "DUP_ORD", "WRONG_ADDR", "LONG_WAIT"], [45, 10, 15, 30]),
               "CXL_REST": (["RST_CLOSED", "ITEM_UNAV"], [45, 55]),
               "CXL_PLAT": (["PAY_FAIL", "CRR_UNAV"], [50, 50]),
               "FAILED": (["CUST_UNREACH", "VEH_BREAK", "WRONG_ADDR"], [55, 25, 20])}
    extras = []
    aw = avail.w.values / avail.w.sum()
    for n in range(n_extra):
        st = wchoice(list(reasons), [46, 31, 13, 10])
        rs = wchoice(*reasons[st])
        if st == "CXL_REST":
            ar = avail.iloc[int(NP.choice(len(avail), p=aw))]
            idxs = by_rest[ar.restaurant_id]
            t = base.iloc[int(R.choice(list(idxs)))]
            day = date.fromisoformat(ar.log_date)
        else:
            t = base.iloc[R.randrange(n_real)]
            day = t.placed_ts.date()
        placed = datetime.combine(day, t.placed_ts.time())
        lag = (t.picked_up_ts - t.placed_ts).total_seconds() / 60.0
        acc = rdy = pick = None
        if st == "FAILED":
            acc = placed + timedelta(minutes=lag * 0.2); rdy = placed + timedelta(minutes=lag * 0.8)
            pick = placed + timedelta(minutes=lag); close = pick + timedelta(minutes=R.uniform(8, 40))
        elif rs in ("RST_CLOSED", "PAY_FAIL"):
            close = placed + timedelta(minutes=R.uniform(0.5, 10))
        elif rs in ("CHG_MIND", "DUP_ORD", "WRONG_ADDR"):
            if R.random() < 0.4:
                acc = placed + timedelta(minutes=R.uniform(0.5, 2))
            close = placed + timedelta(minutes=R.uniform(2.5, 12))
        elif rs == "ITEM_UNAV":
            acc = placed + timedelta(minutes=R.uniform(0.5, 2)); close = acc + timedelta(minutes=R.uniform(2, 8))
        elif rs == "LONG_WAIT":
            acc = placed + timedelta(minutes=R.uniform(0.5, 3)); rdy = None
            close = placed + timedelta(minutes=R.uniform(20, 40))
        else:  # CRR_UNAV
            acc = placed + timedelta(minutes=R.uniform(0.5, 3)); rdy = acc + timedelta(minutes=lag * 0.6)
            close = rdy + timedelta(minutes=R.uniform(5, 20))
        extras.append(dict(order_id=f"SYN-{n + 1:06d}", courier_id=t.courier_id if st == "FAILED" else None,
                           city_code=t.city_code, restaurant_id=t.restaurant_id, courier_rating=t.courier_rating,
                           distance_km=t.distance_km, placed_ts=placed, picked_up_ts=pick, closed_ts=close,
                           order_type=t.order_type, road_traffic=t.road_traffic, multiple_deliveries=t.multiple_deliveries,
                           city_type=t.city_type, pickup_zone_id=t.pickup_zone_id, dropoff_zone_id=t.dropoff_zone_id,
                           status=st, reason=rs, accepted_ts=acc, ready_ts=rdy, transit_minutes=np.nan, is_syn=True))
    ex = pd.DataFrame(extras)
    cols = ["order_id", "courier_id", "city_code", "restaurant_id", "courier_rating", "distance_km", "placed_ts", "picked_up_ts",
            "closed_ts", "order_type", "road_traffic", "multiple_deliveries", "city_type", "pickup_zone_id", "dropoff_zone_id",
            "status", "reason", "transit_minutes", "is_syn"]
    # real delivered orders: simulate acceptance / ready milestones inside the real placed -> picked-up window
    acc_l, rdy_l = [], []
    for t in base.itertuples():
        L = max((t.picked_up_ts - t.placed_ts).total_seconds() / 60.0, 1.0)
        s = speed[t.restaurant_id]
        wa, wp, ww = R.uniform(0.1, 0.25), 0.55 * s * R.uniform(0.8, 1.2), R.uniform(0.1, 0.25) / s
        tot = wa + wp + ww
        a = L * wa / tot; p = L * wp / tot
        acc_l.append(t.placed_ts + pd.Timedelta(minutes=a)); rdy_l.append(t.placed_ts + pd.Timedelta(minutes=a + p))
    base["accepted_ts"] = acc_l
    base["ready_ts"] = rdy_l
    o = pd.concat([base[cols + ["accepted_ts", "ready_ts"]], ex[cols + ["accepted_ts", "ready_ts"]]], ignore_index=True)
    for c in ["placed_ts", "picked_up_ts", "closed_ts", "accepted_ts", "ready_ts"]:
        o[c] = pd.to_datetime(o[c])
    o = o.sort_values("placed_ts").reset_index(drop=True)
    N = len(o)
    print(f"orders: {N:,} ({n_extra:,} simulated cancelled/failed)")

    # ------------------------------------------------------------ ETA promise (model ETA + buffer)
    lag_all = (o.picked_up_ts - o.placed_ts).dt.total_seconds() / 60
    dist_fill = o.distance_km.fillna(o.distance_km.median())
    X = np.column_stack([np.ones(N), dist_fill] + [(o.road_traffic == k).astype(float) for k in ("Medium", "High", "Jam")]
                        + [o.multiple_deliveries.fillna(0)])
    real = (~o.is_syn).values
    y = (lag_all + o.transit_minutes)[real].values
    beta = np.linalg.lstsq(X[real], y, rcond=None)[0]
    pred = X @ beta
    buf = np.quantile(y - pred[real], 0.72)
    o["promised"] = np.maximum(20, 5 * np.ceil((pred + buf) / 5)).astype(int)

    # ------------------------------------------------------------ customers
    cust_rows, cz = [], {}
    zone_orders = o.dropoff_zone_id.value_counts()
    zcity = dict(zip(zones.zone_id, zones.city))
    for z, n in zone_orders.items():
        k = max(2, int(math.ceil(n / 5.8)))
        cz[z] = [len(cust_rows) + i for i in range(k)]
        for _ in range(k):
            cust_rows.append(dict(home_zone_id=z, city=zcity[z]))
    C = len(cust_rows)
    cust = pd.DataFrame(cust_rows)
    cust["w"] = NP.lognormal(0, 0.9, C)
    cust["customer_id"] = [f"CUST-{i + 1:07d}" for i in range(C)]
    city_idx = cust.groupby("city").indices
    o["cust_idx"] = -1
    cname = dict(zip(city.index, city.city_name))
    ocity = o.city_code.map(cname)
    for z, idxs in o.groupby("dropoff_zone_id").indices.items():
        cs = np.array(cz[z]); p = cust.w.values[cs]
        o.loc[idxs, "cust_idx"] = NP.choice(cs, size=len(idxs), p=p / p.sum())
    nz = np.where(o.dropoff_zone_id.isna())[0]
    for i in nz:
        cs = city_idx[ocity.iloc[i]]; p = cust.w.values[cs]
        o.loc[i, "cust_idx"] = NP.choice(cs, p=p / p.sum())
    guest = NP.random(N) < 0.015
    o.loc[guest, "cust_idx"] = -1
    first = o[o.cust_idx >= 0].groupby("cust_idx").placed_ts.min().dt.date
    cust["gender"] = [wchoice(["Female", "Male", "Other"], [46, 52, 2]) for _ in range(C)]
    cust["full_name"] = [pname(g if g != "Other" else None) for g in cust.gender]
    cust["dob"] = [(date(2022, 2, 11) - timedelta(days=int(365.25 * float(np.clip(NP.normal(31, 9), 18, 70))))).isoformat() for _ in range(C)]
    cust["acq"] = [wchoice(["Organic", "Paid Social", "Referral", "Partner"], [40, 25, 20, 15]) for _ in range(C)]
    su = []
    for i in range(C):
        f = first.get(i)
        if f is not None and R.random() < 0.18:
            s = min(f - timedelta(days=R.randrange(0, 3)), SNAPS[2])
        elif f is not None:
            s = date(2020, 1, 15) + timedelta(days=R.randrange(0, 757))
        else:
            s = date(2020, 1, 15) + timedelta(days=R.randrange(0, 807))
        su.append(s)
    cust["signup"] = su
    rank = cust.w.rank(pct=True).values
    zones_by_city = zones.groupby("city").zone_id.apply(list).to_dict()
    seg = np.empty(C, dtype=object); tr = np.empty(C, dtype=object); sub = np.zeros(C, dtype=bool)
    hz = list(cust.home_zone_id)
    snaps_state = []
    segmat = {"New": (["Regular", "At Risk", "Churned"], [70, 20, 10]), "VIP": (["VIP", "Regular", "At Risk"], [85, 12, 3]),
              "Regular": (["Regular", "VIP", "At Risk", "Churned"], [80, 7, 10, 3]),
              "At Risk": (["At Risk", "Regular", "Churned"], [55, 25, 20]), "Churned": (["Churned", "At Risk"], [90, 10])}
    for si, sd in enumerate(SNAPS):
        for i in range(C):
            new = (sd - cust.signup[i]).days <= 30
            if si == 0:
                tr[i] = "Platinum" if rank[i] > .97 else "Gold" if rank[i] > .87 else "Silver" if rank[i] > .62 else "None"
                sub[i] = R.random() < (0.30 if rank[i] > .8 else 0.08)
                seg[i] = "New" if new else ("VIP" if rank[i] > .92 else wchoice(["Regular", "At Risk", "Churned"], [74, 15, 11]))
            else:
                if new:
                    seg[i] = "New"
                else:
                    seg[i] = wchoice(*segmat[seg[i]])
                if R.random() < 0.05:
                    order = ["None", "Silver", "Gold", "Platinum"]; j = order.index(tr[i])
                    tr[i] = order[min(j + 1, 3)] if R.random() < 0.75 else order[max(j - 1, 0)]
                if R.random() < 0.04:
                    sub[i] = not sub[i]
                if R.random() < 0.015:
                    hz[i] = R.choice(zones_by_city[cust.city[i]])
        snaps_state.append((seg.copy(), tr.copy(), sub.copy(), list(hz)))
    crow = []
    for si, sd in enumerate(SNAPS):
        sg, tt, sb, hh = snaps_state[si]
        for i in range(C):
            if cust.signup[i] > sd and not (si == 2):
                continue
            if cust.signup[i] > SNAPS[2]:
                continue
            crow.append(dict(snapshot_date=sd.isoformat(), customer_id=cust.customer_id[i], full_name=cust.full_name[i],
                             gender=cust.gender[i], dob=cust.dob[i], signup_date=cust.signup[i].isoformat(),
                             acquisition_channel=cust.acq[i], customer_segment=sg[i], loyalty_tier=tt[i],
                             is_subscriber=bool(sb[i]), home_zone=zname[hh[i]], home_city=cust.city[i]))
    crm = pd.DataFrame(crow)
    # documented, injected source defects (exercise the staging clean-up rules)
    m = NP.random(len(crm)) < 0.012
    crm.loc[m, "home_city"] = [R.choice(["  {}  ", "{}"]).format(v.upper() if R.random() < .5 else v.lower()) for v in crm.loc[m, "home_city"]]
    m2 = NP.random(len(crm)) < 0.006
    crm.loc[m2, "gender"] = ""
    crm = pd.concat([crm, crm.sample(frac=0.004, random_state=SEED)], ignore_index=True)
    crm.to_csv(EXTRACT_DIR / "crm_customer_snapshot.csv", index=False)
    print(f"customers: {C:,}; crm snapshot rows {len(crm):,}")
    o["customer_id"] = [cust.customer_id[i] if i >= 0 else None for i in o.cust_idx]

    # ------------------------------------------------------------ order lines
    COMP = {"Meal": [("Main", [0, 1, 1, 2]), ("Starter", [0, 0, 1]), ("Side", [0, 1, 1, 2]), ("Beverage", [0, 1, 1]), ("Dessert", [0, 0, 1])],
            "Snack": [("Starter", [1, 1, 2, 3]), ("Side", [0, 1]), ("Beverage", [0, 1, 1])],
            "Drinks": [("Beverage", [1, 1, 2, 3]), ("Dessert", [0, 0, 1])],
            "Buffet": [("Combo", [1, 1, 2]), ("Main", [0, 1]), ("Beverage", [0, 1])]}
    lines, subtotal, items_cnt, cheapest = [], np.zeros(N), np.zeros(N, dtype=int), np.zeros(N)
    for i, (oid, rid, ot) in enumerate(zip(o.order_id, o.restaurant_id, o.order_type)):
        mn = menu[rid]; ln = 0; picked = set(); sub_t = 0.0; q_t = 0; cheap = 1e9
        for cat, ch in COMP.get(ot, COMP["Meal"]):
            k = R.choice(ch)
            avail_items = [x for x in mn.get(cat, []) if x[0] not in picked]
            for it in R.sample(avail_items, min(k, len(avail_items))):
                qty = wchoice([1, 2, 3], [75, 20, 5]); ln += 1; picked.add(it[0])
                lines.append((oid, ln, it[0], qty, it[1])); sub_t += qty * it[1]; q_t += qty; cheap = min(cheap, it[1])
        if ln == 0:
            allit = [x for v in mn.values() for x in v]; it = R.choice(allit)
            lines.append((oid, 1, it[0], 1, it[1])); sub_t, q_t, cheap = it[1], 1, it[1]
        subtotal[i], items_cnt[i], cheapest[i] = sub_t, q_t, cheap
    o["subtotal"], o["items"], o["cheapest"] = subtotal, items_cnt, cheapest
    pd.DataFrame(lines, columns=["order_id", "line_no", "menu_item_id", "qty", "unit_price"]).to_csv(EXTRACT_DIR / "oms_order_line.csv", index=False)

    # ------------------------------------------------------------ promotions, targets, redemption
    camps = [("Welcome Offer 2022", "2022-01-15", "2022-04-30", "New"), ("Republic Day Feast", "2022-01-24", "2022-02-13", "All"),
             ("Valentine Week Treats", "2022-02-07", "2022-02-18", "All"), ("Weekend Binge", "2022-02-11", "2022-04-07", "All"),
             ("Maha Shivratri Specials", "2022-02-27", "2022-03-03", "All"), ("Womens Day Delights", "2022-03-05", "2022-03-10", "All"),
             ("Holi Colours Feast", "2022-03-14", "2022-03-20", "All"), ("Free Delivery Fortnight", "2022-03-01", "2022-03-15", "All"),
             ("Win-Back Wednesdays", "2022-03-02", "2022-04-06", "At Risk"), ("VIP Appreciation Month", "2022-03-10", "2022-04-10", "VIP"),
             ("IPL Season Opener", "2022-03-26", "2022-04-07", "All"), ("Gudi Padwa and Ugadi Feast", "2022-03-30", "2022-04-04", "All")]
    ptypes = ["Percent Discount", "Flat Discount", "Free Delivery", "BOGO", "Cashback"]
    prom = []
    for ci, (cn, cs, ce, tg) in enumerate(camps):
        cs_d, ce_d = date.fromisoformat(cs), date.fromisoformat(ce)
        for j in range(10):
            pt = wchoice(ptypes, [38, 25, 15, 10, 12])
            val, unit = {"Percent Discount": (R.choice([10, 15, 20, 25, 30, 40]), "Percent"), "Flat Discount": (R.choice([50, 75, 100, 150]), "Amount"),
                         "Free Delivery": (100, "Percent"), "BOGO": (100, "Percent"), "Cashback": (R.choice([5, 10, 15]), "Percent")}[pt]
            s = cs_d + timedelta(days=R.randrange(0, 3)); e = max(s + timedelta(days=3), ce_d - timedelta(days=R.randrange(0, 2)))
            prom.append(dict(promotion_id=f"PROMO-{ci * 10 + j + 1:04d}", promotion_code=f"{''.join(w[0] for w in cn.split()[:3]).upper()}{ci + 1:02d}{chr(65 + j)}{val}",
                             promotion_name=f"{cn} {val}{'%' if unit == 'Percent' else ' Off'} {pt}", campaign_name=cn, promotion_type=pt,
                             discount_value=val, discount_unit=unit, funded_by=wchoice(["Platform", "Restaurant", "Shared"], [60, 15, 25]),
                             target_segment=tg, min_order_amount={"Percent Discount": 200, "Flat Discount": 400, "Free Delivery": 200, "BOGO": 250, "Cashback": 300}[pt],
                             start_date=s.isoformat(), end_date=e.isoformat()))
    pm = pd.DataFrame(prom)
    pm.to_csv(EXTRACT_DIR / "mkt_promotion.csv", index=False)
    seg_by_snap = [dict(zip(range(C), st[0])) for st in snaps_state]
    o["promo"] = None; o["disc"] = 0.0; o["free_del"] = False
    o_date = o.placed_ts.dt.date.values
    cust_orders = {}
    for i, c in enumerate(o.cust_idx.values):
        if c >= 0:
            cust_orders.setdefault(c, []).append(i)
    trows = []
    p_red = {"Percent Discount": .14, "Flat Discount": .12, "Free Delivery": .20, "BOGO": .10, "Cashback": .11}
    for p in pm.itertuples():
        issue = date.fromisoformat(p.start_date) + timedelta(days=R.randrange(0, 3)); exp = date.fromisoformat(p.end_date)
        sg = seg_by_snap[snap_index(issue)]
        pool = [i for i in range(C) if cust.signup[i] <= issue and (p.target_segment == "All" or sg[i] == p.target_segment)]
        k = int(len(pool) * (0.07 if p.target_segment == "All" else 0.30))
        for i in R.sample(pool, min(k, len(pool))):
            trows.append((p.promotion_id, cust.customer_id[i], issue.isoformat(), exp.isoformat()))
            if R.random() < p_red[p.promotion_type] * (1.5 if p.target_segment == "New" else 1.0):
                cand = [j for j in cust_orders.get(i, []) if issue <= o_date[j] <= exp and o.promo.iat[j] is None and o.subtotal.iat[j] >= p.min_order_amount]
                if cand:
                    j = R.choice(cand)
                    o.at[j, "promo"] = p.promotion_id
                    sbt = o.subtotal.iat[j]
                    d = {"Percent Discount": min(sbt * p.discount_value / 100, 200), "Cashback": min(sbt * p.discount_value / 100, 150),
                         "Flat Discount": min(p.discount_value, sbt), "BOGO": o.cheapest.iat[j], "Free Delivery": 0.0}[p.promotion_type]
                    o.at[j, "disc"] = round(float(d), 2)
                    o.at[j, "free_del"] = p.promotion_type == "Free Delivery"
    pd.DataFrame(trows, columns=["promotion_id", "customer_id", "issued_at", "expires_at"]).drop_duplicates(["promotion_id", "customer_id", "issued_at"]) \
        .to_csv(EXTRACT_DIR / "mkt_promotion_target.csv", index=False)
    print(f"promotions: {len(pm)}, targets: {len(trows):,}, redeemed orders: {o.promo.notna().sum():,}")

    # ------------------------------------------------------------ payment, channel, fees, tips, refunds, ratings
    o["channel"] = [wchoice(["ANDROID", "IOS", "WEB", "CALLCTR"], [52, 22, 18, 8]) for _ in range(N)]
    o["pay"] = [wchoice(["COD", "DEBIT", "CREDIT", "WALLET", "BANK"], [38, 17, 14, 24, 7]) for _ in range(N)]
    o.loc[o.reason == "PAY_FAIL", "pay"] = "CREDIT"
    sub_flag = np.array([snaps_state[snap_index(d)][2][c] if c >= 0 else False for d, c in zip(o_date, o.cust_idx.values)])
    dist_f = o.distance_km.fillna(9.7)
    o["fee"] = [0.0 if (s or f) else float(r5(25 + 4 * d)) for s, f, d in zip(sub_flag, o.free_del, dist_f)]
    deliv = (o.status == "DELIVERED").values
    total_min = ((o.closed_ts - o.placed_ts).dt.total_seconds() / 60).values
    delay = total_min - o.promised.values
    o["tip"] = [float(R.choice([10, 20, 30, 50])) if (d and R.random() < 0.3) else 0.0 for d in deliv]
    net = o.subtotal - o.disc
    refund = np.zeros(N)
    for i in range(N):
        if deliv[i]:
            if delay[i] > 20 and R.random() < 0.25:
                refund[i] = round(0.25 * net.iat[i], 2)
        elif o.pay.iat[i] != "COD":
            refund[i] = round(net.iat[i] + o.fee.iat[i], 2)
    o["refund"] = refund
    crat = o.courier_rating.fillna(4.6).values
    rating = []
    for i in range(N):
        if deliv[i] and R.random() < 0.5:
            v = 4.45 + 0.3 * (crat[i] - 4.6) - 0.045 * max(delay[i], 0) + R.gauss(0, 0.7)
            rating.append(int(min(5, max(1, round(v)))))
        else:
            rating.append(None)
    o["rating"] = rating

    # ------------------------------------------------------------ write OMS order extract
    def ts(c):
        return c.dt.strftime("%Y-%m-%d %H:%M:%S")
    out = pd.DataFrame(dict(batch_id=1, order_id=o.order_id, customer_id=o.customer_id, restaurant_id=o.restaurant_id,
                            courier_id=o.courier_id, pickup_zone_id=o.pickup_zone_id, dropoff_zone_id=o.dropoff_zone_id,
                            channel_code=o.channel, payment_method_code=o.pay, order_status_code=o.status,
                            cancellation_reason_code=o.reason, promotion_id=o.promo, placed_at=ts(o.placed_ts),
                            accepted_at=ts(o.accepted_ts), ready_at=ts(o.ready_ts), picked_up_at=ts(o.picked_up_ts),
                            closed_at=ts(o.closed_ts), items_count=o["items"], order_subtotal=o.subtotal.round(2),
                            order_discount=o.disc.round(2), delivery_fee=o.fee, tip=o.tip, refund=o.refund,
                            delivery_distance_km=o.distance_km.round(2), promised_delivery_minutes=o.promised,
                            customer_rating=o.rating))
    out.to_csv(EXTRACT_DIR / "oms_order.csv", index=False)

    # complaints depend on late / cancelled orders -> finish availability log
    o["day"] = o.placed_ts.dt.date.astype(str)
    late = o[deliv & (delay > 0)].groupby(["day", "restaurant_id"]).size()
    crest = o[o.status == "CXL_REST"].groupby(["day", "restaurant_id"]).size()
    lam = []
    for r in avail.itertuples():
        key = (r.log_date, r.restaurant_id)
        lam.append(0.15 + 0.10 * late.get(key, 0) + 0.5 * crest.get(key, 0))
    avail["open_complaints"] = NP.poisson(lam)
    avail.drop(columns="w").to_csv(EXTRACT_DIR / "rpp_availability_log.csv", index=False)
    print("on-time share of delivered orders:", round(float((delay[deliv] <= 0).mean()), 3))
    print("extracts written to", EXTRACT_DIR)


if __name__ == "__main__":
    main()
