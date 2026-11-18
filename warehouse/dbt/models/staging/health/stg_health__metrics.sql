-- View over raw health Parquet. Dedupe on the SQLite primary key, keeping
-- the latest _loaded_at so a rerun that appends the same rows does not
-- double-count. source_day is groktor's metrics.day. local_date is the
-- America/Chicago date of recorded_at. Those two can differ in either
-- direction for overnight rows.

with source as (
    select * from {{ source('health', 'metrics') }}
),

casted as (
    select
        cast(id as varchar) as metric_id,
        cast(kind as varchar) as kind,
        cast(category as varchar) as category,
        cast(recorded_at as timestamptz) as recorded_at,
        cast(source_day as date) as source_day,
        cast(dt as date) as dt,
        cast(value as double) as value,
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
        end as unit,
        cast(source as varchar) as source,
        cast(raw_name as varchar) as raw_name,
        cast(notes as varchar) as notes,
        cast(_loaded_at as timestamptz) as _loaded_at,
        cast(_run_id as varchar) as _run_id,
        cast(_source_file as varchar) as _source_file,
        cast(_loader_version as varchar) as _loader_version
    from source
),

with_local as (
    select
        *,
        (recorded_at at time zone '{{ var("local_tz") }}')::date as local_date
    from casted
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
