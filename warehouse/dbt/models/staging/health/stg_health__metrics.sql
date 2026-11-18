-- View over raw health Parquet. Dedupe on the SQLite primary key, keeping
-- the latest _loaded_at so a rerun that appends the same rows does not
-- double-count. source_day is groktor's metrics.day. local_date is the
-- America/Chicago date of recorded_at. Those two can differ in either
-- direction for overnight rows.
--
-- Unit aliases are renamed and, for time units, converted into the kind's
-- canonical unit from health_kind_agg (seconds become minutes or hours,
-- hours become minutes, and the value changes with the unit).

with source as (
    select * from {{ source('health', 'metrics') }}
),

rules as (
    select kind, canonical_unit
    from {{ ref('health_kind_agg') }}
),

casted as (
    select
        cast(id as varchar) as metric_id,
        cast(kind as varchar) as kind,
        cast(category as varchar) as category,
        cast(recorded_at as timestamptz) as recorded_at,
        cast(source_day as date) as source_day,
        cast(dt as date) as dt,
        cast(value as double) as value_raw,
        case lower(trim(cast(unit as varchar)))
            when 'percent' then '%'
            when 'pct' then '%'
            when '%' then '%'
            when 'hrs' then 'hours'
            when 'hr' then 'hours'
            when 'hour' then 'hours'
            when 'hours' then 'hours'
            when 'minutes' then 'min'
            when 'minute' then 'min'
            when 'mins' then 'min'
            when 'min' then 'min'
            when 'steps' then 'count'
            when 'step' then 'count'
            when 'sec' then 's'
            when 'secs' then 's'
            when 'second' then 's'
            when 'seconds' then 's'
            else lower(trim(cast(unit as varchar)))
        end as unit_norm,
        cast(source as varchar) as source,
        cast(raw_name as varchar) as raw_name,
        cast(notes as varchar) as notes,
        cast(_loaded_at as timestamptz) as _loaded_at,
        cast(_run_id as varchar) as _run_id,
        cast(_source_file as varchar) as _source_file,
        cast(_loader_version as varchar) as _loader_version
    from source
),

converted as (
    select
        casted.metric_id,
        casted.kind,
        casted.category,
        casted.recorded_at,
        casted.source_day,
        casted.dt,
        case
            when rules.canonical_unit in ('s', 'min', 'hours')
                and casted.unit_norm in ('s', 'min', 'hours')
                and casted.unit_norm = 's' and rules.canonical_unit = 'min'
                then casted.value_raw / 60.0
            when rules.canonical_unit in ('s', 'min', 'hours')
                and casted.unit_norm in ('s', 'min', 'hours')
                and casted.unit_norm = 's' and rules.canonical_unit = 'hours'
                then casted.value_raw / 3600.0
            when rules.canonical_unit in ('s', 'min', 'hours')
                and casted.unit_norm in ('s', 'min', 'hours')
                and casted.unit_norm = 'min' and rules.canonical_unit = 'hours'
                then casted.value_raw / 60.0
            when rules.canonical_unit in ('s', 'min', 'hours')
                and casted.unit_norm in ('s', 'min', 'hours')
                and casted.unit_norm = 'min' and rules.canonical_unit = 's'
                then casted.value_raw * 60.0
            when rules.canonical_unit in ('s', 'min', 'hours')
                and casted.unit_norm in ('s', 'min', 'hours')
                and casted.unit_norm = 'hours' and rules.canonical_unit = 'min'
                then casted.value_raw * 60.0
            when rules.canonical_unit in ('s', 'min', 'hours')
                and casted.unit_norm in ('s', 'min', 'hours')
                and casted.unit_norm = 'hours' and rules.canonical_unit = 's'
                then casted.value_raw * 3600.0
            else casted.value_raw
        end as value,
        case
            when rules.canonical_unit in ('s', 'min', 'hours')
                and casted.unit_norm in ('s', 'min', 'hours')
                then rules.canonical_unit
            else casted.unit_norm
        end as unit,
        casted.source,
        casted.raw_name,
        casted.notes,
        casted._loaded_at,
        casted._run_id,
        casted._source_file,
        casted._loader_version
    from casted
    left join rules
        on casted.kind = rules.kind
),

with_local as (
    select
        *,
        (recorded_at at time zone '{{ var("local_tz") }}')::date as local_date
    from converted
),

ranked as (
    select
        *,
        row_number() over (
            partition by metric_id
            order by _loaded_at desc, _run_id desc
        ) as _dedupe_rank
    from with_local
)

select
    metric_id,
    kind,
    category,
    recorded_at,
    source_day,
    local_date,
    dt,
    value,
    unit,
    source,
    raw_name,
    notes,
    _loaded_at,
    _run_id,
    _source_file,
    _loader_version
from ranked
where _dedupe_rank = 1
