-- Warn when groktor's metrics.day and the Chicago date of recorded_at
-- disagree. Overnight rows can land on either neighboring day.
{{ config(severity='warn') }}

select
    metric_id,
    source_day,
    local_date
from {{ ref('stg_health__metrics') }}
where local_date <> source_day
