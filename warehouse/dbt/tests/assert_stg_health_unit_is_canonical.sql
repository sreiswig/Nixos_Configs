-- After alias and factor conversion, every staged row must use the kind's
-- canonical unit. A mismatch fails the build so it is not summed into
-- fct_health_daily without being noticed.
select
    metrics.metric_id,
    metrics.kind,
    metrics.unit,
    rules.canonical_unit
from {{ ref('stg_health__metrics') }} as metrics
inner join {{ ref('health_kind_agg') }} as rules
    on metrics.kind = rules.kind
where metrics.unit is distinct from rules.canonical_unit
