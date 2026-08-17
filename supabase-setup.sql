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


-- ===========================================================================
-- Boodschappenlijstje: één rij per item (i.p.v. in de state-JSON)
-- ===========================================================================
-- Waarom apart: planner_state wordt in zijn geheel weggeschreven (last-write-
-- wins). Als twee mensen tegelijk een boodschap toevoegen, overschreef de
-- laatste save de toevoeging van de ander. Met één rij per item raakt niemands
-- item nog een ander item, en is er dus geen conflict meer.
--
-- Dit script mag je meermaals draaien; alles is idempotent.

create table if not exists shopping_items (
  state_id   text not null,
  trip_id    text not null,
  id         text not null,
  text       text not null,
  done       boolean not null default false,
  who        text,
  -- Verwijderen gebeurt met een grafsteen i.p.v. een echte delete. Zo kan een
  -- toestel dat de verwijdering nog niet zag het item niet terug tot leven
  -- wekken met een afvink- of hernoem-actie.
  deleted    boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (state_id, trip_id, id)
);

create index if not exists shopping_items_live_idx
  on shopping_items (state_id, created_at) where not deleted;

-- Zelfde model als hierboven: geen rechtstreekse toegang met de anon key,
-- alles loopt via de security-definer functie met code-controle.
alter table shopping_items enable row level security;
revoke all on table shopping_items from anon, authenticated;

-- Alles in één call: eerst de meegestuurde wijzigingen toepassen, dan de
-- volledige actuele lijst teruggeven. De client stuurt losse bewerkingen
-- ("voeg dit item toe", "vink dit item af"), nooit de hele lijst — daardoor
-- kan gelijktijdig werk niet meer verloren gaan.
--
-- ops = [{op:'add',      trip, id, text, done, who}
--        {op:'done',     trip, id, done}      -- absolute waarde, geen toggle
--        {op:'text',     trip, id, text}
--        {op:'del',      trip, id}
--        {op:'delTrip',  trip}]
--
-- Alle bewerkingen zijn idempotent: opnieuw versturen na een mislukte
-- verbinding levert nooit dubbels of ander resultaat op.
create or replace function shopping_sync(access_key text, ops jsonb default '[]'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  sid  text;
  op   jsonb;
  res  jsonb;
  flag boolean;
begin
  select state_id into sid from access_keys where key = access_key;
  if sid is null then
    raise exception 'invalid key';
  end if;

  for op in
    select value from jsonb_array_elements(
      case when jsonb_typeof(ops) = 'array' then ops else '[]'::jsonb end)
  loop
    -- Let op de coalesce: zonder 'done'-veld levert IN de waarde NULL op
    -- (geen false), en dat botst met de NOT NULL-kolom.
    flag := coalesce((op->>'done') in ('true', 't', '1'), false);

    if op->>'op' = 'add' then
      -- Tekstwaarden defensief bijknippen; de client doet dat ook, maar de
      -- functie is het enige wat echt afgedwongen is.
      insert into shopping_items (state_id, trip_id, id, text, done, who)
      values (sid, op->>'trip', op->>'id',
              left(btrim(coalesce(op->>'text', '')), 200),
              flag,
              nullif(btrim(left(coalesce(op->>'who', ''), 24)), ''))
      on conflict (state_id, trip_id, id) do nothing;

    elsif op->>'op' = 'done' then
      update shopping_items
         set done = flag, updated_at = now()
       where state_id = sid and trip_id = op->>'trip' and id = op->>'id'
         and not deleted and done is distinct from flag;

    elsif op->>'op' = 'text' then
      update shopping_items
         set text = left(btrim(op->>'text'), 200), updated_at = now()
       where state_id = sid and trip_id = op->>'trip' and id = op->>'id'
         and not deleted
         and btrim(coalesce(op->>'text', '')) <> ''
         and text is distinct from left(btrim(op->>'text'), 200);

    elsif op->>'op' = 'del' then
      update shopping_items
         set deleted = true, updated_at = now()
       where state_id = sid and trip_id = op->>'trip' and id = op->>'id'
         and not deleted;

    elsif op->>'op' = 'delTrip' then
      update shopping_items
         set deleted = true, updated_at = now()
       where state_id = sid and trip_id = op->>'trip' and not deleted;
    end if;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object(
           'trip_id', trip_id, 'id', id, 'text', text, 'done', done, 'who', who)
           order by created_at, id), '[]'::jsonb)
    into res
    from shopping_items
   where state_id = sid and not deleted;

  return res;
end;
$$;

-- Overzetten van wat vandaag nog in de state-JSON staat. Draait dit script
-- opnieuw, dan verandert er niets meer (on conflict do nothing).
-- De app zelf ruimt daarna de 'shopping'-lijsten uit de JSON op, en verhuist
-- alsnog wat een oude (nog niet ververste) app-versie er later inzet — er kan
-- dus niets achterblijven, ook niet als dit script vóór de app-update draait.
insert into shopping_items (state_id, trip_id, id, text, done, who)
select ps.id,
       tr->>'id',
       it->>'id',
       left(btrim(it->>'text'), 200),
       coalesce((it->>'done') in ('true', 't', '1'), false),
       nullif(btrim(left(coalesce(it->>'who', ''), 24)), '')
  from planner_state ps
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(ps.data->'trips') = 'array'
         then ps.data->'trips' else '[]'::jsonb end) tr
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(tr->'shopping') = 'array'
         then tr->'shopping' else '[]'::jsonb end) it
 where tr->>'id' is not null
   and it->>'id' is not null
   and btrim(coalesce(it->>'text', '')) <> ''
on conflict (state_id, trip_id, id) do nothing;

-- Grafstenen zijn klein, maar je kan ze na een tijd opruimen:
--   delete from shopping_items where deleted and updated_at < now() - interval '90 days';
