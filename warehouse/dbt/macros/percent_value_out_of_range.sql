-- True when a staged percent row is outside the seed range for its kind.
-- 0 is allowed only when percent_allow_zero is 1.
-- percent_min_exclusive 1 means the low bound is strict (value > percent_min).
-- Otherwise the low bound is inclusive (value >= percent_min).
-- The high bound is always inclusive. Non-percent rows are never out of range.
{% macro percent_value_out_of_range(metrics, rules) %}
(
    {{ rules }}.canonical_unit = '%'
    and {{ metrics }}.unit = '%'
    and not (
        (
            coalesce({{ rules }}.percent_allow_zero, 0) = 1
            and {{ metrics }}.value = 0
        )
        or (
            {{ metrics }}.value <= {{ rules }}.percent_max
            and (
                (
                    coalesce({{ rules }}.percent_min_exclusive, 0) = 1
                    and {{ metrics }}.value > {{ rules }}.percent_min
                )
                or (
                    coalesce({{ rules }}.percent_min_exclusive, 0) = 0
                    and {{ rules }}.percent_min is not null
                    and {{ metrics }}.value >= {{ rules }}.percent_min
                )
            )
        )
    )
)
{% endmacro %}
