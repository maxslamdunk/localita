-- One row per accepted report. `report` is the whole report as JSON; the
-- other columns repeat a few of its fields so they can be queried. Nothing
-- about the sender is stored.
CREATE TABLE submissions (
  submission_id TEXT PRIMARY KEY,
  received_at TEXT NOT NULL,
  format INTEGER NOT NULL,
  device TEXT NOT NULL,
  app_version TEXT NOT NULL,
  outcome TEXT NOT NULL,
  report TEXT NOT NULL
);
