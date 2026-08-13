-- Vakantieplanner — Supabase setup
-- Uitvoeren in het Supabase-dashboard: SQL Editor → New query → plakken → Run.
--
-- BELANGRIJK: vervang hieronder KIES-EEN-GEHEIME-CODE door je eigen toegangscode
-- (die code tik je daarna in de app in). Commit je echte code nooit in deze repo.
--
-- Multi-account: elke toegangscode wijst naar een eigen dataset via state_id.
-- Zo kan je meerdere, van elkaar gescheiden planners hebben (bv. een privé-
-- planner en een gedeelde reisplanner) met elk hun eigen code.

-- Plannerdata: één rij per dataset, met de volledige state als JSON.
create table if not exists planner_state (
  id text primary key,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

-- Geldige toegangscodes. Elke code wijst via state_id naar een dataset in
-- planner_state (meerdere codes mogen naar dezelfde dataset wijzen om te delen).
create table if not exists access_keys (
  key text primary key,
  state_id text not null default 'main'
);

-- RLS aan zonder policies: niemand kan de tabellen rechtstreeks lezen of schrijven
-- met de (publieke) anon key. Alle toegang loopt via de functies hieronder.
alter table planner_state enable row level security;
alter table access_keys enable row level security;
revoke all on table planner_state from anon, authenticated;
revoke all on table access_keys from anon, authenticated;

insert into access_keys (key, state_id) values ('KIES-EEN-GEHEIME-CODE', 'main')
on conflict (key) do nothing;

-- Data ophalen; geeft een fout bij een ongeldige code.
-- Leest de dataset die bij de code hoort (state_id).
create or replace function planner_load(access_key text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare sid text;
begin
  select state_id into sid from access_keys where key = access_key;
  if sid is null then
    raise exception 'invalid key';
  end if;
  return (select data from planner_state where id = sid);
end;
$$;

-- Data opslaan (volledige state, last-write-wins); fout bij een ongeldige code.
-- Schrijft naar de dataset die bij de code hoort (state_id).
create or replace function planner_save(access_key text, payload jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare sid text;
begin
  select state_id into sid from access_keys where key = access_key;
  if sid is null then
    raise exception 'invalid key';
  end if;
  insert into planner_state (id, data, updated_at)
  values (sid, payload, now())
  on conflict (id) do update set data = excluded.data, updated_at = now();
end;
$$;

-- Een extra (gedeelde) code toevoegen met een eigen dataset:
--   insert into access_keys (key, state_id) values ('GEDEELDE-CODE', 'frankrijk');
-- Meerdere codes naar dezelfde state_id laten wijzen = samen dezelfde planner delen.
