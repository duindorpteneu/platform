revoke insert, update, delete, truncate, references, trigger
on all tables in schema app from authenticated;

grant select on all tables in schema app to authenticated;

revoke all on all sequences in schema app from authenticated;

alter default privileges for role postgres in schema app
  revoke insert, update, delete, truncate, references, trigger on tables from authenticated;

alter default privileges for role postgres in schema app
  revoke all on sequences from authenticated;
