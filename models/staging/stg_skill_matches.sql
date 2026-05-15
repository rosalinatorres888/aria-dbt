{{ config(materialized='view', tags=['staging', 'aria_pipeline']) }}

with source as (
    select * from {{ source('aria_raw', 'raw_skill_matches') }}
)

select
    match_id,
    posting_id,
    trim(skill_name)     as skill_name,
    skill_category,
    match_strength,
    case
        when match_strength >= 0.90 then 'strong'
        when match_strength >= 0.70 then 'moderate'
        else 'weak'
    end                  as match_strength_tier
from source
