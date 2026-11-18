-- One row per metric kind, taken from the latest loaded observation
-- whose unit is that kind's canonical unit (aliases are already renamed
-- in staging). A mismatched unit is left out and fails
-- assert_dim_metric_kind_unit / assert_stg_health_unit_is_canonical.
-- The date span uses groktor's metrics.day (source_day).

with eligible as (
    select metrics.*
    from {{ ref('stg_health__metrics') }} as metrics
    inner join {{ ref('health_kind_agg') }} as rules
        on metrics.kind = rules.kind
        and metrics.unit = rules.canonical_unit
),

ranked as (
    select
        *,
        row_number() over (
            partition by kind
            order by _loaded_at desc, recorded_at desc, metric_id desc
        ) as _pick
    from eligible
),

counts as (
    select
        kind,
        count(*) as observation_count,
        min(source_day) as first_source_day,
        max(source_day) as last_source_day
    from eligible
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
