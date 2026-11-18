-- One row per Chicago-local date and metric kind.
-- When several observations share that grain, keep the latest recorded_at.

with ranked as (
    select
        *,
        row_number() over (
            partition by local_date, kind
            order by recorded_at desc, _loaded_at desc, metric_id desc
        ) as _pick
    from {{ ref('stg_health__metrics') }}
)

select
    local_date || '|' || kind as metric_day_key,
    local_date,
    kind,
    category,
    unit,
    value,
    source,
    metric_id,
    recorded_at,
    _loaded_at
from ranked
where _pick = 1
