CREATE OR REPLACE TABLE `digital-analytics-portfolio.leaky_funnel_analysis.funnel_attribution` AS

WITH raw_extracted_events AS (
  -- PHASE 1A: Raw extraction and session tokenization
  SELECT
    PARSE_DATE('%Y%m%d', event_date) AS event_date,
    TIMESTAMP_MICROS(event_timestamp) AS event_timestamp,
    user_pseudo_id,

    CONCAT(
      COALESCE(user_pseudo_id, 'unknown_user'), 
      '_', 
      COALESCE(CAST((SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS STRING), 'unknown_session')
    ) AS unique_session_id,

    event_name,

    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'source') AS raw_source,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'medium') AS raw_medium,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'campaign') AS raw_campaign,

    ecommerce.purchase_revenue AS purchase_revenue
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    event_name IN ('session_start', 'view_item', 'add_to_cart', 'begin_checkout', 'purchase')
    AND _TABLE_SUFFIX BETWEEN '20210101' AND '20210131'
),

stg_ga4_events AS (
  -- PHASE 1B: Broadcast traffic sources horizontally across the session
  SELECT
    event_date,
    event_timestamp,
    unique_session_id,
    event_name,
    MAX(raw_source) OVER(PARTITION BY unique_session_id) AS session_source,
    MAX(raw_medium) OVER(PARTITION BY unique_session_id) AS session_medium,
    MAX(raw_campaign) OVER(PARTITION BY unique_session_id) AS session_campaign,
    purchase_revenue
  FROM
    raw_extracted_events
),

session_milestones AS (
  -- PHASE 2: Funnel Sequencing (flatten events into a single-row milestone ledger)
  SELECT
    unique_session_id,
    LOWER(session_source) AS session_source, 
    LOWER(session_medium) AS session_medium,
    LOWER(session_campaign) AS session_campaign,

    MIN(CASE WHEN event_name = 'session_start' THEN event_timestamp END) AS t_session_start,
    MIN(CASE WHEN event_name = 'view_item' THEN event_timestamp END) AS t_view_item,
    MIN(CASE WHEN event_name = 'add_to_cart' THEN event_timestamp END) AS t_add_to_cart,
    MIN(CASE WHEN event_name = 'begin_checkout' THEN event_timestamp END) AS t_begin_checkout,
    MIN(CASE WHEN event_name = 'purchase' THEN event_timestamp END) AS t_purchase,

    MAX(purchase_revenue) AS session_revenue
  FROM
    stg_ga4_events
  GROUP BY
    1, 2, 3, 4
),

flattened_flags AS (
  -- PHASE 3A: Clean channel mapping, date extraction, chronological filtering
  SELECT 
    unique_session_id,
    DATE(t_session_start) AS session_date,
    COALESCE(session_campaign, 'none') AS session_campaign,
    COALESCE(session_revenue, 0) AS total_revenue,
    CASE
      WHEN session_source = '(direct)' AND (session_medium IN ('(not set)', '(none)')) THEN 'Direct'
      WHEN session_medium = 'organic' THEN 'Organic Search'
      WHEN session_medium LIKE '%cpc%' OR session_medium LIKE '%ppc%' THEN 'Paid Search'
      WHEN session_source IN ('facebook', 'instagram', 'tiktok', 'twitter', 'ig') THEN 'Social'
      WHEN session_medium = 'referral' THEN 'Referral'
      WHEN session_medium = 'email' THEN 'Email'
      ELSE 'None'
    END AS clean_channel,
    CASE WHEN t_session_start IS NOT NULL THEN 1 ELSE 0 END AS funnel_step_1_start,
    CASE WHEN t_view_item IS NOT NULL AND t_view_item >= t_session_start THEN 1 ELSE 0 END AS funnel_step_2_view,
    CASE WHEN t_add_to_cart IS NOT NULL AND t_add_to_cart >= t_view_item THEN 1 ELSE 0 END AS funnel_step_3_cart,
    CASE WHEN t_begin_checkout IS NOT NULL AND t_begin_checkout >= t_add_to_cart THEN 1 ELSE 0 END AS funnel_step_4_checkout,
    CASE WHEN t_purchase IS NOT NULL AND t_purchase >= t_begin_checkout THEN 1 ELSE 0 END AS funnel_step_5_purchase
  FROM session_milestones
),

melted_steps AS (
  -- PHASE 3B: Pivot wide funnel flags into long rows (one row per session per stage)
  SELECT
    f.unique_session_id,
    f.session_date,
    f.clean_channel,
    f.session_campaign,
    f.total_revenue,
    step_data.step_number,
    step_data.funnel_stage,
    step_data.is_active
  FROM flattened_flags f
  CROSS JOIN UNNEST([
    STRUCT(1 AS step_number, '1. Sessions' AS funnel_stage, f.funnel_step_1_start AS is_active),
    STRUCT(2 AS step_number, '2. Product Search' AS funnel_stage, f.funnel_step_2_view AS is_active),
    STRUCT(3 AS step_number, '3. Add to Cart' AS funnel_stage, f.funnel_step_3_cart AS is_active),
    STRUCT(4 AS step_number, '4. Initiated Checkout' AS funnel_stage, f.funnel_step_4_checkout AS is_active),
    STRUCT(5 AS step_number, '5. Purchase' AS funnel_stage, f.funnel_step_5_purchase AS is_active)
  ]) AS step_data
),

aggregated_stages AS (
  -- PHASE 4: Summary aggregation by date, channel, campaign, and stage
  SELECT
    session_date,
    clean_channel,
    session_campaign,
    step_number,
    funnel_stage,
    SUM(is_active) AS active_users,
    SUM(total_revenue * is_active) AS stage_revenue
  FROM melted_steps
  GROUP BY 1, 2, 3, 4, 5
)

-- FINAL OUTPUT: single table powering every chart on the dashboard
SELECT
  session_date,
  clean_channel,
  session_campaign,
  step_number,
  funnel_stage,
  active_users,
  stage_revenue,
  CASE 
    WHEN step_number = 1 THEN 1.0
    ELSE SAFE_DIVIDE(active_users, LAG(active_users, 1) OVER (PARTITION BY clean_channel, session_campaign, session_date ORDER BY step_number ASC))
  END AS step_conversion_rate
FROM aggregated_stages;
