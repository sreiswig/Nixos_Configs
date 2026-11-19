-- A kind on the dimension must use its seed canonical unit.
-- Unknown or mismatched units fail this test instead of being stored.
select
    dim.kind,
    dim.unit,
    rules.canonical_unit
from {{ ref('dim_metric_kind') }} as dim
inner join {{ ref('health_kind_agg') }} as rules
    on dim.kind = rules.kind
where dim.unit is distinct from rules.canonical_unit
