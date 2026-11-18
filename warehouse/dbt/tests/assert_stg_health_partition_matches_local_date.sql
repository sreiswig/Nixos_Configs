-- Hive dt must match the Chicago local date so partition pruning and
-- fct_health_daily.local_date describe the same day.
select
    metric_id,
    local_date,
    dt
from {{ ref('stg_health__metrics') }}
where local_date <> dt
