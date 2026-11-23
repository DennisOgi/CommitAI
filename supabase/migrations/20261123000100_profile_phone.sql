-- Users' own phone numbers, so imported contacts can be matched to Commit AI accounts by number
-- (and people see which of their contacts are on Commit AI, the way Telegram does).
-- One account per number. Written only by the API server (service role).
alter table profiles add column if not exists phone_e164 text;
create unique index if not exists profiles_phone_e164_key on profiles (phone_e164) where phone_e164 is not null;

-- Matching imported contacts by number.
create index if not exists contacts_phone_e164 on contacts (phone_e164) where phone_e164 is not null;
