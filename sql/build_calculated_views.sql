BEGIN;

DROP VIEW IF EXISTS vw_sub_monthly_total;
CREATE OR REPLACE VIEW vw_sub_monthly_total AS
WITH monthly AS (
    SELECT
        mitarbeiter AS employee_name,
        bereich_neu AS service,
        jahr::int AS year,
        EXTRACT(MONTH FROM datum)::int AS month_num,
        ROUND(SUM(dauer)::numeric, 2) AS total_hours_raw,
        MIN(ma_kat) AS ma_kat_min
    FROM xl_projecttimes
    WHERE ma_kat = 'Sub'
      AND NULLIF(TRIM(mitarbeiter), '') IS NOT NULL
      AND NULLIF(TRIM(bereich_neu), '') IS NOT NULL
    GROUP BY
        mitarbeiter,
        bereich_neu,
        jahr,
        EXTRACT(MONTH FROM datum)
)
SELECT
    employee_name,
    service,
    service AS department,
    year,
    month_num,
    CASE month_num
        WHEN 1 THEN 'Jan'
        WHEN 2 THEN 'Feb'
        WHEN 3 THEN 'Mrz'
        WHEN 4 THEN 'Apr'
        WHEN 5 THEN 'Mai'
        WHEN 6 THEN 'Jun'
        WHEN 7 THEN 'Jul'
        WHEN 8 THEN 'Aug'
        WHEN 9 THEN 'Sep'
        WHEN 10 THEN 'Okt'
        WHEN 11 THEN 'Nov'
        WHEN 12 THEN 'Dez'
    END AS month_name,
    total_hours_raw,
    ROUND(
        CASE
            WHEN ma_kat_min = 'RW' AND total_hours_raw > 9 THEN total_hours_raw - 0.75
            WHEN ma_kat_min = 'RW' AND total_hours_raw > 6 THEN total_hours_raw - 0.5
            ELSE total_hours_raw
        END,
        2
    ) AS total_hours
FROM monthly;

CREATE OR REPLACE VIEW vw_man_day_daily AS
SELECT
    work_date::date AS work_day,
    EXTRACT(YEAR FROM work_date)::int AS year,
    EXTRACT(MONTH FROM work_date)::int AS month_num,
    TO_CHAR(work_date, 'Mon') AS month_name,
    ROUND((SUM(duration) / 8.0)::numeric, 2) AS man_day
FROM work_logs
GROUP BY
    work_date::date,
    EXTRACT(YEAR FROM work_date),
    EXTRACT(MONTH FROM work_date),
    TO_CHAR(work_date, 'Mon');

CREATE OR REPLACE VIEW vw_man_day_monthly AS
SELECT
    DATE_TRUNC('month', work_date)::date AS month_start,
    EXTRACT(YEAR FROM work_date)::int AS year,
    EXTRACT(MONTH FROM work_date)::int AS month_num,
    TO_CHAR(work_date, 'Mon') AS month_name,
    ROUND((SUM(duration) / 8.0)::numeric, 1) AS man_day
FROM work_logs
GROUP BY
    DATE_TRUNC('month', work_date)::date,
    EXTRACT(YEAR FROM work_date),
    EXTRACT(MONTH FROM work_date),
    TO_CHAR(work_date, 'Mon');

COMMIT;
