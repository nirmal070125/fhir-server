-- FHIR Server PostgreSQL Schema
-- One resources table holds all FHIR resource types. Separate sp_* tables
-- store extracted search parameter values so searches never touch resource_json.
-- Requires PostgreSQL 13+. For Location near-search, install PostGIS.
--
-- Layout:
--   1. Schema version table
--   2. Core resource storage      (resources, resource_history)
--   3. Search parameter indexes   (sp_string, sp_token, sp_date, sp_number,
--                                  sp_quantity, sp_uri, sp_reference, sp_coords)
--   4. Registry & reference data  (search_param_definitions, ig_*,
--                                  base_definitions, closure tables)
--   5. Planner statistics
--   6. Autovacuum tuning
--   7. Row-Level Security
--   8. LEAKPROOF numeric operators
--   9. Schema version history
--
-- Each table is defined together with all of its own indexes and column
-- migrations. Every statement is idempotent (CREATE ... IF NOT EXISTS /
-- ADD COLUMN IF NOT EXISTS), so a fresh database is initialised in full and
-- re-running is a no-op. This is table creation, not a migration system: it can
-- only add tables, columns, and indexes. Upgrading an EXISTING database across
-- schema versions can need manual steps — see section 9.


-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Schema version
-- ═══════════════════════════════════════════════════════════════════════════
-- Tracks the schema revision applied to this database. Stamped at the end of
-- this file (see section 9).

CREATE TABLE IF NOT EXISTS schema_version (
    version     INT         NOT NULL PRIMARY KEY,
    upgraded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Core resource storage
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── resources ───────────────────────────────────────────────────────────────
-- Stores every FHIR resource; resource_json holds the full FHIR document.
-- search_text is a pre-built tsvector for _text / _content full-text search.
-- No GIN index is built on resource_json: all searches go through the sp_* tables,
-- and indexing the whole document would cost ~2.4x on writes for no benefit here.

CREATE TABLE IF NOT EXISTS resources (
    tenant_id     TEXT         NOT NULL DEFAULT current_setting('app.current_tenant', true),
    fhir_id       VARCHAR(64)  NOT NULL,
    resource_type VARCHAR(100) NOT NULL,
    version_id    INT          NOT NULL DEFAULT 1,
    last_updated  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    is_deleted    BOOLEAN      NOT NULL DEFAULT FALSE,
    resource_json JSONB        NOT NULL,
    search_text   TSVECTOR,
    PRIMARY KEY (tenant_id, resource_type, fhir_id)
);

-- List all resources of a type, newest first (GET /{type}).
CREATE INDEX IF NOT EXISTS idx_res_type_updated ON resources (tenant_id, resource_type, last_updated DESC);
-- Same, but skipping soft-deleted rows (used by most searches).
CREATE INDEX IF NOT EXISTS idx_res_active       ON resources (tenant_id, resource_type, last_updated DESC) WHERE is_deleted = FALSE;
-- Full-text search over search_text (_text / _content).
CREATE INDEX IF NOT EXISTS idx_res_search_text  ON resources USING GIN (search_text);

-- ─── resource_history ────────────────────────────────────────────────────────
-- Append-only log of every create, update, and delete. Each row is a full
-- snapshot of resource_json at that version, enabling vread and audit trails.

CREATE TABLE IF NOT EXISTS resource_history (
    id            BIGSERIAL    PRIMARY KEY,
    tenant_id     TEXT         NOT NULL DEFAULT current_setting('app.current_tenant', true),
    fhir_id       VARCHAR(64)  NOT NULL,
    resource_type VARCHAR(100) NOT NULL,
    version_id    INT          NOT NULL,
    operation     VARCHAR(10)  NOT NULL,   -- CREATE | UPDATE | DELETE
    recorded_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    resource_json JSONB,
    UNIQUE (tenant_id, fhir_id, resource_type, version_id)
);

-- Fetch a specific version of a resource (GET /{type}/{id}/_history/{vid}).
CREATE INDEX IF NOT EXISTS idx_hist_resource  ON resource_history (tenant_id, resource_type, fhir_id, version_id DESC);
-- Global history feed ordered by time (GET /_history).
CREATE INDEX IF NOT EXISTS idx_hist_time      ON resource_history (tenant_id, recorded_at DESC);
-- History feed for a single resource type ordered by time (GET /{type}/_history).
CREATE INDEX IF NOT EXISTS idx_hist_type_time ON resource_history (tenant_id, resource_type, recorded_at DESC);


-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Search parameter indexes (sp_*)
-- ═══════════════════════════════════════════════════════════════════════════
-- One table per FHIR search parameter type. Each holds values extracted from
-- resource_json at write time and cascades on delete of its parent resource.
--
-- Two index families recur across these tables:
--   *_source  — leads on (tenant_id, resource_id, resource_type) to serve the
--               per-resource EXISTS probe of multi-parameter searches (correlated
--               on resource_id/resource_type; see internal/store/search.go) and
--               the per-resource re-index DELETE / FK ON DELETE CASCADE. Trailing
--               param_name + value columns let the probe resolve its predicate
--               index-only instead of heap-fetching every row of the candidate
--               resource. (See v8 in section 9 for the history behind this shape.)
--   *_recent  — leads on the value/lookup key but orders by last_updated DESC and
--               INCLUDEs the sort/join columns, so a recency-sorted search walks
--               newest-first and stops after one page instead of materialising and
--               top-N sorting a dense match set. (See v10/v11 in section 9.)

-- ─── sp_string ───────────────────────────────────────────────────────────────
-- FHIR string search parameters (name, address, etc.).
-- value_exact keeps the original casing for the :exact modifier;
-- value_lower is the downcased value for the default case-insensitive prefix match.

CREATE TABLE IF NOT EXISTS sp_string (
    id            BIGSERIAL    PRIMARY KEY,
    tenant_id     TEXT         NOT NULL DEFAULT current_setting('app.current_tenant', true),
    resource_id   VARCHAR(64)  NOT NULL,
    resource_type VARCHAR(100) NOT NULL,
    param_name    VARCHAR(191) NOT NULL,
    value_exact   VARCHAR(512),
    value_lower   VARCHAR(512),
    FOREIGN KEY (tenant_id, resource_id, resource_type) REFERENCES resources (tenant_id, fhir_id, resource_type) ON DELETE CASCADE
);

-- text_pattern_ops is required for LIKE 'prefix%' to use a btree index under
-- non-C collations (e.g. en_US.utf8); without it, prefix scans fall back to a
-- sequential scan. The operator class also serves equality lookups.
CREATE INDEX IF NOT EXISTS idx_sp_str_lower_pattern ON sp_string (tenant_id, resource_type, param_name, value_lower text_pattern_ops);
CREATE INDEX IF NOT EXISTS idx_sp_str_exact         ON sp_string (tenant_id, resource_type, param_name, value_exact);
CREATE INDEX IF NOT EXISTS idx_sp_str_source        ON sp_string (tenant_id, resource_id, resource_type, param_name, value_lower);
-- Uncomment for :contains support (requires pg_trgm extension):
-- CREATE EXTENSION IF NOT EXISTS pg_trgm;
-- CREATE INDEX idx_sp_str_trgm ON sp_string USING GIN (value_lower gin_trgm_ops);

-- ─── sp_token ────────────────────────────────────────────────────────────────
-- FHIR token search parameters (CodeableConcept, Coding, Identifier, code, boolean).
-- display supports the :text modifier (match on the human label).
-- last_updated is a denormalised copy of resources.last_updated, set at index
-- time, so idx_sp_tok_recent can walk newest-first for a code without a
-- resources lookup.

CREATE TABLE IF NOT EXISTS sp_token (
    id            BIGSERIAL    PRIMARY KEY,
    tenant_id     TEXT         NOT NULL DEFAULT current_setting('app.current_tenant', true),
    resource_id   VARCHAR(64)  NOT NULL,
    resource_type VARCHAR(100) NOT NULL,
    param_name    VARCHAR(191) NOT NULL,
    system        VARCHAR(512),
    code          VARCHAR(191),
    display       VARCHAR(512),
    last_updated  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    FOREIGN KEY (tenant_id, resource_id, resource_type) REFERENCES resources (tenant_id, fhir_id, resource_type) ON DELETE CASCADE
);

-- Migration for databases created before last_updated was added (v11): no-op on
-- fresh installs, backfills existing rows before the recency index below is built.
ALTER TABLE sp_token ADD COLUMN IF NOT EXISTS last_updated TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Primary lookup: system|code pairs (the most common token search pattern).
-- (idx_sp_tok_system was dropped as a redundant strict prefix of this index —
--  the planner already uses this one for system-only lookups.)
CREATE INDEX IF NOT EXISTS idx_sp_tok_sys_code ON sp_token (tenant_id, resource_type, param_name, system, code);
-- Lookup by code alone when the search omits system.
CREATE INDEX IF NOT EXISTS idx_sp_tok_code     ON sp_token (tenant_id, resource_type, param_name, code) WHERE code IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sp_tok_source   ON sp_token (tenant_id, resource_id, resource_type, param_name, system, code);
-- Recency drive for the composite token+quantity early-exit (fetchSQL's composite
-- shape, see search.go): walk sp_token newest-first for a code, probe the other
-- component per row, and stop after one page. INCLUDE keeps the walk (and an
-- optional system filter) index-only.
CREATE INDEX IF NOT EXISTS idx_sp_tok_recent   ON sp_token (tenant_id, resource_type, param_name, code, last_updated DESC) INCLUDE (resource_id, system) WHERE code IS NOT NULL;

-- ─── sp_date ─────────────────────────────────────────────────────────────────
-- FHIR date / dateTime / Period / instant parameters.
-- Partial-precision dates ("2000", "2000-04") are expanded into a
-- [value_low, value_high] range at write time so all 8 FHIR date comparators
-- (eq, ne, lt, gt, le, ge, sa, eb) work without special casing.
-- value_precision records the original granularity (YEAR|MONTH|DAY|SECOND).

CREATE TABLE IF NOT EXISTS sp_date (
    id              BIGSERIAL    PRIMARY KEY,
    tenant_id       TEXT         NOT NULL DEFAULT current_setting('app.current_tenant', true),
    resource_id     VARCHAR(64)  NOT NULL,
    resource_type   VARCHAR(100) NOT NULL,
    param_name      VARCHAR(191) NOT NULL,
    value_low       TIMESTAMPTZ  NOT NULL,
    value_high      TIMESTAMPTZ  NOT NULL,
    value_precision VARCHAR(10)  NOT NULL DEFAULT 'SECOND',
    FOREIGN KEY (tenant_id, resource_id, resource_type) REFERENCES resources (tenant_id, fhir_id, resource_type) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_sp_date_range  ON sp_date (tenant_id, resource_type, param_name, value_low, value_high);
CREATE INDEX IF NOT EXISTS idx_sp_date_source ON sp_date (tenant_id, resource_id, resource_type, param_name, value_low, value_high);

-- ─── sp_number ───────────────────────────────────────────────────────────────
-- FHIR number search parameters.
-- value_low / value_high encode the implicit precision range around value so
-- FHIR's "approximately equal" (eq) semantics work: searching 100 matches 100.4
-- but not 100.5.
-- last_updated is a denormalised copy of resources.last_updated, set at index
-- time, so idx_sp_num_recent can sort candidates without a per-match lookup.

CREATE TABLE IF NOT EXISTS sp_number (
    id            BIGSERIAL     PRIMARY KEY,
    tenant_id     TEXT          NOT NULL DEFAULT current_setting('app.current_tenant', true),
    resource_id   VARCHAR(64)   NOT NULL,
    resource_type VARCHAR(100)  NOT NULL,
    param_name    VARCHAR(191)  NOT NULL,
    value         DECIMAL(20,6) NOT NULL,
    value_low     DECIMAL(20,6) NOT NULL,
    value_high    DECIMAL(20,6) NOT NULL,
    last_updated  TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    FOREIGN KEY (tenant_id, resource_id, resource_type) REFERENCES resources (tenant_id, fhir_id, resource_type) ON DELETE CASCADE
);

-- Migration for databases created before last_updated was added (v10): no-op on
-- fresh installs, backfills existing rows before the recency index below is built.
ALTER TABLE sp_number ADD COLUMN IF NOT EXISTS last_updated TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- INCLUDE (resource_id, last_updated) makes the range scan covering: the id-first
-- candidate resolve is index-only, yielding the fhir_id to join and the sort key.
CREATE INDEX IF NOT EXISTS idx_sp_num_range  ON sp_number (tenant_id, resource_type, param_name, value_low, value_high) INCLUDE (resource_id, last_updated);
CREATE INDEX IF NOT EXISTS idx_sp_num_source ON sp_number (tenant_id, resource_id, resource_type, param_name, value_low, value_high);
CREATE INDEX IF NOT EXISTS idx_sp_num_recent ON sp_number (tenant_id, resource_type, param_name, last_updated DESC) INCLUDE (value_low, value_high, resource_id);

-- ─── sp_quantity ─────────────────────────────────────────────────────────────
-- FHIR quantity search parameters.
-- value / value_low / value_high hold the raw value with its precision range.
-- canonical_value / canonical_units hold the UCUM-normalised equivalent so
-- cross-unit comparisons work (searching "1g" matches "1000mg").
-- last_updated mirrors sp_number's, for idx_sp_qty_recent.

CREATE TABLE IF NOT EXISTS sp_quantity (
    id              BIGSERIAL     PRIMARY KEY,
    tenant_id       TEXT          NOT NULL DEFAULT current_setting('app.current_tenant', true),
    resource_id     VARCHAR(64)   NOT NULL,
    resource_type   VARCHAR(100)  NOT NULL,
    param_name      VARCHAR(191)  NOT NULL,
    value           DECIMAL(20,6) NOT NULL,
    value_low       DECIMAL(20,6) NOT NULL,
    value_high      DECIMAL(20,6) NOT NULL,
    system          VARCHAR(255),
    code            VARCHAR(64),
    canonical_value DECIMAL(20,6),
    canonical_units VARCHAR(64),
    last_updated    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    FOREIGN KEY (tenant_id, resource_id, resource_type) REFERENCES resources (tenant_id, fhir_id, resource_type) ON DELETE CASCADE
);

-- Migration for databases created before last_updated was added (v10); see the
-- sp_number note above.
ALTER TABLE sp_quantity ADD COLUMN IF NOT EXISTS last_updated TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Raw value range search (same system+code, no unit conversion needed).
-- INCLUDE (resource_id, last_updated) makes the range scan covering so the
-- id-first candidate resolve is index-only.
CREATE INDEX IF NOT EXISTS idx_sp_qty_raw       ON sp_quantity (tenant_id, resource_type, param_name, value_low, value_high, system, code) INCLUDE (resource_id, last_updated);
-- buildQuantityExists filters on value_low/value_high plus optional system/code,
-- so those trail param_name to keep the probe index-only.
CREATE INDEX IF NOT EXISTS idx_sp_qty_source    ON sp_quantity (tenant_id, resource_id, resource_type, param_name, value_low, value_high, system, code);
-- Canonical search (cross-unit comparison via UCUM normalisation).
CREATE INDEX IF NOT EXISTS idx_sp_qty_canonical ON sp_quantity (tenant_id, resource_type, param_name, canonical_value, canonical_units) WHERE canonical_value IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sp_qty_recent    ON sp_quantity (tenant_id, resource_type, param_name, last_updated DESC) INCLUDE (value_low, value_high, resource_id, system, code);

-- ─── sp_uri ──────────────────────────────────────────────────────────────────
-- FHIR uri search parameters (url, profile, etc.).
-- Supports exact match and the :below modifier (prefix / hierarchy match).

CREATE TABLE IF NOT EXISTS sp_uri (
    id            BIGSERIAL    PRIMARY KEY,
    tenant_id     TEXT         NOT NULL DEFAULT current_setting('app.current_tenant', true),
    resource_id   VARCHAR(64)  NOT NULL,
    resource_type VARCHAR(100) NOT NULL,
    param_name    VARCHAR(191) NOT NULL,
    value         VARCHAR(512) NOT NULL,
    FOREIGN KEY (tenant_id, resource_id, resource_type) REFERENCES resources (tenant_id, fhir_id, resource_type) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_sp_uri_exact  ON sp_uri (tenant_id, resource_type, param_name, value);
-- text_pattern_ops enables efficient LIKE 'prefix%' for the :below modifier.
CREATE INDEX IF NOT EXISTS idx_sp_uri_prefix ON sp_uri (tenant_id, resource_type, param_name, value text_pattern_ops);
CREATE INDEX IF NOT EXISTS idx_sp_uri_source ON sp_uri (tenant_id, resource_id, resource_type, param_name, value);

-- ─── sp_reference ────────────────────────────────────────────────────────────
-- FHIR reference search parameters. Also used for _include / _revinclude and
-- $everything traversal.
-- target_url holds the literal URL when the reference is external (not local).
-- identifier_* columns support the :identifier modifier (search by Identifier
-- instead of resource id).

CREATE TABLE IF NOT EXISTS sp_reference (
    id                BIGSERIAL    PRIMARY KEY,
    tenant_id         TEXT         NOT NULL DEFAULT current_setting('app.current_tenant', true),
    resource_id       VARCHAR(64)  NOT NULL,
    resource_type     VARCHAR(100) NOT NULL,
    param_name        VARCHAR(191) NOT NULL,
    target_type       VARCHAR(100),
    target_id         VARCHAR(64),
    target_version_id INT,
    target_url        VARCHAR(512),
    identifier_system VARCHAR(512),
    identifier_value  VARCHAR(255),
    display           VARCHAR(255),
    FOREIGN KEY (tenant_id, resource_id, resource_type) REFERENCES resources (tenant_id, fhir_id, resource_type) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_sp_ref_source      ON sp_reference (tenant_id, resource_id, resource_type, param_name, target_id);
-- Search by target (e.g. ?patient=123): leading on target_id serves bare-id
-- lookups; the trailing columns let the predicate resolve index-only.
CREATE INDEX IF NOT EXISTS idx_sp_ref_target_full ON sp_reference (tenant_id, target_id, target_type, param_name, resource_type, resource_id);
-- The :identifier modifier (find references by Identifier value).
CREATE INDEX IF NOT EXISTS idx_sp_ref_ident       ON sp_reference (tenant_id, target_type, identifier_system, identifier_value) WHERE identifier_value IS NOT NULL;

-- ─── sp_coords ───────────────────────────────────────────────────────────────
-- lat/lng for the Location.near search parameter.
-- For heavy geospatial workloads, consider replacing lat/lng with a
-- PostGIS geometry(Point,4326) column and a GIST index.

CREATE TABLE IF NOT EXISTS sp_coords (
    id            BIGSERIAL    PRIMARY KEY,
    tenant_id     TEXT         NOT NULL DEFAULT current_setting('app.current_tenant', true),
    resource_id   VARCHAR(64)  NOT NULL,
    resource_type VARCHAR(100) NOT NULL,
    param_name    VARCHAR(191) NOT NULL,
    latitude      DECIMAL(9,6) NOT NULL,
    longitude     DECIMAL(9,6) NOT NULL,
    FOREIGN KEY (tenant_id, resource_id, resource_type) REFERENCES resources (tenant_id, fhir_id, resource_type) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_sp_coords ON sp_coords (tenant_id, resource_type, param_name, latitude, longitude);


-- ═══════════════════════════════════════════════════════════════════════════
-- 4. Registry & reference data
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── search_param_definitions ────────────────────────────────────────────────
-- Registry of all known search parameters for each resource type. Populated at
-- startup from the embedded FHIR R4 base spec (CSV) and any loaded IG packages.
-- ig_source: '' = base FHIR R4, 'user' = custom SearchParameter resource,
--            'name@version' = sourced from a specific IG package.
-- components_json: composite search parameter component expressions (JSON array).

CREATE TABLE IF NOT EXISTS search_param_definitions (
    id              SERIAL       PRIMARY KEY,
    resource_type   VARCHAR(191) NOT NULL,
    param_name      VARCHAR(191) NOT NULL,
    param_type      VARCHAR(32)  NOT NULL,
    fhirpath_expr   TEXT         NOT NULL,
    is_custom       BOOLEAN      NOT NULL DEFAULT FALSE,
    ig_source       TEXT         NOT NULL DEFAULT '',
    target_types    TEXT         NOT NULL DEFAULT '',
    components_json TEXT         NOT NULL DEFAULT '',
    UNIQUE (resource_type, param_name)
);

CREATE INDEX IF NOT EXISTS idx_spd_resource ON search_param_definitions (resource_type);
CREATE INDEX IF NOT EXISTS idx_spd_custom   ON search_param_definitions (resource_type) WHERE is_custom = TRUE;
CREATE INDEX IF NOT EXISTS idx_spd_ig       ON search_param_definitions (ig_source) WHERE ig_source != '';

-- ─── Implementation Guide tracking ───────────────────────────────────────────
-- ig_packages records each loaded IG package so the server can skip re-downloading
-- it on restart. ig_profiles stores the StructureDefinition profiles declared by
-- each IG, used when building the CapabilityStatement.

CREATE TABLE IF NOT EXISTS ig_packages (
    id              SERIAL      PRIMARY KEY,
    package_name    TEXT        NOT NULL,
    package_version TEXT        NOT NULL,
    fhir_version    TEXT        NOT NULL DEFAULT '',
    loaded_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (package_name, package_version)
);

CREATE TABLE IF NOT EXISTS ig_profiles (
    id            SERIAL  PRIMARY KEY,
    package_name  TEXT    NOT NULL,
    profile_url   TEXT    NOT NULL,
    resource_type TEXT    NOT NULL DEFAULT '',
    sd_json       JSONB,
    UNIQUE (profile_url)
);

-- ─── base_definitions ────────────────────────────────────────────────────────
-- Core FHIR R4 resource StructureDefinitions (kind=resource,
-- derivation=specialization) shipped with the server and loaded at startup (see
-- internal/basedef). They let the server validate resources against the base spec
-- even when no profile is supplied. Like ig_profiles this is reference data, not
-- PHI, and is identical across tenants — so it carries no tenant_id and is
-- intentionally excluded from the Row-Level Security policies in section 7.

CREATE TABLE IF NOT EXISTS base_definitions (
    resource_type TEXT        NOT NULL PRIMARY KEY,
    sd_url        TEXT        NOT NULL DEFAULT '',
    sd_json       JSONB       NOT NULL,
    loaded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── FHIR Terminology: closure tables ────────────────────────────────────────
-- Support the $closure operation, which maintains a transitive closure table of
-- subsumption relationships between coded concepts. A closure context groups
-- related concepts; ClosureDeltaTable records each subsumes/subsumed-by pair.

CREATE TABLE IF NOT EXISTS "ClosureContextTable" (
    "ID"           SERIAL       PRIMARY KEY,
    "NAME"         VARCHAR(191) NOT NULL UNIQUE,
    "LAST_UPDATED" TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS "ClosureConceptTable" (
    "ID"           SERIAL       PRIMARY KEY,
    "CONTEXT_ID"   INT          NOT NULL,
    "SYSTEM"       VARCHAR(512) NOT NULL,
    "CODE"         VARCHAR(191) NOT NULL,
    "LAST_UPDATED" TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    FOREIGN KEY ("CONTEXT_ID") REFERENCES "ClosureContextTable"("ID") ON DELETE CASCADE,
    UNIQUE ("CONTEXT_ID", "SYSTEM", "CODE")
);

CREATE INDEX IF NOT EXISTS idx_closure_concept ON "ClosureConceptTable" ("CONTEXT_ID", "SYSTEM", "CODE");

CREATE TABLE IF NOT EXISTS "ClosureDeltaTable" (
    "ID"           SERIAL       PRIMARY KEY,
    "CONTEXT_ID"   INT          NOT NULL,
    "SUBSUMES_ID"  INT          NOT NULL,
    "SUBSUMED_ID"  INT          NOT NULL,
    "LAST_UPDATED" TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    FOREIGN KEY ("CONTEXT_ID")  REFERENCES "ClosureContextTable"("ID")  ON DELETE CASCADE,
    FOREIGN KEY ("SUBSUMES_ID") REFERENCES "ClosureConceptTable"("ID")  ON DELETE CASCADE,
    FOREIGN KEY ("SUBSUMED_ID") REFERENCES "ClosureConceptTable"("ID")  ON DELETE CASCADE,
    UNIQUE ("CONTEXT_ID", "SUBSUMES_ID", "SUBSUMED_ID")
);


-- ═══════════════════════════════════════════════════════════════════════════
-- 5. Planner statistics
-- ═══════════════════════════════════════════════════════════════════════════
-- Populated by ANALYZE (autoanalyze covers this after the bulk import).

-- Raise statistics targets for high-cardinality columns so the planner produces
-- accurate row-count estimates for multi-param searches.
ALTER TABLE sp_token     ALTER COLUMN code          SET STATISTICS 1000;
ALTER TABLE sp_token     ALTER COLUMN system        SET STATISTICS 1000;
ALTER TABLE sp_token     ALTER COLUMN resource_type SET STATISTICS 1000;
ALTER TABLE sp_token     ALTER COLUMN param_name    SET STATISTICS 1000;
ALTER TABLE sp_reference ALTER COLUMN target_id     SET STATISTICS 1000;
ALTER TABLE sp_reference ALTER COLUMN param_name    SET STATISTICS 1000;

-- Multivariate statistics: the per-column targets above still let the planner
-- assume resource_type / param_name / code are independent, so it badly
-- under-estimates a common (resource_type, param_name, code) combination — e.g.
-- Observation category=vital-signs (~20% of Observations) was estimated at <2%.
-- That misestimate made it materialize + sort the entire match set (135k rows,
-- one resources lookup each) instead of the abort-early ordered scan that stops
-- at the first page: ~966ms vs ~15ms on the perf dataset. MCV/dependencies over
-- the correlated columns correct the estimate so the planner picks the ordered
-- scan for dense codes and the id-first-style materialize for sparse ones.
CREATE STATISTICS IF NOT EXISTS stx_sp_token_rt_param_code (dependencies, ndistinct, mcv)
    ON resource_type, param_name, code FROM sp_token;

-- system|code searches (the common token form, e.g.
-- class=http://terminology.hl7.org/CodeSystem/v3-ActCode|AMB) filter on system
-- AND code, which are strongly correlated — a code like AMB only ever appears
-- under its own system. Without system in the stats the planner treats them as
-- independent and badly UNDER-estimates a dense combination: Encounter class=AMB
-- (62k rows) was estimated at 593, so it materialised + sorted every match and
-- joined resources per row (~2.7s) instead of the abort-early ordered scan
-- (~0.7ms). Adding system to the multivariate stat corrects the estimate.
CREATE STATISTICS IF NOT EXISTS stx_sp_token_rt_param_sys_code (dependencies, ndistinct, mcv)
    ON resource_type, param_name, system, code FROM sp_token;


-- ═══════════════════════════════════════════════════════════════════════════
-- 6. Autovacuum tuning for high-churn tables
-- ═══════════════════════════════════════════════════════════════════════════
-- Default autovacuum_vacuum_scale_factor=0.20 means PostgreSQL waits until 20%
-- of a table is dead before cleaning up. On tables with millions of rows that is
-- millions of dead tuples — causing index bloat, planner misestimation, and the
-- throughput degradation visible after ~500s in load test runs. Tighten to 2% so
-- autovacuum stays ahead of write-heavy workloads. These ALTER TABLE SET (...)
-- statements are idempotent: safe to re-run on an existing database.

ALTER TABLE resources SET (
    autovacuum_vacuum_scale_factor  = 0.02,
    autovacuum_analyze_scale_factor = 0.01
);

ALTER TABLE resource_history SET (
    autovacuum_vacuum_scale_factor  = 0.02,
    autovacuum_analyze_scale_factor = 0.01
);

-- sp_* tables are DELETE+INSERT heavy on every UPDATE; keep them lean so index
-- bloat does not accumulate between vacuum cycles.
ALTER TABLE sp_string    SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.01);
ALTER TABLE sp_token     SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.01);
ALTER TABLE sp_date      SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.01);
ALTER TABLE sp_number    SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.01);
ALTER TABLE sp_quantity  SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.01);
ALTER TABLE sp_uri       SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.01);
ALTER TABLE sp_reference SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.01);
ALTER TABLE sp_coords    SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.01);


-- ═══════════════════════════════════════════════════════════════════════════
-- 7. Multi-tenancy: Row-Level Security
-- ═══════════════════════════════════════════════════════════════════════════
-- Every PHI-bearing table (resources, resource_history, sp_*) carries a tenant_id
-- column that defaults to the app.current_tenant runtime setting the server applies
-- per request. Their primary / foreign keys and the resource_history version-
-- uniqueness all lead with tenant_id, so two tenants may hold resources with the
-- same id. The global configuration tables (search_param_definitions, ig_*, the
-- closure tables, base_definitions, schema_version) are intentionally SHARED across
-- tenants and carry no tenant_id.
--
-- Isolation is enforced by Row-Level Security: each policy restricts rows to the
-- current tenant. FORCE makes the policy apply to the table owner too. An unset
-- tenant fails CLOSED — NULL matches no rows and violates the NOT NULL tenant_id
-- on write.
--
-- NOTE: the server (and any tooling that touches these tables at runtime) MUST
-- connect as a NON-superuser role — superusers and roles with BYPASSRLS ignore
-- Row-Level Security entirely.
DO $rls$
DECLARE
    t             text;
    tenant_tables text[] := ARRAY['resources','resource_history','sp_string','sp_token',
                                  'sp_date','sp_number','sp_quantity','sp_uri',
                                  'sp_reference','sp_coords'];
BEGIN
    FOREACH t IN ARRAY tenant_tables LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE  ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I', t);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON %I '
            || 'USING (tenant_id = current_setting(''app.current_tenant'', true)) '
            || 'WITH CHECK (tenant_id = current_setting(''app.current_tenant'', true))',
            t);
    END LOOP;
END
$rls$;


-- ═══════════════════════════════════════════════════════════════════════════
-- 8. LEAKPROOF numeric comparison operators
-- ═══════════════════════════════════════════════════════════════════════════
-- Under Row-Level Security the sp_* tables are security barriers: a user WHERE
-- qual is evaluated *inside* the index scan (as an index cond) only if its
-- operator is LEAKPROOF; otherwise it is held back and applied as a post-filter
-- above the barrier. PostgreSQL ships text and date/timestamptz comparisons
-- LEAKPROOF, but NOT the numeric ones. So `value_low > $1` on sp_quantity
-- (numeric(20,6)) could not use its (tenant_id, resource_type, param_name,
-- value_low, …) index bound — every quantity/number search scanned the entire
-- (tenant, type, param) partition and filtered value_low in memory (~50ms/query
-- on the perf dataset, worse under concurrency where it spawned parallel seq
-- scans). numeric comparisons are pure arithmetic and do not leak argument values
-- via errors or side channels, so marking them LEAKPROOF is safe.
--
-- Requires superuser: only a superuser may set LEAKPROOF. Wrapped so a non-super
-- DDL role (or managed Postgres with no superuser, e.g. Azure Flexible Server)
-- still applies the rest of the schema — the optimization is skipped with a notice
-- and those searches fall back to the correct, slower post-filter path.
DO $leakproof$
BEGIN
    ALTER FUNCTION numeric_eq(numeric, numeric) LEAKPROOF;
    ALTER FUNCTION numeric_gt(numeric, numeric) LEAKPROOF;
    ALTER FUNCTION numeric_ge(numeric, numeric) LEAKPROOF;
    ALTER FUNCTION numeric_lt(numeric, numeric) LEAKPROOF;
    ALTER FUNCTION numeric_le(numeric, numeric) LEAKPROOF;
EXCEPTION
    WHEN insufficient_privilege THEN
        RAISE NOTICE 'skipping LEAKPROOF on numeric comparison operators (requires superuser); quantity/number range searches under RLS will use a slower post-filter';
END
$leakproof$;


-- ═══════════════════════════════════════════════════════════════════════════
-- 9. Schema version history
-- ═══════════════════════════════════════════════════════════════════════════
-- Fresh installs get everything above in its final form; the notes below are the
-- upgrade guidance for EXISTING databases, where CREATE ... IF NOT EXISTS will not
-- alter an object that already exists. Run the relevant migration by hand when
-- bumping to that version.
--
--   v5  Ingest write-amplification diet: slimmed the sp_* _source indexes to
--       (tenant_id, resource_id, resource_type) and dropped idx_sp_tok_system.
--       Superseded by v8.
--   v6  Row-Level Security on all PHI tables (section 7).
--   v7  base_definitions table (core FHIR R4 StructureDefinitions).
--   v8  Reverted the v5 _source diet, which had regressed multi-parameter search.
--       Multi-param searches use correlated EXISTS probes (internal/store/
--       search.go); the slimmed indexes forced each probe to scan and heap-fetch
--       every sp_* row of a candidate resource to re-check param_name and value.
--       The _source indexes above restore the pre-v5 composite forms (tenant_id-led,
--       with param_name + value columns) so the probe resolves index-only.
--       idx_sp_tok_system stays dropped (redundant strict prefix of
--       idx_sp_tok_sys_code). Existing DBs must DROP and recreate each _source
--       index (CREATE INDEX IF NOT EXISTS will not rebuild an existing one), e.g.:
--           DROP   INDEX CONCURRENTLY IF EXISTS idx_sp_str_source;
--           CREATE INDEX CONCURRENTLY idx_sp_str_source
--               ON sp_string (tenant_id, resource_id, resource_type, param_name, value_lower);
--       (repeat for tok/date/num/qty/uri/ref with each table's column list above).
--   v9  Marked numeric comparison operators LEAKPROOF (section 8) so quantity/
--       number range predicates push into the sp_* value indexes under RLS.
--   v10 Recency covering indexes idx_sp_num_recent / idx_sp_qty_recent (defined
--       with their tables above) for the early-exit id-first fetch. Existing DBs:
--       run the ALTER TABLE ... ADD COLUMN last_updated and the matching
--       CREATE INDEX CONCURRENTLY by hand.
--   v11 Recency covering index idx_sp_tok_recent (defined with sp_token above) for
--       the composite token+quantity early-exit drive. Same manual steps as v10.

INSERT INTO schema_version (version)
VALUES (5), (6), (7), (8), (9), (10), (11)
ON CONFLICT DO NOTHING;
