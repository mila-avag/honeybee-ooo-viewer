-- Honeybee viewer batch progress.
-- Same queue read as Ultra deliveries (query 390037): the latest human node
-- by created_at, on scale_prod.public_raw.pipelinev3humannodes.
-- A pending node is counted at that level, including tasks with no attempt yet.
-- Model names are task metadata, with the same renames as query 390037.
-- The attempt's review_level is not used. Datasource 22.

WITH latest_node AS (
    SELECT
        h.task AS task_id,
        h.review_level::INT AS review_level,
        h.status AS status
    FROM scale_prod.public_raw.pipelinev3humannodes h
    WHERE h.project = '6a567b80aaa4d140131eae6c'
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY h.task
        ORDER BY h.created_at DESC
    ) = 1
),
named AS (
    SELECT
        t._id AS task_id,
        CASE COALESCE(t.metadata:model_a_name::STRING, '(null)')
            WHEN 'Gemini GOAT DTE pro_dte_test_arm'          THEN 'Gemini Test Model'
            WHEN '6 Astra'                                   THEN 'GPT 6 Astra'
            WHEN 'GPT-6 Astra'                               THEN 'GPT 6 Astra'
            WHEN 'GPT Astra 6'                               THEN 'GPT 6 Astra'
            WHEN 'Fable 5.1'                                 THEN 'Claude Fable 5.1'
            WHEN 'Gemini Pro release testing > Model Beetle' THEN 'Gemini Base'
            WHEN '(AI Studio) Gemini 4 Argon EAP'            THEN 'Gemini Ai Studio'
            WHEN 'Gemini App Monothread > Argon'             THEN 'Gemini App Monothread > Argon'
            WHEN 'Gemini App Monothread > Argon> Argon'      THEN 'Gemini App Monothread > Argon'
            WHEN 'Gemini App Monothread'                     THEN 'Gemini App Monothread > Argon'
            WHEN 'Gemini Monothread > Argon'                 THEN 'Gemini App Monothread > Argon'
            ELSE COALESCE(t.metadata:model_a_name::STRING, '(null)')
        END AS model_a_name,
        CASE COALESCE(t.metadata:model_b_name::STRING, '(null)')
            WHEN 'Gemini GOAT DTE pro_dte_test_arm'          THEN 'Gemini Test Model'
            WHEN '6 Astra'                                   THEN 'GPT 6 Astra'
            WHEN 'GPT-6 Astra'                               THEN 'GPT 6 Astra'
            WHEN 'GPT-6'                                     THEN 'GPT 6 Astra'
            WHEN 'Fable 5.1'                                 THEN 'Claude Fable 5.1'
            WHEN 'Gemini Pro release testing > Model Beetle' THEN 'Gemini Base'
            WHEN 'Gemini Pro Release Testing Model Beetle'   THEN 'Gemini Base'
            WHEN '(AI Studio) Gemini 4 Argon EAP'            THEN 'Gemini AI Studio'
            WHEN 'TASK Argon'                                THEN 'Gemini Argon Task'
            WHEN 'Argon Task'                                THEN 'Gemini Argon Task'
            ELSE COALESCE(t.metadata:model_b_name::STRING, '(null)')
        END AS model_b_name
    FROM scale_prod.public_w_deleted.tasks t
    WHERE t.project = '6a567b80aaa4d140131eae6c'
      AND NOT COALESCE(t.__deleted, FALSE)
)
SELECT
    COALESCE(n.model_a_name, '(null)') AS "model_a_name",
    COALESCE(n.model_b_name, '(null)') AS "model_b_name",
    h.review_level AS "review_level",
    CONCAT('L', h.review_level::STRING) AS "review_level_label",
    COUNT(*) AS "task_count"
FROM latest_node h
LEFT JOIN named n ON n.task_id = h.task_id
WHERE h.status = 'pending'
GROUP BY 1, 2, 3, 4
ORDER BY "task_count" DESC
;
