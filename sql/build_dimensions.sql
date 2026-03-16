-- Dimension rebuild script for Grafana reference dashboards.
-- Sources:
--   xl_emp_241001 (employee directory)
--   xl_projecttimes (project and activity facts)
--   xl_data (task/task_new mapping)
--   work_logs (resolved employee -> owner_login mapping)

BEGIN;

DROP TABLE IF EXISTS dim_employee;
CREATE TABLE dim_employee AS
WITH wl_map AS (
    SELECT
        employee_name,
        MAX(owner_login) AS owner_login
    FROM work_logs
    GROUP BY employee_name
)
SELECT
    ROW_NUMBER() OVER (ORDER BY COALESCE(e.name, wl.employee_name, e.benutzername)) AS employee_id,
    COALESCE(e.name, wl.employee_name) AS employee_name,
    COALESCE(wl.owner_login, NULLIF(e.benutzername, '')) AS owner_login,
    NULLIF(e.vorname, '') AS first_name,
    NULLIF(e.nachname, '') AS last_name,
    NULLIF(e.kurzzeichen, '') AS initials,
    NULLIF(e.dept, '') AS dept,
    NULLIF(e.status, '') AS status
FROM xl_emp_241001 e
FULL OUTER JOIN wl_map wl
    ON wl.employee_name = e.name;

CREATE INDEX idx_dim_employee_name ON dim_employee(employee_name);
CREATE INDEX idx_dim_employee_login ON dim_employee(owner_login);

DROP TABLE IF EXISTS dim_project;
CREATE TABLE dim_project AS
SELECT DISTINCT
    NULLIF(projekt_nr, '') AS project_number,
    NULLIF(projektbezeichnung, '') AS project_name,
    NULLIF(abteilung, '') AS department_source,
    NULLIF(bereich, '') AS department_area,
    NULLIF(bereich_neu, '') AS department_area_normalized,
    NULLIF(ort, '') AS location
FROM xl_projecttimes
WHERE NULLIF(projekt_nr, '') IS NOT NULL;

CREATE INDEX idx_dim_project_number ON dim_project(project_number);
CREATE INDEX idx_dim_project_area ON dim_project(department_area_normalized);

DROP TABLE IF EXISTS dim_activity;
CREATE TABLE dim_activity AS
WITH data_map AS (
    SELECT DISTINCT
        NULLIF(task, '') AS task,
        NULLIF(task_new, '') AS task_new,
        NULLIF(ttq_project, '') AS ttq_project,
        NULLIF(ttq_category, '') AS ttq_category,
        NULLIF(kurzform, '') AS short_code,
        NULLIF(bezeichnung, '') AS description
    FROM xl_data
),
facts AS (
    SELECT DISTINCT
        NULLIF(vorgang, '') AS task,
        NULLIF(task_new, '') AS task_new
    FROM xl_projecttimes
)
SELECT DISTINCT
    COALESCE(d.task, f.task) AS task,
    COALESCE(d.task_new, f.task_new) AS task_new,
    d.ttq_project,
    d.ttq_category,
    d.short_code,
    d.description
FROM facts f
FULL OUTER JOIN data_map d
    ON d.task = f.task
    AND COALESCE(d.task_new, '') = COALESCE(f.task_new, '')
WHERE COALESCE(d.task, f.task, d.task_new, f.task_new) IS NOT NULL;

CREATE INDEX idx_dim_activity_task ON dim_activity(task);
CREATE INDEX idx_dim_activity_task_new ON dim_activity(task_new);

DROP TABLE IF EXISTS dim_calendar;
CREATE TABLE dim_calendar AS
WITH bounds AS (
    SELECT MIN(work_date) AS min_date, MAX(work_date) AS max_date
    FROM work_logs
),
days AS (
    SELECT generate_series(
        (SELECT min_date FROM bounds),
        (SELECT max_date FROM bounds),
        INTERVAL '1 day'
    )::date AS day_date
)
SELECT
    day_date,
    EXTRACT(YEAR FROM day_date)::int AS year_num,
    EXTRACT(QUARTER FROM day_date)::int AS quarter_num,
    EXTRACT(MONTH FROM day_date)::int AS month_num,
    TO_CHAR(day_date, 'Month') AS month_name,
    EXTRACT(WEEK FROM day_date)::int AS week_num,
    EXTRACT(ISODOW FROM day_date)::int AS iso_day_of_week,
    TO_CHAR(day_date, 'Dy') AS day_name_short,
    (EXTRACT(ISODOW FROM day_date) IN (6, 7)) AS is_weekend,
    (EXTRACT(ISODOW FROM day_date) NOT IN (6, 7)) AS is_workday
FROM days;

CREATE INDEX idx_dim_calendar_day ON dim_calendar(day_date);
CREATE INDEX idx_dim_calendar_year_month ON dim_calendar(year_num, month_num);

COMMIT;
