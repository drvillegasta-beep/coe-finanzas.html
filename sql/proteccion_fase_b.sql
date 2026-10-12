-- ═══ PROTECCIÓN DE FINANZAS · FASE B (NO EJECUTAR TODAVÍA) ═══
-- Requisito: todos los usuarios activos de Finanzas entraron al menos una vez con la versión
-- que abre sesión segura (12 oct 2026 en adelante). Revisión:
--   select f.nombre, f.usuario, u.last_sign_in_at
--   from fin_usuarios f left join auth.users u on u.raw_app_meta_data->>'app_user_id' = f.id::text and u.raw_app_meta_data->>'app'='fin'
--   where f.activo order by u.last_sign_in_at nulls first;
-- También requiere que COE Nómina ya abra su sesión segura (escribe en fin_facturas y lee nom_periodos).

create or replace function public.coe_app(p text) returns boolean language sql stable as $$
  select coalesce((auth.jwt()->'app_metadata'->'apps') ? p, false)
$$;

do $$
declare t text; pol record;
begin
  foreach t in array array['fin_entidades','fin_facturas','fin_abonos','fin_recurrentes','fin_log','fin_config','fin_razones_sociales',
    'fin_documentos','fin_pedidos','fin_correos','fin_tareas','fin_tareas_avances','fin_cierres_jornada','fin_solicitudes_baja','fin_usuarios'] loop
    for pol in select policyname from pg_policies where schemaname='public' and tablename=t loop
      execute format('drop policy %I on public.%I', pol.policyname, t);
    end loop;
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('create policy coe_fin on public.%I for all to authenticated using (public.coe_app(''fin'')) with check (public.coe_app(''fin''))', t);
  end loop;
end $$;

-- Nómina registra su cierre como egreso en fin_facturas
create policy coe_nom on public.fin_facturas for all to authenticated using (public.coe_app('nom')) with check (public.coe_app('nom'));

-- Contraseñas y PIN nunca se leen desde el navegador
revoke select on public.fin_usuarios from authenticated;
grant select (id,nombre,rol,activo,created_at,permisos,email,sede,limite_autoriza,usuario,debe_cambiar) on public.fin_usuarios to authenticated;
