# E-Commerce Checkout Friction & Marketing Attribution
<p align="center">
  <a href=https://datastudio.google.com/reporting/03d92539-57f4-462f-a22a-b42da8674bfe>
    <img src="https://img.shields.io/badge/View%20Live%20Dashboard-Looker%20Studio-4285F4?style=for-the-badge&logo=looker&logoColor=white" />
  </a>
  <a href=https://medium.com/@gabrielblessing381/e-commerce-checkout-friction-marketing-attribution-738051b32d62?sharedUserId=gabrielblessing381>
    <img src="https://img.shields.io/badge/Read%20Full%20Article-Medium-000000?style=for-the-badge&logo=medium&logoColor=white" />
  </a>
</p>

# The Problem Statement

The online store is losing significant revenue because too many potential customers drop off right before checkout, while broken data tracking makes it impossible to see which marketing channels actually drive sales.

## Project Scope & Objectives

Using real, anonymized session data from Google’s public GA4 dataset on BigQuery, this project focuses on two high-impact goals:

Recover Lost Revenue: Locate exactly where high-intent shoppers are dropping off before checkout to unlock trapped sales.
Stop Wasted Marketing Spend: Audit the tracking infrastructure to find out which traffic data can be trusted for profitable business decisions.


**Stakeholder relevance:** Growth/UX teams need to know where to focus conversion efforts. Marketing teams need to know whether their channel-performance data is reliable enough to act on.



## 2. Data Structure

**Source:** `bigquery-public-data.ga4_obfuscated_sample_ecommerce`, Jan 1–31, 2021

**Pipeline:** Built entirely in BigQuery SQL as a 6-stage chained-CTE pipeline — no dbt or orchestration tooling, structured for readability and staged debugging.

| Stage | Purpose |
|---|---|
| `raw_extracted_events` | Cleans dates/timestamps, extracts nested `event_params`, builds a collision-safe session ID |
| `ga4_events` | Fills the attribution gap — GA4 only stamps source/medium on a session's first event |
| `session_milestones` | Collapses event-level rows into one row per session with milestone timestamps |
| `flattened_flags` | Converts timestamps into funnel-step flags + clean channel classification |
| `melted_steps` | Unpivots sessions into one row per session per stage, for funnel charting |
| `aggregated_stages` | Final rollup — totals, revenue by stage, and step-over-step conversion rates |

**Output:** One materialized table, `funnel_attribution`, powering the entire Looker Studio dashboard.

Full CTE-by-CTE breakdown with code: [`/sql/funnel_attribution.sql`](./sql/funnel_attribution.sql) · Full technical reasoning: [Medium article](#)



## 3. Executive Summary

| KPI | Value |
|---|---|
| Overall conversion rate | 0.96% |
| Cart-to-checkout abandonment | **66.8%** |
| Checkout completion rate | 74.1% |
| Attribution coverage | 8% (92% of sessions unattributed) |

Out of every 100 sessions, fewer than 1 results in a purchase. The steepest drop happens early, before most sessions reach a product view but the more actionable leak is deeper in the funnel: **two-thirds of users who add an item to their cart abandon before checkout starts**, even though checkout itself converts above 70% once begun. The leak isn't checkout — it's whatever happens right before it.

Underneath this, marketing attribution is only possible for a small fraction of sessions. The remaining 92% carry no traffic-source data at all, meaning most channel-level budget decisions would be made blind.



## 4. Insight Deep Dive

**Funnel breakdown:**

| Stage | Sessions | % of Total | Carry-Through |
|---|---|---|---|
| Sessions | 116,514 | 100% | — |
| Product View | 22,500 | 19.31% | 19.31% |
| Add to Cart | 4,525 | 3.88% | 20.11% |
| Begin Checkout | 1,504 | 1.29% | 33.2% |
| Purchase | 1,115 | 0.96% | 74.1% |

- **Top-of-funnel drop (~81%)** — validated as real, not a query artifact (ruled out: step-order suppression, duplicate `session_start` events, event-vs-session miscounting). Root cause (low-intent browsing vs. tracking gap vs. bots) not determinable from this dataset alone.
- **Cart-to-checkout leak (66.8%)** — the primary actionable finding. Checkout's healthy 74.1% completion rate isolates the friction to the cart stage specifically.
- **Attribution gap (92%)** — confirmed against raw `session_source`/`session_medium` fields, genuinely absent at the source, not a classification bug.
- **Secondary anomaly** — 1.5%–11% of purchasers (by channel; 6.7% of 779 on Referral) completed a purchase with no tracked `view_item` event, explaining an unusual dip-then-spike revenue pattern across stages.

Full validation methodology and root-cause testing: [Medium article](#)

---

## 5. Recommendations

1. **Audit the cart page** — the highest-leverage fix, given 66.8% of cart-adders abandon here.
2. **Audit the `view_item` tag** across product page templates to rule out a tracking gap.
3. **Trace a sample of `view_item`-missing sessions** manually to confirm shortcut path vs. tracking failure.
4. **Treat the 81% top-of-funnel drop as unresolved** — rule out tracking/bot issues before acting on it.
5. **Re-run channel-level breakdowns on a longer date range** before trusting small-sample channels (e.g., Paid Search: 2 of 18 purchasers).

- **SQL:** [`/sql/funnel_attribution.sql`](./sql/funnel_attribution.sql)
- **Dataset:** `bigquery-public-data.ga4_obfuscated_sample_ecommerce` (BigQuery public, free tier)
