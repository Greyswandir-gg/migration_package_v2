import streamlit as st
import pandas as pd
from sqlalchemy import create_engine, text
import os
import json
import re
import unicodedata
from datetime import datetime, timezone

st.set_page_config(page_title="Admin Panel", layout="wide")

DB_URL = os.getenv("DATABASE_URL", "postgresql://admin:secretpassword@localhost:5432/analytics_db")
engine = create_engine(DB_URL)
MAPPING_FILE = 'mappings.json'

ADMIN_CREDENTIALS = {"admin": "admin123"}

DEFAULT_IGNORE_SHEETS = {"Sources"}
TABLE_PREFIX = "xl_"
PRIMARY_IMPORT_SHEET = "ProjectTimes"


def sanitize_identifier(value):
    cleaned = re.sub(r"[^a-z0-9_]+", "_", str(value).strip().lower())
    cleaned = re.sub(r"_+", "_", cleaned).strip("_")
    if not cleaned:
        cleaned = "col"
    if cleaned[0].isdigit():
        cleaned = f"c_{cleaned}"
    return cleaned


def sanitize_login_part(value):
    raw = str(value or "").strip().lower()
    # Normalize diacritics (e.g. "Mészáros" -> "meszaros")
    raw = unicodedata.normalize("NFKD", raw).encode("ascii", "ignore").decode("ascii")
    raw = re.sub(r"[^a-z0-9]+", ".", raw)
    raw = re.sub(r"[.]+", ".", raw).strip(".")
    return raw


def derive_login_from_employee_name(employee_name):
    name = str(employee_name or "").strip()
    if not name:
        return "unassigned"

    if "," in name:
        last = sanitize_login_part(name.split(",", 1)[0])
        first = sanitize_login_part(name.split(",", 1)[1])
        candidate = ".".join([part for part in (last, first) if part])
        return candidate or "unassigned"

    parts = [sanitize_login_part(p) for p in name.split() if sanitize_login_part(p)]
    if len(parts) >= 2:
        return f"{parts[0]}.{parts[1]}"
    if len(parts) == 1:
        return parts[0]
    return "unassigned"
def make_unique_names(values):
    seen = {}
    result = []
    for value in values:
        base = sanitize_identifier(value)
        count = seen.get(base, 0)
        if count:
            candidate = f"{base}_{count + 1}"
        else:
            candidate = base
        seen[base] = count + 1
        result.append(candidate)
    return result


def build_table_name(sheet_name):
    return f"{TABLE_PREFIX}{sanitize_identifier(sheet_name)}"


def normalize_dataframe(df):
    data = df.copy()
    data = data.dropna(axis=1, how='all')
    data.columns = make_unique_names(data.columns)
    return data


def parse_ignore_sheets(raw_value):
    if not raw_value:
        return set(DEFAULT_IGNORE_SHEETS)
    return {part.strip() for part in raw_value.split(",") if part.strip()}


def load_all_sheets(uploaded_file, ignore_sheets):
    all_sheets = pd.read_excel(uploaded_file, sheet_name=None, engine='openpyxl')
    selected = {
        name: frame for name, frame in all_sheets.items()
        if name not in ignore_sheets
    }
    return all_sheets, selected


def drop_existing_xl_tables(conn, only_tables=None):
    existing = conn.execute(text(
        "SELECT c.relname AS object_name, c.relkind AS object_kind "
        "FROM pg_class c "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname = 'public' "
        "  AND c.relname LIKE :prefix "
        "  AND c.relkind IN ('r', 'p', 'v', 'm')"
    ), {"prefix": f"{TABLE_PREFIX}%"}).fetchall()
    only_tables = {t for t in (only_tables or [])}
    dropped = 0
    for (object_name, object_kind) in existing:
        if only_tables and object_name not in only_tables:
            continue
        if re.match(r"^[a-z0-9_]+$", object_name):
            if object_kind in ("v", "m"):
                conn.execute(text(f'DROP VIEW IF EXISTS "{object_name}" CASCADE'))
            else:
                conn.execute(text(f'DROP TABLE IF EXISTS "{object_name}" CASCADE'))
            dropped += 1
    return dropped


def ensure_etl_runs_table(conn):
    conn.execute(text(
        """
        CREATE TABLE IF NOT EXISTS etl_import_runs (
            id BIGSERIAL PRIMARY KEY,
            started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            finished_at TIMESTAMPTZ NULL,
            status VARCHAR(20) NOT NULL,
            file_name TEXT NULL,
            ignore_sheets TEXT NULL,
            imported_sheet_count INTEGER NOT NULL DEFAULT 0,
            imported_row_count BIGINT NOT NULL DEFAULT 0,
            dropped_table_count INTEGER NOT NULL DEFAULT 0,
            error_message TEXT NULL
        )
        """
    ))


def start_import_run(file_name, ignore_sheets):
    with engine.begin() as conn:
        ensure_etl_runs_table(conn)
        row = conn.execute(
            text(
                """
                INSERT INTO etl_import_runs (status, file_name, ignore_sheets)
                VALUES ('running', :file_name, :ignore_sheets)
                RETURNING id
                """
            ),
            {"file_name": file_name, "ignore_sheets": ", ".join(sorted(ignore_sheets))}
        ).fetchone()
    return row[0]


def finish_import_run(run_id, status, imported_sheet_count=0, imported_row_count=0, dropped_table_count=0, error_message=None):
    with engine.begin() as conn:
        ensure_etl_runs_table(conn)
        conn.execute(
            text(
                """
                UPDATE etl_import_runs
                SET finished_at = :finished_at,
                    status = :status,
                    imported_sheet_count = :imported_sheet_count,
                    imported_row_count = :imported_row_count,
                    dropped_table_count = :dropped_table_count,
                    error_message = :error_message
                WHERE id = :run_id
                """
            ),
            {
                "finished_at": datetime.now(timezone.utc),
                "status": status,
                "imported_sheet_count": int(imported_sheet_count),
                "imported_row_count": int(imported_row_count),
                "dropped_table_count": int(dropped_table_count),
                "error_message": error_message,
                "run_id": int(run_id),
            }
        )


def rebuild_work_logs_if_possible(selected_sheets, conn):
    if 'ProjectTimes' not in selected_sheets:
        return None

    df = selected_sheets['ProjectTimes'].copy()

    # Support new Evaluation_* files where some source headers may vary by export.
    source_candidates = {
        'work_date': ['Datum'],
        'duration': ['Dauer'],
        'department': ['Bereich', 'Abteilung'],
        'project_number': ['Projekt-Nr.'],
        'activity_type': ['Task_new', 'Tätigkeit'],
        'employee_name': ['Mitarbeiter'],
        'description': ['Bemerkung'],
    }
    picked = {}
    missing_targets = []
    for target, candidates in source_candidates.items():
        source_name = next((name for name in candidates if name in df.columns), None)
        if source_name is None:
            missing_targets.append(target)
        else:
            picked[target] = source_name
    if missing_targets:
        return {"ok": False, "missing": missing_targets}

    mapping = load_mappings()
    selected_source_cols = [picked[key] for key in source_candidates.keys()]
    rename_map = {picked[key]: key for key in source_candidates.keys()}
    work = df[selected_source_cols].rename(columns=rename_map)
    mapped = work['employee_name'].map(mapping)
    fallback = work['employee_name'].apply(derive_login_from_employee_name)
    work['owner_login'] = mapped.fillna(fallback).fillna('unassigned')
    work['owner_login'] = work['owner_login'].astype(str).str.strip().replace("", "unassigned")

    # Keep existing Grafana filters functional after full refresh uploads.
    if 'employment_type' in df.columns:
        work['employment_type'] = df['employment_type']
    elif 'MA-Kat' in df.columns:
        work['employment_type'] = df['MA-Kat'].map({
            'RW': 'Full-time',
            'Sub': 'Part-time',
            'Temp': 'Temporary',
        }).fillna('Full-time')
    elif 'Mitarbeiter Kategorien' in df.columns:
        work['employment_type'] = df['Mitarbeiter Kategorien'].map({
            'RW': 'Full-time',
            'Sub': 'Part-time',
            'Temp': 'Temporary',
        }).fillna('Full-time')
    else:
        work['employment_type'] = 'Full-time'

    work = work[['owner_login', 'work_date', 'duration', 'department', 'project_number',
                 'activity_type', 'employee_name', 'description', 'employment_type']]

    table_exists = conn.execute(text(
        """
        SELECT EXISTS (
            SELECT 1
            FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name = 'work_logs'
        )
        """
    )).scalar()

    # Keep dependent views intact: clear rows then append instead of DROP/CREATE.
    if table_exists:
        conn.execute(text("TRUNCATE TABLE work_logs"))
        work.to_sql('work_logs', conn, if_exists='append', index=False, method='multi', chunksize=1000)
    else:
        work.to_sql('work_logs', conn, if_exists='replace', index=False, method='multi', chunksize=1000)
    return {"ok": True, "rows": len(work)}

def load_mappings():
    if os.path.exists(MAPPING_FILE):
        with open(MAPPING_FILE, 'r', encoding='utf-8') as f:
            return json.load(f)
    else:
        default_map = {"Ivanov Ivan": "ivan", "Petrov Petr": "petr"}
        save_mappings(default_map)
        return default_map

def save_mappings(mapping_dict):
    with open(MAPPING_FILE, 'w', encoding='utf-8') as f:
        json.dump(mapping_dict, f, ensure_ascii=False, indent=4)

def login_page():
    col1, col2, col3 = st.columns([1,1,1])
    with col2:
        st.title("🛡️ Admin Login")
        with st.form("login"):
            username = st.text_input("Username")
            password = st.text_input("Password", type="password")
            if st.form_submit_button("Enter"):
                if username in ADMIN_CREDENTIALS and ADMIN_CREDENTIALS[username] == password:
                    st.session_state['logged_in'] = True
                    st.session_state['username'] = username
                    st.rerun()
                else:
                    st.error("Access Denied")

def main_app():
    if 'logged_in' not in st.session_state or not st.session_state.get('logged_in', False):
        st.session_state['logged_in'] = False
        st.rerun()

    current_mapping = load_mappings()

    st.sidebar.title(f"Admin: {st.session_state.get('username', 'Unknown')}")
    st.sidebar.info("Control panel for data upload and user management.")

    if st.sidebar.button("Logout", type="primary"):
        st.session_state['logged_in'] = False
        st.rerun()

    tab1, tab2, tab3 = st.tabs(["📤 Data Upload", "👥 User Settings", "🔧 Database Management"])

    with tab1:
        st.header("Upload Excel Report")
        uploaded_file = st.file_uploader("File Evaluation_2023ff.xlsx", type=["xlsx", "xls"])
        ignore_raw = st.text_input(
            "Ignore sheets (comma separated)",
            value=", ".join(sorted(DEFAULT_IGNORE_SHEETS)),
            help="These sheets are skipped during full refresh load."
        )

        if uploaded_file:
            try:
                with st.spinner('Reading all sheets...'):
                    ignore_sheets = parse_ignore_sheets(ignore_raw)
                    all_sheets, selected_sheets = load_all_sheets(uploaded_file, ignore_sheets)
                    if PRIMARY_IMPORT_SHEET not in all_sheets:
                        st.error(f"Sheet `{PRIMARY_IMPORT_SHEET}` not found in uploaded file.")
                        st.stop()
                    # Current business requirement: ingest only ProjectTimes.
                    selected_sheets = {PRIMARY_IMPORT_SHEET: all_sheets[PRIMARY_IMPORT_SHEET]}

                if not selected_sheets:
                    st.warning("No sheets left to import after ignore rules.")
                    st.stop()

            except ValueError as e:
                st.error(f"Failed to read workbook: {e}")
                st.stop()
            except Exception as e:
                st.error(f"Error reading file: {e}")
                st.info("Please ensure the file is a valid Excel file (.xlsx/.xls).")
                st.stop()

            st.success(
                f"✅ File loaded successfully: {len(all_sheets)} sheets detected, "
                f"{len(selected_sheets)} selected for import ({PRIMARY_IMPORT_SHEET} only)."
            )

            with st.expander("📋 Sheet overview"):
                preview_rows = []
                for name, frame in selected_sheets.items():
                    preview_rows.append({
                        "Sheet": name,
                        "Rows": int(frame.shape[0]),
                        "Columns": int(frame.shape[1]),
                        "Target table": build_table_name(name)
                    })
                st.dataframe(pd.DataFrame(preview_rows), width='stretch')

            if 'ProjectTimes' in selected_sheets and 'Mitarbeiter' in selected_sheets['ProjectTimes'].columns:
                unique_names = selected_sheets['ProjectTimes']['Mitarbeiter'].dropna().unique()
                unknown_names = [name for name in unique_names if name not in current_mapping]

                if unknown_names:
                    st.warning(f"⚠️ Found {len(unknown_names)} new employees not in settings!")
                    with st.expander("View unknown employees"):
                        st.write(list(unknown_names))
                    st.info("Go to 'User Settings' tab to add their logins.")

            if st.button("🚀 Full Refresh Upload", type="primary"):
                progress_bar = st.progress(0)
                status_text = st.empty()
                run_id = None

                try:
                    status_text.text("Step 1/5: Starting import run...")
                    run_id = start_import_run(uploaded_file.name, ignore_sheets)
                    progress_bar.progress(10)

                    status_text.text("Step 2/5: Full refresh in transaction...")
                    imported = []
                    dropped_count = 0
                    total_rows = 0
                    with engine.begin() as conn:
                        target_tables = [build_table_name(name) for name in selected_sheets.keys()]
                        dropped_count = drop_existing_xl_tables(conn, only_tables=target_tables)
                        total = len(selected_sheets)
                        for idx, (sheet_name, frame) in enumerate(selected_sheets.items(), start=1):
                            table_name = build_table_name(sheet_name)
                            normalized = normalize_dataframe(frame)
                            normalized.to_sql(
                                table_name,
                                conn,
                                if_exists='replace',
                                index=False,
                                method='multi',
                                chunksize=1000
                            )
                            row_count = int(len(normalized))
                            total_rows += row_count
                            imported.append((sheet_name, table_name, row_count))
                            progress_bar.progress(10 + int((idx / max(total, 1)) * 70))

                        status_text.text("Step 3/5: Rebuilding legacy work_logs...")
                        legacy_result = rebuild_work_logs_if_possible(selected_sheets, conn)
                    progress_bar.progress(85)

                    status_text.text("Step 4/5: Writing import log...")
                    finish_import_run(
                        run_id=run_id,
                        status="success",
                        imported_sheet_count=len(imported),
                        imported_row_count=total_rows,
                        dropped_table_count=dropped_count
                    )
                    progress_bar.progress(95)

                    status_text.text("Step 5/5: Finalizing...")
                    progress_bar.progress(100)

                    st.success(
                        f"✅ Full refresh complete (run #{run_id}). "
                        f"Imported {len(imported)} sheet(s), {total_rows} row(s), dropped {dropped_count} old table(s)."
                    )

                    st.dataframe(
                        pd.DataFrame(imported, columns=['Sheet', 'Table', 'Rows']),
                        width='stretch'
                    )

                    if legacy_result is None:
                        st.info("ProjectTimes not found. Legacy table `work_logs` was not rebuilt.")
                    elif legacy_result.get("ok"):
                        st.info(f"Legacy table `work_logs` rebuilt: {legacy_result['rows']} rows.")
                    else:
                        st.warning(
                            "Legacy table `work_logs` not rebuilt. Missing columns in ProjectTimes: "
                            + ", ".join(legacy_result.get("missing", []))
                        )

                    st.balloons()

                except Exception as e:
                    if run_id is not None:
                        finish_import_run(run_id=run_id, status="failed", error_message=str(e))
                    st.error(f"Error during upload: {e}")
                    st.info("All data changes from this run were rolled back.")
                    import traceback
                    with st.expander("View error details"):
                        st.code(traceback.format_exc())

    with tab2:
        st.header("Mapping: Excel Name ↔ Grafana Login")
        st.write("Edit the table below. Changes are saved automatically when you click 'Save'.")

        map_df = pd.DataFrame(list(current_mapping.items()), columns=["Excel Name", "Grafana Login"])

        edited_df = st.data_editor(map_df, num_rows="dynamic", width='stretch')

        if st.button("💾 Save Mapping Settings"):
            new_mapping = dict(zip(edited_df["Excel Name"], edited_df["Grafana Login"]))
            save_mappings(new_mapping)
            st.toast("Settings saved!", icon="✅")
            st.rerun()

    with tab3:
        st.header("Database Status")

        with engine.connect() as conn:
            res = conn.execute(text("SELECT owner_login, COUNT(*) as cnt, MAX(work_date) as last_date FROM work_logs GROUP BY owner_login"))
            stats_df = pd.DataFrame(res.fetchall(), columns=['User', 'Rows', 'Last Date'])

        st.dataframe(stats_df, width='stretch')

        st.divider()
        st.subheader("Danger Zone")

        col_del1, col_del2 = st.columns(2)
        with col_del1:
            date_to_del = st.date_input("Delete data for date:")
            if st.button("🗑️ Delete for selected day"):
                with engine.connect() as conn:
                    conn.execute(
                        text("DELETE FROM work_logs WHERE work_date::date = :target_date"),
                        {"target_date": date_to_del}
                    )
                    conn.commit()
                st.warning(f"Data for {date_to_del} deleted.")
                st.rerun()

        with col_del2:
            if st.button("🔥 CLEAR ENTIRE DATABASE"):
                with engine.connect() as conn:
                    conn.execute(text("TRUNCATE TABLE work_logs"))
                    conn.commit()
                st.error("Database completely cleared.")
                st.rerun()

if 'logged_in' not in st.session_state:
    st.session_state['logged_in'] = False

if not st.session_state['logged_in']:
    login_page()
else:
    main_app()
