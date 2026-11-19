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
        case
            -- Cal is kilocalories. Lowercase cal is not this alias.
            when trim(cast(unit as varchar)) = 'Cal' then 'kcal'
            else case lower(trim(cast(unit as varchar)))
            when 'percent' then '%'
            when 'pct' then '%'
            when 'percentage' then '%'
            when '%' then '%'
            when 'hrs' then 'hours'
            when 'hr' then 'hours'
            when 'hour' then 'hours'
            when 'hours' then 'hours'
            when 'h' then 'hours'
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
            when 'beats per minute' then 'bpm'
            when 'beats/minute' then 'bpm'
            when 'beats/min' then 'bpm'
            when 'bpm' then 'bpm'
            when 'meter' then 'm'
            when 'meters' then 'm'
            when 'metre' then 'm'
            when 'metres' then 'm'
            when 'm' then 'm'
            when 'kilometer' then 'km'
            when 'kilometers' then 'km'
            when 'kilometre' then 'km'
            when 'kilometres' then 'km'
            when 'km' then 'km'
            when 'mile' then 'mile'
            when 'miles' then 'mile'
            when 'mi' then 'mile'
            when 'kilocalorie' then 'kcal'
            when 'kilocalories' then 'kcal'
            when 'kcals' then 'kcal'
            when 'kcal' then 'kcal'
            when 'kilojoule' then 'kj'
            when 'kilojoules' then 'kj'
            when 'kj' then 'kj'
            when 'gram' then 'g'
            when 'grams' then 'g'
            when 'g' then 'g'
            when 'kilogram' then 'kg'
            when 'kilograms' then 'kg'
            when 'kgs' then 'kg'
            when 'kg' then 'kg'
            when 'pound' then 'lb'
            when 'pounds' then 'lb'
            when 'lbs' then 'lb'
            when 'lb' then 'lb'
            when 'millisecond' then 'ms'
            when 'milliseconds' then 'ms'
            when 'msec' then 'ms'
            when 'ms' then 'ms'
            else lower(trim(cast(unit as varchar)))
            end
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

factors as (
    select * from (
        values
            ('s', 'time', 1.0),
            ('min', 'time', 60.0),
            ('hours', 'time', 3600.0),
            ('m', 'length', 1.0),
            ('km', 'length', 1000.0),
            ('mile', 'length', 1609.344),
            ('kcal', 'energy', 1.0),
            ('kj', 'energy', 1.0 / 4.184),
            ('kg', 'mass', 1.0),
            ('g', 'mass', 0.001),
            ('lb', 'mass', 0.45359237),
            ('%', 'ratio', 1.0),
            ('bpm', 'rate', 1.0),
            ('ms', 'ms', 1.0),
            ('count', 'count', 1.0),
            ('score', 'score', 1.0)
    ) as t(unit, family, to_base)
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
            when from_unit.family is not null
                and from_unit.family = to_unit.family
                then casted.value_raw * from_unit.to_base / to_unit.to_base
            else casted.value_raw
        end as value,
        case
            when from_unit.family is not null
                and from_unit.family = to_unit.family
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
    left join factors as from_unit
        on casted.unit_norm = from_unit.unit
    left join factors as to_unit
        on rules.canonical_unit = to_unit.unit
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
