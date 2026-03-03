import streamlit as st
import pandas as pd
from sqlalchemy import create_engine, text
import os
import json

st.set_page_config(page_title="Admin Panel", layout="wide")

DB_URL = os.getenv("DATABASE_URL", "postgresql://admin:secretpassword@localhost:5432/analytics_db")
engine = create_engine(DB_URL)
MAPPING_FILE = 'mappings.json'

ADMIN_CREDENTIALS = {"admin": "admin123"}

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

        if uploaded_file:
            try:
                with st.spinner('Reading Excel file...'):
                    df = pd.read_excel(uploaded_file, sheet_name='ProjectTimes', engine='openpyxl')

                if df.empty:
                    st.warning("The uploaded file contains no data in 'ProjectTimes' sheet.")
                    st.stop()

            except ValueError as e:
                st.error(f"Sheet 'ProjectTimes' not found in the file. Available sheets might be different. Error: {e}")
                st.stop()
            except Exception as e:
                st.error(f"Error reading file: {e}")
                st.info("Please ensure the file is a valid Excel file (.xlsx) with a 'ProjectTimes' sheet.")
                st.stop()

            st.success(f"✅ File loaded successfully: {len(df)} rows, {len(df.columns)} columns")

            with st.expander("📋 View column names"):
                st.write(list(df.columns))

            if 'Mitarbeiter' in df.columns:
                unique_names = df['Mitarbeiter'].unique()
                unknown_names = [name for name in unique_names if name not in current_mapping]

                if unknown_names:
                    st.warning(f"⚠️ Found {len(unknown_names)} new employees not in settings!")
                    with st.expander("View unknown employees"):
                        st.write(list(unknown_names))
                    st.info("Go to 'User Settings' tab to add their logins.")
            else:
                st.error("Column 'Mitarbeiter' not found in the Excel file!")

            if st.button("🚀 Process and Upload", type="primary"):
                progress_bar = st.progress(0)
                status_text = st.empty()

                try:
                    status_text.text("Step 1/4: Validating columns...")
                    progress_bar.progress(25)

                    required_cols = {
                        'Datum': 'work_date', 'Dauer': 'duration', 'Bereich': 'department',
                        'Projekt-Nr.': 'project_number', 'Task_new': 'activity_type',
                        'Mitarbeiter': 'employee_name', 'Bemerkung': 'description'
                    }

                    missing_cols = [col for col in required_cols.keys() if col not in df.columns]
                    if missing_cols:
                        st.error(f"Missing required columns: {', '.join(missing_cols)}")
                        st.stop()

                    df_clean = df[list(required_cols.keys())].rename(columns=required_cols)

                    status_text.text("Step 2/4: Mapping employee names...")
                    progress_bar.progress(50)
                    df_clean['owner_login'] = df_clean['employee_name'].map(current_mapping).fillna('unassigned')

                    status_text.text("Step 3/4: Clearing old data for this period...")
                    progress_bar.progress(75)
                    min_d, max_d = df_clean['work_date'].min(), df_clean['work_date'].max()

                    with engine.connect() as conn:
                        result = conn.execute(text(f"DELETE FROM work_logs WHERE work_date >= '{min_d}' AND work_date <= '{max_d}'"))
                        conn.commit()
                        deleted_rows = result.rowcount
                        st.info(f"Deleted {deleted_rows} old records for period {min_d} to {max_d}")

                    status_text.text(f"Step 4/4: Uploading {len(df_clean)} records...")
                    progress_bar.progress(90)

                    chunk_size = 1000
                    for i in range(0, len(df_clean), chunk_size):
                        chunk = df_clean.iloc[i:i+chunk_size]
                        chunk.to_sql('work_logs', engine, if_exists='append', index=False)

                    progress_bar.progress(100)
                    status_text.text("Complete!")

                    st.success(f"✅ Successfully uploaded {len(df_clean)} records!")
                    st.balloons()

                except Exception as e:
                    st.error(f"Error during upload: {e}")
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
                    conn.execute(text(f"DELETE FROM work_logs WHERE work_date = '{date_to_del}'"))
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
