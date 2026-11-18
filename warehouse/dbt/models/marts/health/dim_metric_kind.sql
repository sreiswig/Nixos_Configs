-- One row per metric kind, taken from the latest loaded observation.
-- The date span uses groktor's metrics.day (source_day).

with ranked as (
    select
        *,
        row_number() over (
            partition by kind
            order by _loaded_at desc, recorded_at desc, metric_id desc
        ) as _pick
    from {{ ref('stg_health__metrics') }}
),

counts as (
    select
        kind,
        count(*) as observation_count,
        min(source_day) as first_source_day,
        max(source_day) as last_source_day
    from {{ ref('stg_health__metrics') }}
    group by kind
)

select
    ranked.kind,
    ranked.category,
    ranked.unit,
    counts.observation_count,
    counts.first_source_day,
    counts.last_source_day
from ranked
inner join counts
    on ranked.kind = counts.kind
where ranked._pick = 1
