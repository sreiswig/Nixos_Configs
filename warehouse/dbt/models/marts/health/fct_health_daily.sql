-- One row per groktor metrics.day (source_day) and kind.
-- Additive kinds sum every sample. Point-in-time kinds keep the latest
-- recorded_at and still expose avg, min, and max of the samples.
-- The rule list is the seed health_kind_agg.

with rules as (
    select kind, agg_rule
    from {{ ref('health_kind_agg') }}
),

sampled as (
    select
        metrics.*,
        rules.agg_rule
    from {{ ref('stg_health__metrics') }} as metrics
    inner join rules
        on metrics.kind = rules.kind
),

grouped as (
    select
        source_day,
        kind,
        any_value(agg_rule) as agg_rule,
        count(*) as sample_count,
        sum(value) as value_sum,
        avg(value) as value_avg,
        min(value) as value_min,
        max(value) as value_max,
        arg_max(value, recorded_at) as value_latest,
        arg_max(local_date, recorded_at) as local_date,
        arg_max(category, recorded_at) as category,
        arg_max(unit, recorded_at) as unit,
        arg_max(source, recorded_at) as source,
        arg_max(metric_id, recorded_at) as metric_id,
        max(recorded_at) as recorded_at,
        max(_loaded_at) as _loaded_at
    from sampled
    group by source_day, kind
)

select
    source_day || '|' || kind as metric_day_key,
    source_day,
    local_date,
    kind,
    category,
    unit,
    agg_rule,
    case
        when agg_rule = 'sum' then value_sum
        else value_latest
    end as value,
    value_avg,
    value_min,
    value_max,
    sample_count,
    source,
    metric_id,
    recorded_at,
    _loaded_at
from grouped
