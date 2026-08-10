-- The semantic no-op introduced in the preceding migration is valid only for
-- states that were already explicitly confirmed, locked or requested. An
-- imported_unconfirmed value must still transition to a parent confirmation,
-- even when the chosen variant equals the imported suggestion.
do $migration$
declare
  function_source text;
  needle text := $needle$
    elsif not differs then
$needle$;
  replacement text := $replacement$
    elsif not differs
      and size_profile.selection_status in (
        'confirmed',
        'locked',
        'change_requested'
      )
    then
$replacement$;
begin
  function_source := pg_get_functiondef(
    'public.confirm_parent_package_sizes(text,uuid,jsonb,text,uuid)'::regprocedure
  );
  if (
    length(function_source) - length(replace(function_source, needle, ''))
  ) / length(needle) <> 1 then
    raise exception 'PARENT_SIZE_NOOP_STATE_PATCH_AMBIGUOUS';
  end if;
  execute replace(function_source, needle, replacement);
end;
$migration$;

notify pgrst, 'reload schema';
