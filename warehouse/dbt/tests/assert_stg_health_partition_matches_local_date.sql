-- The loader's hive dt is the America/Chicago date of recorded_at, which
-- staging also stores as local_date. source_day is a separate column.
select
    metric_id,
    local_date,
    dt
from {{ ref('stg_health__metrics') }}
where local_date <> dt
