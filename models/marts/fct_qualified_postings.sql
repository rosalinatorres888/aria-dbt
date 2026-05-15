{{
  config(
    materialized='table',
    tags=['mart', 'fact'],
    indexes=[
      {'columns': ['posting_id'], 'unique': true},
      {'columns': ['source_code']},
      {'columns': ['posted_date']}
    ]
  )
}}

-- ─────────────────────────────────────────────────────────────────────────────
-- FACT TABLE: fct_qualified_postings
--
-- Grain:   one row per *qualified* job posting (match_score >= 0.50)
-- Purpose: downstream BI / dashboards; daily refresh aligns to ARIA's
--          24/7 scraping cadence.
-- Joins:   conformed dim_source (via source_code).
-- ─────────────────────────────────────────────────────────────────────────────

with postings as (
    select * from {{ ref('stg_postings') }}
    where match_score >= 0.50   -- ARIA's "qualified" threshold
),

skills_agg as (
    select
        posting_id,
        count(*)                                    as skill_match_count,
        count(distinct skill_category)              as skill_category_count,
        round(avg(match_strength), 3)               as avg_skill_match_strength,
        -- string_agg() is the ANSI / DuckDB / Postgres equivalent of
        -- Snowflake's LISTAGG. dbt-utils.string_agg() abstracts this across
        -- warehouses; using native SQL here for transparency.
        string_agg(skill_name, ', ' order by match_strength desc)
                                                    as top_skills_list
    from {{ ref('stg_skill_matches') }}
    group by 1
),

final as (
    select
        p.posting_id,
        p.source_code,
        p.job_title,
        p.company_name,
        p.location_raw,
        p.is_remote,
        p.posted_date,
        p.scraped_at,
        p.days_since_posted,
        p.salary_min,
        p.salary_max,
        p.salary_midpoint,
        p.salary_currency,
        p.match_score,
        p.match_tier,
        p.is_qualified,
        p.description_length_chars,
        -- skill aggregates
        coalesce(s.skill_match_count, 0)            as skill_match_count,
        coalesce(s.skill_category_count, 0)         as skill_category_count,
        s.avg_skill_match_strength,
        s.top_skills_list
    from postings p
    left join skills_agg s using (posting_id)
)

select * from final
