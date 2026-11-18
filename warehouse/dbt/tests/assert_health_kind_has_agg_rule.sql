-- Every kind that landed in staging needs a row in health_kind_agg.
select distinct metrics.kind
from {{ ref('stg_health__metrics') }} as metrics
left join {{ ref('health_kind_agg') }} as rules
    on metrics.kind = rules.kind
where rules.kind is null
