-- Singular test: every row in fct_qualified_postings must clear the 0.50
-- match_score threshold. Returns rows that violate the invariant; dbt fails
-- the test if the result set is non-empty.
--
-- This is a *data invariant* — not a column-level constraint — so it lives
-- in tests/ rather than schema.yml.

select
    posting_id,
    match_score
from {{ ref('fct_qualified_postings') }}
where match_score < 0.50
   or match_score is null
