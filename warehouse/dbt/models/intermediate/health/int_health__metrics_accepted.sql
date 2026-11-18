-- Staging rows that marts are allowed to use.
-- Out-of-range percent values stay in stg_health__metrics so
-- assert_stg_health_percent_scale can fail the build. They are left out
-- here, which is the exclusion a plain `dbt run` (no tests) applies.
-- Nothing is multiplied by 100.

select metrics.*
from {{ ref('stg_health__metrics') }} as metrics
left join {{ ref('health_kind_agg') }} as rules
    on metrics.kind = rules.kind
where not {{ percent_value_out_of_range('metrics', 'rules') }}
