-- One row per metric kind, taken from the latest loaded observation.

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
        min(local_date) as first_local_date,
        max(local_date) as last_local_date
    from {{ ref('stg_health__metrics') }}
    group by kind
)

select
    ranked.kind,
    ranked.category,
    ranked.unit,
    counts.observation_count,
    counts.first_local_date,
    counts.last_local_date
from ranked
inner join counts
    on ranked.kind = counts.kind
where ranked._pick = 1
