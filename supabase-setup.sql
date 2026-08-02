-- Vakantieplanner — Supabase setup
-- Uitvoeren in het Supabase-dashboard: SQL Editor → New query → plakken → Run.
--
-- BELANGRIJK: vervang hieronder KIES-EEN-GEHEIME-CODE door je eigen toegangscode
-- (die code tik je daarna in de app in). Commit je echte code nooit in deze repo.

-- Plannerdata: één rij met de volledige state als JSON.
create table if not exists planner_state (
  id text primary key,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

-- Geldige toegangscodes (meerdere kunnen, bv. om later een code te vervangen).
create table if not exists access_keys (
  key text primary key
);

-- RLS aan zonder policies: niemand kan de tabellen rechtstreeks lezen of schrijven
-- met de (publieke) anon key. Alle toegang loopt via de functies hieronder.
alter table planner_state enable row level security;
alter table access_keys enable row level security;
revoke all on table planner_state from anon, authenticated;
revoke all on table access_keys from anon, authenticated;

insert into access_keys (key) values ('KIES-EEN-GEHEIME-CODE')
on conflict (key) do nothing;

-- Data ophalen; geeft een fout bij een ongeldige code.
create or replace function planner_load(access_key text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from access_keys where key = access_key) then
    raise exception 'invalid key';
  end if;
  return (select data from planner_state where id = 'main');
end;
$$;

-- Data opslaan (volledige state, last-write-wins); fout bij een ongeldige code.
create or replace function planner_save(access_key text, payload jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from access_keys where key = access_key) then
    raise exception 'invalid key';
  end if;
  insert into planner_state (id, data, updated_at)
  values ('main', payload, now())
  on conflict (id) do update set data = excluded.data, updated_at = now();
end;
$$;
