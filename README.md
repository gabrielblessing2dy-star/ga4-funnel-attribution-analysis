# GA4 Funnel and Attribution Analysis: Where Revenue Is Actually Lost

Diagnosing cart abandonment and marketing attribution gaps in a real e-commerce dataset using BigQuery SQL and Looker Studio.

---

## Problem Statement

Less than 1 in every 100 sessions on this site ends in a purchase. This project set out to find out exactly where that revenue is being lost across the customer journey and whether the marketing data available is even reliable enough to explain it.

Using real, anonymized session data from Google's public GA4 e-commerce dataset (Google Merchandise Store, January 2021) on BigQuery, two questions were investigated:

1. Where in the funnel is the business actually losing paying customers?
2. How much of the traffic-source data used for marketing attribution can be trusted?

**Dataset:** `bigquery-public-data.ga4_obfuscated_sample_ecommerce`, Jan 1–31, 2021.

---

## Methodology

Built entirely in BigQuery SQL as a single chained-CTE pipeline. structured for readability and staged debugging at each step.

### 1. `raw_extracted_events` — Cleaning the Raw Data

GA4 stores dates as strings, timestamps as microseconds, and marketing metadata as a nested array — none of it usable as-is.

- **Dates/timestamps:** `PARSE_DATE` and `TIMESTAMP_MICROS` convert raw strings/microseconds into usable `DATE`/`TIMESTAMP` types.
- **Traffic source extraction:** `source`, `medium`, and `campaign` live inside `event_params` as a nested key-value array, not flat columns. Extracted via subqueries with `UNNEST` rather than `CROSS JOIN UNNEST` — a full cross join would duplicate a row for every key in the array, inflating session counts.
- **Unique session ID:** GA4's native session ID is timestamp-based and can collide across different users. Fixed by combining device ID + session timestamp via `CONCAT`, with `COALESCE` handling nulls in both fields.
- **Cost control:** `WHERE` clause restricts the scan to January 2021 and filters to only the 5 funnel events this project uses, avoiding a full-table scan across every day GA4 exports.

### 2. `ga4_events` — Filling In the Attribution Gap

GA4 only populates `source`/`medium`/`campaign` on the first event of a session — every subsequent event in that session is null. Left as-is, purchase events would carry no attribution data at all.

Fixed with a window function:
```sql
MAX(raw_source) OVER (PARTITION BY unique_session_id)
```
Since only one row per session has a real value, `MAX()` reliably surfaces it and broadcasts it across every row in that session — no self-join required.

### 3. `session_milestones` — Collapsing to One Row Per Session

Event-level rows are collapsed into one row per session via `GROUP BY unique_session_id` (plus marketing fields). Conditional aggregation pulls the first timestamp each funnel step was hit:
```sql
MIN(CASE WHEN event_name = '...' THEN event_timestamp END)
```
This shape — one row per session, one column per step — is what makes stage-to-stage timestamp comparison possible in the next step.

`MAX(purchase_revenue)` is used for revenue: only the `purchase` row carries a non-null dollar amount, so `MAX()` reliably picks it out and attaches it to the session summary — the same pattern used for the attribution fill-down in step 2.

### 4. `flattened_flags` — Funnel Flags + Channel Classification

Converts timestamps into binary funnel-step flags and a clean marketing channel.

- **Funnel flags:** a step only counts as reached if its timestamp exists **and** occurred at or after the previous step — a stricter, deliberate definition than simply checking existence. This means a cart-abandonment session correctly flags `1,1,1,0,0` rather than any looser pattern.
- **Channel classification:** raw `session_source`/`session_medium` values are inconsistent (casing, naming, nulls). A rule-based `CASE` statement groups them into Direct / Organic Search / Paid Search / Social / Referral / Email, with unmatched values falling into an explicit `None` bucket rather than being guessed.
- **Session date:** `DATE(t_session_start)` extracts a clean date for trend aggregation.
- **Null handling:** `COALESCE(session_campaign, 'none')` and `COALESCE(session_revenue, 0)` prevent sessions with no campaign or no purchase from dropping out of downstream totals.

### 5. `melted_steps` — Unpivoting Sessions Into Stages

Reshapes one row per session (5 stage columns) into 5 rows per session (1 stage per row), via a fixed 5-element array and `CROSS JOIN UNNEST`.

This differs from the `CROSS JOIN UNNEST` risk flagged in step 1: there, the array (`event_params`) was variable-length and unpredictable. Here, the array is fixed, hand-written, and always exactly 5 elements — no risk of row multiplication. This shape (stage name as a row value, not a column) is required by Looker Studio's native funnel chart.

### 6. `aggregated_stages` + Final Query — Rolling Up to Totals and Conversion Rates

**Visit and revenue totals:** grouped by date, channel, and stage. Revenue required care — since a session's total revenue had been copied onto all 5 of its stage rows in step 5, summing naively would count one sale 5 times. Fixed by counting revenue only at the exact stage reached:
```sql
stage_revenue = total_revenue * is_active
```

**Step-over-step conversion rate:**
```sql
SAFE_DIVIDE(
  active_users,
  LAG(active_users) OVER (
    PARTITION BY clean_channel, session_campaign, session_date
    ORDER BY step_number
  )
)
```
Step 1 is hardcoded to `1.0`. `SAFE_DIVIDE` prevents divide-by-zero errors on sparse channel/date combinations rather than failing the query.

### Output

One materialized table (`funnel_attribution`) powers every chart in the Looker Studio dashboard — funnel visualization, step conversion rates, revenue-by-stage, and channel/date filtering — via a single data source connection.

---

## Findings

### 1. Biggest drop: Session → Product View (~81% drop-off)

| Stage | Sessions | % of Total | Carry-Through |
|---|---|---|---|
| 1. Sessions | 116,514 | 100% | — |
| 2. Product View | 22,500 | 19.31% | 19.31% |
| 3. Add to Cart | 4,525 | 3.88% | 20.11% |
| 4. Begin Checkout | 1,504 | 1.29% | 33.2% |
| 5. Purchase | 1,115 | 0.96% | 74.1% |

Most sessions never make it to a product view. This was checked, not assumed — three possible causes were tested and ruled out: wrong step order, duplicate `session_start` events, and counting events instead of sessions. None explain the drop, so it's real.

**Open question:** this dataset can't say *why* it's happening — low-intent browsing, a missing tracking tag, or bot traffic are all still possible.

### 2. Real leak: Add to Cart → Begin Checkout (66.8% abandonment)

Of everyone who added an item to their cart, only 33.2% started checkout — a **66.8% abandonment rate** at the highest-intent stage of the funnel.

By contrast, checkout itself converts well: **74.1%** of people who start checkout finish it. This rules out checkout as the problem — the friction is happening *before* checkout starts, most likely on the cart page.

### 3. Secondary pattern: purchases missing a `view_item` event

Revenue by channel showed an odd dip-then-jump pattern through the funnel stages. Investigation confirmed this wasn't a calculation error: a share of purchasers (1.5%–11%, depending on channel; Referral: 6.7% of 779 purchasers) completed a purchase without ever triggering a tracked `view_item` event. Their revenue is missing from the stages they technically skipped.

### 4. Attribution gap: 92% of sessions have no traffic-source data

Confirmed against raw `session_source`/`session_medium` fields — this data is genuinely missing, not a classification error downstream.

### Validation Approach

| Anomaly | Ruled out | Conclusion |
|---|---|---|
| Funnel drop-off (session → `view_item`, ~81%) | Sequential-logic suppression, duplicate `session_start` inflation, event-vs-session count errors | Genuine top-of-funnel behavior; root cause (tracking gap vs. low-intent traffic vs. bot traffic) not distinguishable from this dataset alone |
| Unattributed traffic (~92% of sessions) | Classification bug in channel rule engine | Data genuinely absent at source, confirmed via direct query against raw `session_source`/`medium` fields |
| Revenue dip-then-spike across funnel stages | Aggregation/calculation error in `stage_revenue` | 1.5%–11% of purchasers per channel completed a purchase without a tracked `view_item` event; a data-completeness gap, not a bug |

**Unresolved, flagged for further investigation:**
- Root cause of the session → `view_item` drop-off (tracking gap, low-intent traffic, or bot contamination)
- Root cause of purchases missing a tracked `view_item` event (tracking gap vs. legitimate alternate purchase path)

---

## Executive Diagnosis

Out of every 100 sessions, fewer than 1 results in a purchase.

The biggest drop happens early, before most sessions reach a product view — and this dataset alone can't fully explain why. The more actionable finding is deeper in the funnel: **two-thirds of users who add an item to their cart abandon before checkout starts**, even though checkout itself converts above 70% once started. The leak isn't checkout — it's whatever happens right before it.

Underneath both findings sits a marketing data problem: attribution is only possible for a small fraction of sessions. The remaining 92% carry no traffic-source data at all.

---

## Recommendations

1. **Audit the cart page.** Two-thirds of cart-adders abandon before checkout — the highest-leverage fix available. Check for late-revealed costs, weak/hidden CTAs, load issues, or a confusing cart-to-checkout transition.

2. **Audit the `view_item` tag implementation** across product page templates. A measurable share of purchasers never triggered this event before buying (up to 6.7% on Referral). Cheap to check, worth ruling out early.

3. **Trace a sample of the affected sessions.** Session recordings or a raw event-level pull for the specific `unique_session_id`s would confirm whether this is a legitimate shortcut path or a tracking gap.

4. **Treat the 81% top-of-funnel drop as unresolved, not settled.** Rule out tracking gaps and bot traffic before investing in traffic-quality initiatives based on this number.

5. **Re-run channel-level breakdowns with a larger date range.** Some channels (Paid Search, Organic Search, Email) have small enough sample sizes this month that one outlier session could swing the percentage significantly.

---

## Reproduce

All queries in `/sql`, run against BigQuery public datasets (free tier).
