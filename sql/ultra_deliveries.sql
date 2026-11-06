-- Ultra deliveries, query 390037. Run this on Redash data source 22.
-- Project 6a567b80aaa4d140131eae6c.
-- Delivered means sent in the last 21 days (Pacific), or completed in that window and never sent.
-- Pending review is a task at L8, L10, or L12. Still in attempt has not left the attempt layer.

with pt as (
  select convert_timezone('America/Los_Angeles', current_timestamp()) as now_pt
),
sent_batches as (
  select b.delivered_at, f.value:_id::string as task_id
  from scale_prod.public.chatdeliverybatches b,
       lateral flatten(input => b.source:taskStates) f
  where b.project_id = '6a567b80aaa4d140131eae6c'
    and b.status = 'sent'
    and not coalesce(b.__deleted, false)
    and not coalesce(b.is_test, false)
),
-- Delivered: sent in the last 21 days (PT)
delivered as (
  select distinct s.task_id
  from sent_batches s, pt
  where convert_timezone('America/Los_Angeles', s.delivered_at) >= dateadd(day, -21, pt.now_pt)
),
-- Completed in the last 21 days (PT) but never in any sent batch, counted as delivered
completed_undelivered as (
  select t._id as task_id
  from scale_prod.public_w_deleted.tasks t, pt
  where t.project = '6a567b80aaa4d140131eae6c'
    and not coalesce(t.__deleted, false)
    and t.status = 'completed'
    and convert_timezone('America/Los_Angeles', t.completed_at) >= dateadd(day, -21, pt.now_pt)
    and not exists (select 1 from sent_batches s where s.task_id = t._id)
),
latest_node as (
  select task, review_level, status
  from scale_prod.public_raw.pipelinev3humannodes
  where project = '6a567b80aaa4d140131eae6c'
  qualify row_number() over (partition by task order by created_at desc) = 1
),
pending as (
  select task as task_id, review_level from latest_node
  where status = 'pending' and review_level in (8, 10, 12)
),
attempt as (
  select task as task_id, review_level from latest_node
  where status = 'pending' and review_level = -1
),
all_tasks as (
  select task_id, 'delivered' as bucket, null as review_level from delivered
  union all
  select task_id, 'delivered', null from completed_undelivered
  union all
  select task_id, 'pending', review_level from pending
  union all
  select task_id, 'attempt', review_level from attempt
),
tasks_named as (
  select a.task_id, a.bucket, a.review_level,
         case coalesce(t.metadata:model_a_name::string, '(null)')
           when 'Gemini GOAT DTE pro_dte_test_arm'          then 'Gemini Test Model'
           when '6 Astra'                                   then 'GPT 6 Astra'
           when 'GPT-6 Astra'                               then 'GPT 6 Astra'
           when 'Fable 5.1'                                 then 'Claude Fable 5.1'
           when 'Gemini Pro release testing > Model Beetle' then 'Gemini Base'
           when '(AI Studio) Gemini 4 Argon EAP'            then 'Gemini Ai Studio'
           else coalesce(t.metadata:model_a_name::string, '(null)')
         end as model_a_name,
         case coalesce(t.metadata:model_b_name::string, '(null)')
           when 'Gemini GOAT DTE pro_dte_test_arm'          then 'Gemini Test Model'
           when '6 Astra'                                   then 'GPT 6 Astra'
           when 'GPT-6 Astra'                               then 'GPT 6 Astra'
           when 'GPT-6'                                     then 'GPT 6 Astra'
           when 'Fable 5.1'                                 then 'Claude Fable 5.1'
           when 'Gemini Pro release testing > Model Beetle' then 'Gemini Base'
           when 'Gemini Pro Release Testing Model Beetle'   then 'Gemini Base'
           when '(AI Studio) Gemini 4 Argon EAP'            then 'Gemini AI Studio'
           else coalesce(t.metadata:model_b_name::string, '(null)')
         end as model_b_name
  from all_tasks a
  left join scale_prod.public_w_deleted.tasks t
    on t._id = a.task_id and not coalesce(t.__deleted, false)
),
-- Full attempt history (FULL_W_DELETED) + last 3 days from RAW
ta as (
  select * from (
    select _id, task, attempted_at_review_level, v2_time_spent_secs, v2_active_time_spent_secs, __deleted, 1 as src
    from scale_prod.public_w_deleted_raw.taskattempts
    where project = '6a567b80aaa4d140131eae6c' and attempted_at >= dateadd(day, -3, current_timestamp())
    union all
    select _id, task, attempted_at_review_level, v2_time_spent_secs, v2_active_time_spent_secs, __deleted, 2 as src
    from scale_prod.full_w_deleted.taskattempts
    where project = '6a567b80aaa4d140131eae6c'
  )
  qualify row_number() over (partition by _id order by src) = 1
),
-- One row per task + model pair; is_pending = task is in the L8/L10/L12 pending bucket
task_model as (
  select task_id, model_a_name, model_b_name, max(iff(bucket = 'pending', 1, 0)) as is_pending
  from tasks_named group by 1, 2, 3
),
att as (
  select tm.model_a_name, tm.model_b_name, tm.is_pending, ta.task, ta.attempted_at_review_level as lvl,
         ta.v2_time_spent_secs as secs, ta.v2_active_time_spent_secs as active_secs
  from ta join task_model tm on tm.task_id = ta.task
  where not coalesce(ta.__deleted, false) and ta.v2_time_spent_secs > 0
),
task_total as (
  select model_a_name, model_b_name, is_pending, task, sum(secs) as total_secs from att group by 1, 2, 3, 4
),
-- Model A AHT (L-1 attempts)
model_a_aht as (
  select model_a_name,
         round(avg(iff(lvl = -1, secs, null)) / 60, 1)                                        as attempt_aht_mins_all,
         round(median(iff(lvl = -1, secs, null)) / 60, 1)                                     as attempt_median_mins_all,
         round(percentile_cont(0.95) within group (order by iff(lvl = -1, secs, null)) / 60, 1) as attempt_95pct_mins_all,
         round(avg(iff(lvl = -1, active_secs, null)) / 60, 1)                                 as attempt_active_mins_all,
         count(iff(lvl = -1, 1, null))                                                        as attempt_n_all,
         round(avg(iff(lvl = -1 and is_pending = 1, secs, null)) / 60, 1)                     as attempt_aht_mins_pending,
         round(median(iff(lvl = -1 and is_pending = 1, secs, null)) / 60, 1)                  as attempt_median_mins_pending,
         count(iff(lvl = -1 and is_pending = 1, 1, null))                                     as attempt_n_pending
  from att group by 1
),
model_a_task_time as (
  select model_a_name,
         round(avg(total_secs) / 60, 1)                            as total_time_per_task_mins_all,
         round(avg(iff(is_pending = 1, total_secs, null)) / 60, 1) as total_time_per_task_mins_pending
  from task_total group by 1
),
-- Model A + B pair AHT (L-1 attempts)
pair_aht as (
  select model_a_name, model_b_name,
         round(avg(iff(lvl = -1, secs, null)) / 60, 1)                                        as pair_attempt_aht_mins,
         round(median(iff(lvl = -1, secs, null)) / 60, 1)                                     as pair_attempt_median_mins,
         round(percentile_cont(0.95) within group (order by iff(lvl = -1, secs, null)) / 60, 1) as pair_attempt_95pct_mins,
         round(avg(iff(lvl = -1, active_secs, null)) / 60, 1)                                 as pair_attempt_active_mins,
         count(iff(lvl = -1, 1, null))                                                        as pair_attempts_n,
         round(avg(iff(lvl = -1 and is_pending = 1, secs, null)) / 60, 1)                     as pair_pending_attempt_aht_mins,
         round(median(iff(lvl = -1 and is_pending = 1, secs, null)) / 60, 1)                  as pair_pending_attempt_median_mins,
         count(iff(lvl = -1 and is_pending = 1, 1, null))                                     as pair_pending_attempts_n
  from att group by 1, 2
),
pair_task_time as (
  select model_a_name, model_b_name,
         round(avg(total_secs) / 60, 1)                            as pair_total_mins_per_task,
         round(avg(iff(is_pending = 1, total_secs, null)) / 60, 1) as pair_pending_total_mins_per_task
  from task_total group by 1, 2
)
select n.model_a_name, n.model_b_name,
       count(distinct iff(n.bucket = 'delivered', n.task_id, null))             as delivered_last_21d,
       count(distinct iff(n.bucket = 'pending', n.task_id, null))               as pending_to_deliver,
       count(distinct iff(n.bucket = 'delivered', n.task_id, null))
         + count(distinct iff(n.bucket = 'pending', n.task_id, null))           as delivered_plus_pending,
       count(distinct iff(n.bucket = 'attempt', n.task_id, null))               as pending_in_attempt,
       count(distinct iff(n.bucket = 'delivered', n.task_id, null))
         + count(distinct iff(n.bucket = 'pending', n.task_id, null))
         + count(distinct iff(n.bucket = 'attempt', n.task_id, null))           as total,
       count(distinct iff(n.bucket = 'pending' and n.review_level = 8,  n.task_id, null)) as pending_l8,
       count(distinct iff(n.bucket = 'pending' and n.review_level = 10, n.task_id, null)) as pending_l10,
       count(distinct iff(n.bucket = 'pending' and n.review_level = 12, n.task_id, null)) as pending_l12,
       -- Model A AHT
       any_value(m.attempt_aht_mins_all)               as model_a_attempt_aht_mins,
    --   any_value(m.attempt_median_mins_all)            as model_a_attempt_median_mins,
    --   any_value(m.attempt_95pct_mins_all)             as model_a_attempt_95pct_mins,
    --   any_value(m.attempt_active_mins_all)            as model_a_attempt_active_mins,
    --   any_value(m.attempt_n_all)                      as model_a_attempts_n,
       any_value(tt.total_time_per_task_mins_all)      as model_a_total_mins_per_task,
       any_value(m.attempt_aht_mins_pending)           as pending_attempt_aht_mins,
    --   any_value(m.attempt_median_mins_pending)        as pending_attempt_median_mins,
    --   any_value(m.attempt_n_pending)                  as pending_attempts_n,
       any_value(tt.total_time_per_task_mins_pending)  as pending_total_mins_per_task,
       -- Model A + B pair AHT
       any_value(p.pair_attempt_aht_mins)              as pair_attempt_aht_mins,
    --   any_value(p.pair_attempt_median_mins)           as pair_attempt_median_mins,
    --   any_value(p.pair_attempt_95pct_mins)            as pair_attempt_95pct_mins,
    --   any_value(p.pair_attempt_active_mins)           as pair_attempt_active_mins,
    --   any_value(p.pair_attempts_n)                    as pair_attempts_n,
       any_value(pt2.pair_total_mins_per_task)         as pair_total_mins_per_task,
       any_value(p.pair_pending_attempt_aht_mins)      as pair_pending_attempt_aht_mins,
    --   any_value(p.pair_pending_attempt_median_mins)   as pair_pending_attempt_median_mins,
    --   any_value(p.pair_pending_attempts_n)            as pair_pending_attempts_n,
       any_value(pt2.pair_pending_total_mins_per_task) as pair_pending_total_mins_per_task
from tasks_named n
left join model_a_aht m        on m.model_a_name = n.model_a_name
left join model_a_task_time tt on tt.model_a_name = n.model_a_name
left join pair_aht p           on p.model_a_name = n.model_a_name and p.model_b_name = n.model_b_name
left join pair_task_time pt2   on pt2.model_a_name = n.model_a_name and pt2.model_b_name = n.model_b_name
group by 1, 2
order by delivered_last_21d desc, pending_to_deliver desc
