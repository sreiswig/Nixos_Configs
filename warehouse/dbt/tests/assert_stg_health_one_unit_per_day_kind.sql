-- After canonical conversion, one (source_day, kind) must not mix units.
-- A mix would make a sum add minutes to seconds.
select
    source_day,
    kind,
    count(distinct unit) as unit_count
from {{ ref('stg_health__metrics') }}
group by source_day, kind
having count(distinct unit) > 1
