-- Every percent kind needs an explicit seed range. A blank bound would
-- make the exclusion and the alarm disagree.
select
    kind,
    canonical_unit,
    percent_min,
    percent_max
from {{ ref('health_kind_agg') }}
where canonical_unit = '%'
    and (
        percent_min is null
        or percent_max is null
        or percent_allow_zero is null
        or percent_min_exclusive is null
    )
