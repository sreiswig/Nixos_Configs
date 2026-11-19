-- One row per groktor metrics.day (source_day) and kind.
-- Additive kinds sum every sample. Point-in-time kinds keep the value from
-- one winning row. That row is the latest (recorded_at, _loaded_at, metric_id).
-- unit, local_date, and _loaded_at always come from that same row.
-- value_avg, value_min, and value_max describe every sample in the group.

with rules as (
    select kind, agg_rule, canonical_unit
    from {{ ref('health_kind_agg') }}
),

sampled as (
    select
        metrics.*,
        rules.agg_rule
    from {{ ref('int_health__metrics_accepted') }} as metrics
    inner join rules
        on metrics.kind = rules.kind
        and metrics.unit = rules.canonical_unit
),

ranked as (
    select
        *,
        row_number() over (
            partition by source_day, kind
            order by recorded_at desc, _loaded_at desc, metric_id desc
        ) as _pick
    from sampled
),

winner as (
    select *
    from ranked
    where _pick = 1
),

aggs as (
    select
        source_day,
        kind,
        count(*) as sample_count,
        sum(value) as value_sum,
        avg(value) as value_avg,
        min(value) as value_min,
        max(value) as value_max
    from sampled
    group by source_day, kind
)

select
    winner.source_day || '|' || winner.kind as metric_day_key,
    winner.source_day,
    winner.local_date,
    winner.kind,
    winner.category,
    winner.unit,
    winner.agg_rule,
    case
        when winner.agg_rule = 'sum' then aggs.value_sum
        else winner.value
    end as value,
    aggs.value_avg,
    aggs.value_min,
    aggs.value_max,
    aggs.sample_count,
    winner.source,
    winner.metric_id,
    winner.recorded_at,
    winner._loaded_at
from winner
inner join aggs
    on winner.source_day = aggs.source_day
    and winner.kind = aggs.kind
