{{ config(materialized='view', tags=['staging', 'aria_pipeline']) }}

with source as (
    select * from {{ source('aria_raw', 'raw_sources') }}
)

select
    source_code,
    source_name,
    source_type,
    is_api_based,
    base_url
from source
