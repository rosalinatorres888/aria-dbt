{{
  config(
    materialized='table',
    tags=['mart', 'dimension']
  )
}}

-- ─────────────────────────────────────────────────────────────────────────────
-- DIMENSION: dim_source_performance
--
-- Grain:   one row per scraping source (LINKEDIN, INDEED, GREENHOUSE, …)
-- Purpose: enriched dimension answering "which source delivers the highest-
--          quality job leads?" — feeds dashboard pages and pipeline tuning.
-- Notes:   this is a *conformed dimension* — joins to fct_qualified_postings
--          on source_code. Pre-aggregating the metrics here keeps BI tools
--          fast and avoids correlated subqueries downstream.
-- ─────────────────────────────────────────────────────────────────────────────

with sources as (
    select * from {{ ref('stg_sources') }}
),

posting_stats as (
    select
        source_code,
        count(*)                                                as total_postings_scraped,
        sum(case when is_qualified then 1 else 0 end)           as qualified_postings,
        round(avg(match_score), 3)                              as avg_match_score,
        round(max(match_score), 3)                              as best_match_score,
        round(
            avg(case when is_remote then 1 else 0 end), 3
        )                                                       as remote_share,
        round(avg(salary_midpoint), 0)                          as avg_salary_midpoint_usd,
        round(avg(days_since_posted), 1)                        as avg_days_since_posted
    from {{ ref('stg_postings') }}
    group by 1
),

final as (
    select
        s.source_code,
        s.source_name,
        s.source_type,
        s.is_api_based,
        s.base_url,
        coalesce(ps.total_postings_scraped, 0)                  as total_postings_scraped,
        coalesce(ps.qualified_postings, 0)                      as qualified_postings,
        case
            when coalesce(ps.total_postings_scraped, 0) = 0 then 0
            else round(
                ps.qualified_postings * 1.0 / ps.total_postings_scraped, 3
            )
        end                                                     as qualified_rate,
        ps.avg_match_score,
        ps.best_match_score,
        ps.remote_share,
        ps.avg_salary_midpoint_usd,
        ps.avg_days_since_posted,
        -- Ranking dimension attribute — lets BI tools sort with no extra logic
        rank() over (order by ps.avg_match_score desc nulls last) as source_quality_rank
    from sources s
    left join posting_stats ps using (source_code)
)

select * from final
