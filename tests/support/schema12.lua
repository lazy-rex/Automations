-- The old schema steps 1 to 12, verbatim from automations_sql.lua at 4fc4938 (lines 13 to 24):
-- the steps that release 4.2 shipped. tests/schema.lua builds a version-12 database from them.
return {
    'CREATE TABLE meta (name TEXT PRIMARY KEY, value TEXT NOT NULL)',
    'CREATE TABLE automations (id TEXT PRIMARY KEY, rev TEXT NOT NULL, doc TEXT NOT NULL)',
    'CREATE TABLE states (id TEXT PRIMARY KEY, rev TEXT NOT NULL, doc TEXT NOT NULL)',
    'CREATE TABLE runs (run_key TEXT PRIMARY KEY, automation_id TEXT NOT NULL, rev TEXT NOT NULL, status TEXT NOT NULL, q TEXT, t TEXT, agent TEXT, doc TEXT NOT NULL)',
    'CREATE UNIQUE INDEX runs_q ON runs (q) WHERE q IS NOT NULL',
    'CREATE UNIQUE INDEX runs_t ON runs (t) WHERE t IS NOT NULL',
    "CREATE INDEX runs_delivered ON runs (agent, run_key) WHERE status = 'delivered'",
    'CREATE INDEX runs_auto ON runs (automation_id, status)',
    'CREATE TABLE presets (name TEXT PRIMARY KEY, rev TEXT NOT NULL, automation_id TEXT NOT NULL)',
    'CREATE TABLE seen (key TEXT PRIMARY KEY, rev TEXT NOT NULL, doc TEXT NOT NULL)',
    'CREATE TABLE retired (key TEXT PRIMARY KEY, rev TEXT NOT NULL, doc TEXT NOT NULL)',
    'CREATE TABLE ops (key TEXT PRIMARY KEY, fingerprint TEXT, reply TEXT NOT NULL)',
}
