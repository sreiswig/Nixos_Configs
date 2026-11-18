-- Percent kinds are stored on a 0-100 scale. A value labeled %
-- (after alias rename) must be greater than 1 and at most 100.
-- A fraction such as 0.2 is a failed row. Do not multiply it by 100.
select
    metrics.metric_id,
    metrics.kind,
    metrics.value,
    metrics.unit
from {{ ref('stg_health__metrics') }} as metrics
inner join {{ ref('health_kind_agg') }} as rules
    on metrics.kind = rules.kind
where rules.canonical_unit = '%'
    and metrics.unit = '%'
    and not (metrics.value > 1 and metrics.value <= 100)
