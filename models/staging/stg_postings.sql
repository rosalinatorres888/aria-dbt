{{
  config(
    materialized='view',
    tags=['staging', 'aria_pipeline']
  )
}}

-- Staging layer: 1:1 with the source, but type-cast, renamed, and lightly
-- cleaned. NO business logic — this layer's job is to make raw data trustworthy
-- and consistent for downstream models.

with source as (
    select * from {{ source('aria_raw', 'raw_postings') }}
),

renamed as (
    select
        -- IDs
        posting_id,
        source_code,

        -- Descriptive
        trim(job_title)                              as job_title,
        trim(company)                                as company_name,
        trim(location_raw)                           as location_raw,
        is_remote,

        -- Dates
        posted_date,
        scraped_at,
        date_diff('day', posted_date, scraped_at::date) as days_since_posted,

        -- Compensation (nullable)
        salary_min,
        salary_max,
        coalesce(salary_currency, 'USD')             as salary_currency,
        case
            when salary_min is not null and salary_max is not null
                then (salary_min + salary_max) / 2.0
        end                                          as salary_midpoint,

        -- ARIA pipeline output
        match_score,
        is_qualified,
        raw_description_chars                        as description_length_chars,

        -- Derived bucket for downstream BI
        case
            when match_score >= 0.90 then 'top_tier'
            when match_score >= 0.75 then 'strong'
            when match_score >= 0.50 then 'moderate'
            else 'low'
        end                                          as match_tier

    from source
)

select * from renamed
