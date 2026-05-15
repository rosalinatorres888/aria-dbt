{{
  config(
    materialized='table',
    tags=['mart', 'analytics']
  )
}}

-- ─────────────────────────────────────────────────────────────────────────────
-- ANALYTICS MART: mart_skill_demand
--
-- Grain:   one row per (skill, skill_category)
-- Purpose: directly answers ARIA's North Star question — "which skills are
--          most in-demand across the qualified market today?" This is the
--          mart that powers the Streamlit dashboard end users actually see.
-- ─────────────────────────────────────────────────────────────────────────────

with qualified as (
    select posting_id from {{ ref('fct_qualified_postings') }}
),

skill_matches as (
    select
        sm.skill_name,
        sm.skill_category,
        sm.match_strength,
        sm.match_strength_tier
    from {{ ref('stg_skill_matches') }} sm
    inner join qualified q using (posting_id)
),

ranked as (
    select
        skill_name,
        skill_category,
        count(*)                                            as demand_count,
        round(avg(match_strength), 3)                       as avg_match_strength,
        sum(case when match_strength_tier = 'strong' then 1 else 0 end) as strong_signal_count
    from skill_matches
    group by 1, 2
)

select
    skill_name,
    skill_category,
    demand_count,
    avg_match_strength,
    strong_signal_count,
    rank() over (order by demand_count desc) as demand_rank,
    rank() over (partition by skill_category order by demand_count desc)
        as demand_rank_in_category
from ranked
