-- Pre-expand compatibility for legacy rows without a usable Sportlink ID or
-- parent e-mail. This migration intentionally sorts before the Phase B expand
-- migration so its exact external-identity backfill can safely ignore NULL.

alter table app.members
  alter column relation_number drop not null,
  alter column email drop not null;

do $$
begin
  if exists(
    select 1
    from app.members member
    where nullif(btrim(member.relation_number), '') is not null
    group by upper(btrim(member.relation_number))
    having count(*) > 1
  ) then
    raise exception 'MEMBER_RELATION_NORMALIZATION_CONFLICT' using errcode = '23505';
  end if;
end;
$$;

update app.members
set relation_number = nullif(btrim(relation_number), ''),
    email = lower(nullif(btrim(email), ''))
where relation_number is distinct from nullif(btrim(relation_number), '')
   or email is distinct from lower(nullif(btrim(email), ''));
