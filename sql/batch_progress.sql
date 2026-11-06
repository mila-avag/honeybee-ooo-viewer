-- Honeybee viewer batch progress.
-- Grain: latest attempt per task for model names, current open human node for the layer.
-- Model A name is prefiller 9f5365db7f5d when that slot is filled.
-- Older tasks leave it empty and put the name in 22e13d3d5d87,
-- before " — Enter each turn's prompt...". 646efa3f869f is the legacy slot.
-- Model B name is prefiller 88fdb8d4174c.
-- An open layer is a pending human node. Paused nodes are labeled Paused and left out of the table.
-- Tasks with no open node and status completed are Completed. Datasource 22.

WITH latest AS (
    SELECT
        ta.task AS task_id,
        COALESCE(cds.respsonse, s3.s3_content, ta.response) AS resp
    FROM public.taskattempts ta
    LEFT JOIN view.cds_chat_task_attempt_responses cds
        ON cds.task_attempt_id = ta._id
    LEFT JOIN etl.cds_s3 s3
        ON ta.response:type::STRING = 'ResponseObject'
       AND s3.cds_url = ta.response:url::STRING
    WHERE ta.project = '6a567b80aaa4d140131eae6c'
      AND ta.attempted_by IS NOT NULL
      AND ta.attempted_by != '583cf35b8b8b73054d4344e6'
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY ta.task
        ORDER BY ta.attempt_version DESC NULLS LAST, ta.attempted_at DESC
    ) = 1
),
named AS (
    SELECT
        task_id,
        COALESCE(
            NULLIF(TRIM(resp:dataSourceResults:"before:0:data-source-string-prefiller-9f5365db7f5d":content::STRING), ''),
            NULLIF(TRIM(resp:dataSourceResults:"before:0:data-source-string-prefiller-646efa3f869f":content::STRING), ''),
            NULLIF(IFF(
                TRIM(SPLIT_PART(resp:dataSourceResults:"before:0:data-source-string-prefiller-22e13d3d5d87":content::STRING, ' — ', 1))
                    IN ('', 'Product A', 'Model A'),
                NULL,
                TRIM(SPLIT_PART(resp:dataSourceResults:"before:0:data-source-string-prefiller-22e13d3d5d87":content::STRING, ' — ', 1))
            ), ''),
            'A (unnamed)'
        ) AS model_a_name,
        COALESCE(
            NULLIF(TRIM(resp:dataSourceResults:"before:0:data-source-string-prefiller-88fdb8d4174c":content::STRING), ''),
            'B (unnamed)'
        ) AS model_b_name
    FROM latest
),
pending_node AS (
    SELECT
        h.task AS task_id,
        h.review_level::INT AS review_level
    FROM public.pipelinev3humannodes h
    WHERE h.project = '6a567b80aaa4d140131eae6c'
      AND COALESCE(h.__deleted, FALSE) = FALSE
      AND h.status = 'pending'
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY h.task
        ORDER BY h.updated_at DESC NULLS LAST
    ) = 1
),
paused_task AS (
    SELECT DISTINCT h.task AS task_id
    FROM public.pipelinev3humannodes h
    WHERE h.project = '6a567b80aaa4d140131eae6c'
      AND COALESCE(h.__deleted, FALSE) = FALSE
      AND h.status = 'paused'
),
task_state AS (
    SELECT t._id AS task_id, t.status AS task_status
    FROM public.tasks t
    WHERE t.project = '6a567b80aaa4d140131eae6c'
)
SELECT
    n.model_a_name AS "model_a_name",
    n.model_b_name AS "model_b_name",
    p.review_level AS "review_level",
    CASE
        WHEN p.review_level IS NOT NULL THEN CONCAT('L', p.review_level::STRING)
        WHEN z.task_id IS NOT NULL THEN 'Paused'
        WHEN t.task_status = 'completed' THEN 'Completed'
        ELSE 'Not open'
    END AS "review_level_label",
    COUNT(*) AS "task_count"
FROM named n
LEFT JOIN pending_node p ON p.task_id = n.task_id
LEFT JOIN paused_task z ON z.task_id = n.task_id AND p.task_id IS NULL
LEFT JOIN task_state t ON t.task_id = n.task_id
GROUP BY 1, 2, 3, 4
ORDER BY "task_count" DESC
