-- Every staged kind, and every kind named in the accepted_values list,
-- needs a health_kind_agg row. The list below is the same set as the
-- staging and mart accepted_values tests.
with accepted as (
    select * from (
        values
            ('sleep_duration_hours'),
            ('sleep_efficiency_pct'),
            ('resting_heart_rate_bpm'),
            ('heart_rate_variability_ms'),
            ('heart_rate'),
            ('steps'),
            ('active_calories_kcal'),
            ('exercise_minutes'),
            ('distance'),
            ('floors'),
            ('weight_kg'),
            ('body_fat_pct'),
            ('readiness_score'),
            ('spo2_pct'),
            ('deep_sleep'),
            ('light_sleep'),
            ('rem_sleep'),
            ('sleep_score'),
            ('stress'),
            ('pai'),
            ('vo2_max')
    ) as kinds(kind)
),

missing_accepted as (
    select accepted.kind
    from accepted
    left join {{ ref('health_kind_agg') }} as rules
        on accepted.kind = rules.kind
    where rules.kind is null
),

missing_staged as (
    select distinct metrics.kind
    from {{ ref('stg_health__metrics') }} as metrics
    left join {{ ref('health_kind_agg') }} as rules
        on metrics.kind = rules.kind
    where rules.kind is null
)

select kind from missing_accepted
union
select kind from missing_staged
