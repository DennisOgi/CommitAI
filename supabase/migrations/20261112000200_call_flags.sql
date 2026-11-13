-- Moments the employee flagged as a commitment during a call (offsets in ms from answer).
-- The extractor is told to look hardest around them and boosts confidence for findings nearby.
alter table calls add column if not exists flags jsonb not null default '[]'::jsonb;
comment on column calls.flags is 'Offsets (ms) where the employee tapped "Flag commitment" during the call';
