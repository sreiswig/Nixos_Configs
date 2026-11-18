-- Percent kinds use the seed range, not one global cutoff.
-- body_fat_pct and sleep_efficiency_pct allow 0 and values from 1 through 100.
-- A fraction such as 0.2 is still out of range for those kinds.
-- spo2_pct allows only values greater than 1 and at most 100.
-- The row stays in staging. int_health__metrics_accepted drops it, so
-- fct_health_daily does not take it even when tests are skipped.
select
    metrics.metric_id,
    metrics.kind,
    metrics.value,
    metrics.unit
from {{ ref('stg_health__metrics') }} as metrics
inner join {{ ref('health_kind_agg') }} as rules
    on metrics.kind = rules.kind
where {{ percent_value_out_of_range('metrics', 'rules') }}
