-- value follows the seed: sum of samples, or the latest recorded_at.
with expected as (
    select
        metrics.source_day,
        metrics.kind,
        rules.agg_rule,
        case
            when rules.agg_rule = 'sum' then sum(metrics.value)
            else arg_max(metrics.value, metrics.recorded_at)
        end as value
    from {{ ref('stg_health__metrics') }} as metrics
    inner join {{ ref('health_kind_agg') }} as rules
        on metrics.kind = rules.kind
    group by metrics.source_day, metrics.kind, rules.agg_rule
)

select
    expected.source_day,
    expected.kind,
    expected.value as expected_value,
    actual.value as actual_value
from expected
inner join {{ ref('fct_health_daily') }} as actual
    on expected.source_day = actual.source_day
    and expected.kind = actual.kind
where abs(expected.value - actual.value) > 1e-6
