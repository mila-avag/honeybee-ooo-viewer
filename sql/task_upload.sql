-- Honeybee task upload. Run this on Redash data source 30, the same source as query 400607.
-- The IN list is filled in when you download this file from the viewer after pasting task ids.
-- Honeybee task authoring fields. Resolves CDS pointer so response.before is readable.
-- Every field: use response value if present/non-empty, else fall back to metadata.

WITH resolved AS (
  SELECT
    t._id       AS og_task_id,
    t.metadata  AS metadata,
    COALESCE(
      TRY_PARSE_JSON(COALESCE(cds.s3_content, ta.response)::string),
      COALESCE(cds.s3_content, ta.response)
    )           AS response
  FROM PUBLIC.TASKS t
  LEFT JOIN PUBLIC.TASKATTEMPTS ta
    ON ta.task = t._id
  LEFT JOIN ETL.CDS_S3 cds
    ON ta.response:type::string = 'ResponseObject'
   AND cds.cds_url = ta.response:url::string
  WHERE t._id IN ({{task_ids}})
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY t._id
    ORDER BY ta.attempt_version DESC NULLS LAST, ta.attempted_at DESC NULLS LAST
  ) = 1
),

latest AS (
  SELECT
    og_task_id,
    metadata:prompt_id::string AS prompt_id,

    -- scalars: use response if non-empty (after trim), else metadata
    COALESCE(
      NULLIF(TRIM(response:before:"step-TextCollection-e8ca527371fe":output:universe::string), ''),
      metadata:universe::string
    ) AS universe,
    COALESCE(
      NULLIF(TRIM(response:before:"step-TextCollection-e8ca527371fe":output:prompt_CUJ::string), ''),
      metadata:CUJ::string
    ) AS cuj,
    LOWER(COALESCE(
      NULLIF(TRIM(response:before:"step-TextCollection-e8ca527371fe":output:task_type::string), ''),
      metadata:task_type::string,
      ''
    )) AS task_type,
    COALESCE(
      NULLIF(TRIM(response:before:"step-TextCollection-e8ca527371fe":output:final_hardened_prompt::string), ''),
      metadata:opening_prompt::string
    ) AS opening_prompt,

    -- arrays: use response if it's a non-empty array, else metadata
    IFF(
      ARRAY_SIZE(response:before:"step-TextCollection-e8ca527371fe":output:input_artifacts_a) > 0,
      response:before:"step-TextCollection-e8ca527371fe":output:input_artifacts_a,
      metadata:input_uploads
    ) AS uploads_raw,
    IFF(
      ARRAY_SIZE(response:before:"step-TextCollection-e8ca527371fe":output:input_artifacts_a_links) > 0,
      response:before:"step-TextCollection-e8ca527371fe":output:input_artifacts_a_links,
      metadata:input_paths
    ) AS paths_raw,
    IFF(
      ARRAY_SIZE(response:before:"step-1784053126103-0h5ldq":output:criteria) > 0,
      response:before:"step-1784053126103-0h5ldq":output:criteria,
      metadata:target_deliverables
    ) AS targets_raw,
    IFF(
      ARRAY_SIZE(response:before:"step-RubricCriteriaBuilder-rubric01":output:criteria) > 0,
      response:before:"step-RubricCriteriaBuilder-rubric01":output:criteria,
      metadata:rubric_criteria
    ) AS rubric_raw
  FROM resolved
),

input_paths AS (
  SELECT
    l.og_task_id,
    COALESCE(
      ARRAY_AGG(
        TRIM(REPLACE(
          COALESCE(
            p.value:fullText::string,
            GET(
              FILTER(
                COALESCE(p.value:parts, ARRAY_CONSTRUCT()),
                x -> LOWER(x:id::string) IN ('file_path', 'path to artifacts')
              ),
              0
            ):value::string,
            p.value::string
          ),
          CHAR(160),
          ''
        ))
      ) WITHIN GROUP (ORDER BY p.index),
      ARRAY_CONSTRUCT()
    ) AS input_paths
  FROM latest l,
    LATERAL FLATTEN(input => COALESCE(l.paths_raw, ARRAY_CONSTRUCT()), OUTER => TRUE) p
  WHERE p.value IS NULL
     OR TYPEOF(p.value) != 'OBJECT'
     OR p.value:s3Url IS NULL
  GROUP BY 1
),

input_uploads AS (
  SELECT
    l.og_task_id,
    COALESCE(
      ARRAY_AGG(
        COALESCE(
          u.value:s3Url::string,
          CASE
            WHEN u.value:cdsUrl::string LIKE 'scale-cds://%' THEN
              'https://' ||
              COALESCE(SPLIT_PART(u.value:cdsUrl::string, '#s3/', 2), 'scale-cds-public-us-west-2') ||
              '.s3.amazonaws.com/' ||
              SPLIT_PART(REPLACE(u.value:cdsUrl::string, 'scale-cds://', ''), '#s3/', 1)
            WHEN u.value::string LIKE 'http%' THEN u.value::string
          END
        )
      ) WITHIN GROUP (ORDER BY u.index),
      ARRAY_CONSTRUCT()
    ) AS input_uploads
  FROM latest l,
    LATERAL FLATTEN(input => COALESCE(l.uploads_raw, ARRAY_CONSTRUCT()), OUTER => TRUE) u
  WHERE u.value IS NULL
     OR u.value:s3Url IS NOT NULL
     OR u.value:cdsUrl IS NOT NULL
     OR (TYPEOF(u.value) = 'VARCHAR' AND u.value::string LIKE 'http%')
  GROUP BY 1
),

target_deliverables AS (
  SELECT
    l.og_task_id,
    COALESCE(
      ARRAY_AGG(
        OBJECT_CONSTRUCT(
          'criterion_id', COALESCE(c.value:id::string, c.value:criterion_id::string),
          'title', c.value:title::string
        )
      ) WITHIN GROUP (ORDER BY c.index),
      ARRAY_CONSTRUCT()
    ) AS target_deliverables
  FROM latest l,
    LATERAL FLATTEN(input => COALESCE(l.targets_raw, ARRAY_CONSTRUCT()), OUTER => TRUE) c
  WHERE c.value IS NULL OR c.value:title IS NOT NULL OR c.value:id IS NOT NULL
  GROUP BY 1
),

rubric_criteria AS (
  SELECT
    l.og_task_id,
    COALESCE(
      ARRAY_AGG(
        OBJECT_CONSTRUCT(
          'criterion_id', COALESCE(r.value:id::string, r.value:criterion_id::string),
          'title', r.value:title::string,
          'weight', COALESCE(r.value:weight, 0),
          'criterion_category', r.value:annotations:criterion_category::string,
          'category', cat.l1,
          'subcategory', IFF(
            cat.l1 IS NULL,
            NULL,
            NULLIF(TRIM(SPLIT_PART(SUBSTR(LOWER(r.value:annotations:criterion_category::string), LENGTH(cat.l1) + 2), ':', 1)), '')
          )
        )
      ) WITHIN GROUP (ORDER BY r.index),
      ARRAY_CONSTRUCT()
    ) AS rubric_criteria
  FROM latest l,
    LATERAL FLATTEN(input => COALESCE(l.rubric_raw, ARRAY_CONSTRUCT()), OUTER => TRUE) r,
    LATERAL (
      SELECT CASE
        WHEN LOWER(r.value:annotations:criterion_category::string) LIKE 'tool & connector reliability-%'
          OR LOWER(r.value:annotations:criterion_category::string) LIKE 'tool and connector reliability-%'
          THEN 'tool & connector reliability'
        WHEN LOWER(r.value:annotations:criterion_category::string) LIKE 'memory & personalization-%'
          OR LOWER(r.value:annotations:criterion_category::string) LIKE 'personalization and memory-%'
          THEN 'memory & personalization'
        WHEN LOWER(r.value:annotations:criterion_category::string) LIKE 'communication quality-%'
          THEN 'communication quality'
        WHEN LOWER(r.value:annotations:criterion_category::string) LIKE 'interaction efficiency-%'
          THEN 'interaction efficiency'
        WHEN LOWER(r.value:annotations:criterion_category::string) LIKE 'collaboration quality-%'
          THEN 'collaboration quality'
        WHEN LOWER(r.value:annotations:criterion_category::string) LIKE 'trust & grounding-%'
          OR LOWER(r.value:annotations:criterion_category::string) LIKE 'trust and grounding-%'
          THEN 'trust & grounding'
        WHEN LOWER(r.value:annotations:criterion_category::string) LIKE 'outcome quality-%'
          THEN 'outcome quality'
        WHEN LOWER(r.value:annotations:criterion_category::string) LIKE 'safety-%'
          THEN 'safety'
      END AS l1
    ) cat
  WHERE r.value IS NULL OR r.value:title IS NOT NULL OR r.value:id IS NOT NULL
  GROUP BY 1
)

SELECT
  l.og_task_id                                                 AS "og_task_id",
  l.universe                                                   AS "universe",
  l.prompt_id                                                  AS "prompt_id",
  l.cuj                                                        AS "CUJ",
  l.task_type                                                  AS "task_type",
  l.opening_prompt                                             AS "opening_prompt",
  TO_JSON(COALESCE(p.input_paths, ARRAY_CONSTRUCT()))          AS "input_paths",
  TO_JSON(COALESCE(u.input_uploads, ARRAY_CONSTRUCT()))        AS "input_uploads",
  TO_JSON(COALESCE(td.target_deliverables, ARRAY_CONSTRUCT())) AS "target_deliverables",
  TO_JSON(COALESCE(rc.rubric_criteria, ARRAY_CONSTRUCT()))     AS "rubric_criteria",
  ''                                                           AS "demo_email",
  ''                                                           AS "demo_password",
  ''                                                           AS "model_a_name",
  ''                                                           AS "model_b_name",
  'en_US'                                                      AS "languageCode",
  ''                                                           AS "demo_email_b",
  ''                                                           AS "demo_password_b",
  ''                                                           AS "environment_context",
  ''                                                           AS "estimated_turns",
  ''                                                           AS "credential_mode"
FROM latest l
LEFT JOIN input_paths p        ON p.og_task_id  = l.og_task_id
LEFT JOIN input_uploads u      ON u.og_task_id  = l.og_task_id
LEFT JOIN target_deliverables td ON td.og_task_id = l.og_task_id
LEFT JOIN rubric_criteria rc   ON rc.og_task_id = l.og_task_id
;