-- Expected value is computed here, not with arg_max.
-- Latest kinds: the row with the greatest (recorded_at, _loaded_at, metric_id),
-- chosen with ORDER BY ... LIMIT 1.
-- Sum kinds: sum of accepted values, which are already in the canonical unit.
-- Out-of-range percents are not in int_health__metrics_accepted, so they
-- are not part of this expected value. The percent test still sees them
-- on staging.
-- unit and _loaded_at must come from that same winning row.
-- An accepted kind missing from the fact is a failure.

with metrics as (
    select * from {{ ref('int_health__metrics_accepted') }}
),

groups as (
    select distinct source_day, kind
    from metrics
),

winner as (
    select
        groups.source_day,
        groups.kind,
        (
            select metrics.value
            from metrics
            where metrics.source_day = groups.source_day
                and metrics.kind = groups.kind
            order by metrics.recorded_at desc, metrics._loaded_at desc, metrics.metric_id desc
            limit 1
        ) as value,
        (
            select metrics.unit
            from metrics
            where metrics.source_day = groups.source_day
                and metrics.kind = groups.kind
            order by metrics.recorded_at desc, metrics._loaded_at desc, metrics.metric_id desc
            limit 1
        ) as unit,
        (
            select metrics._loaded_at
            from metrics
            where metrics.source_day = groups.source_day
                and metrics.kind = groups.kind
            order by metrics.recorded_at desc, metrics._loaded_at desc, metrics.metric_id desc
            limit 1
        ) as _loaded_at
    from groups
),

sums as (
    select
        source_day,
        kind,
        sum(value) as value_sum
    from metrics
    group by source_day, kind
),

expected as (
    select
        winner.source_day,
        winner.kind,
        rules.agg_rule,
        case
            when rules.agg_rule = 'sum' then sums.value_sum
            else winner.value
        end as value,
        winner.unit,
        winner._loaded_at
    from winner
    inner join {{ ref('health_kind_agg') }} as rules
        on winner.kind = rules.kind
    inner join sums
        on winner.source_day = sums.source_day
        and winner.kind = sums.kind
)

select
    expected.source_day,
    expected.kind,
    expected.value as expected_value,
    actual.value as actual_value,
    expected.unit as expected_unit,
    actual.unit as actual_unit,
    expected._loaded_at as expected_loaded_at,
    actual._loaded_at as actual_loaded_at
from expected
left join {{ ref('fct_health_daily') }} as actual
    on expected.source_day = actual.source_day
    and expected.kind = actual.kind
where actual.source_day is null
    or actual.unit is distinct from expected.unit
    or actual._loaded_at is distinct from expected._loaded_at
    or abs(coalesce(actual.value, 0) - expected.value) > 1e-6
