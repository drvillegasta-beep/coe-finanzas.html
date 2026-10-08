-- COE Finanzas v3 · Fase 2: Pendientes con prioridad, seguimiento, retrasos y cierre del día (aditivo)

alter table public.fin_tareas add column if not exists prioridad text default 'moderado';
alter table public.fin_tareas add column if not exists categoria text;
alter table public.fin_tareas add column if not exists origen text default 'cronograma';
alter table public.fin_tareas add column if not exists sede text;
alter table public.fin_tareas add column if not exists creada_por uuid;
alter table public.fin_tareas add column if not exists fecha_limite_original date;
alter table public.fin_tareas add column if not exists reprogramaciones integer default 0;
alter table public.fin_tareas add column if not exists ultimo_avance text;
alter table public.fin_tareas add column if not exists ultimo_avance_at timestamptz;
alter table public.fin_tareas add column if not exists updated_at timestamptz default now();
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'fin_tareas_prioridad_check') then
    alter table public.fin_tareas add constraint fin_tareas_prioridad_check check (prioridad in ('critico','moderado','no_critico'));
  end if;
end $$;

-- Prioridad del cronograma fijo
update public.fin_tareas set prioridad = case clave
  when 'edo_cuenta' then 'critico' when 'polizas' then 'critico' when 'fact_pend' then 'critico' when 'cierre' then 'critico'
  when 'conc_banc' then 'moderado' when 'flujo' then 'moderado' when 'inv_farm' then 'moderado'
  else 'no_critico' end, categoria = coalesce(categoria, 'Cronograma contable')
where origen = 'cronograma' or origen is null;

-- Bitácora de avances (solo se agrega, nunca se edita)
create table if not exists public.fin_tareas_avances (
  id uuid primary key default gen_random_uuid(),
  tarea_id uuid not null references public.fin_tareas(id),
  usuario_id uuid,
  tipo text not null,           -- creacion | avance | estado | reprogramacion | cumplida
  estado_ant text, estado_nuevo text,
  fecha_ant date, fecha_nueva date,
  nota text, evidencia_url text,
  created_at timestamptz default now()
);
create index if not exists fin_tareas_avances_tarea_idx on public.fin_tareas_avances (tarea_id, created_at);

-- Cierre del día de cada responsable
create table if not exists public.fin_cierres_jornada (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null,
  fecha date not null default current_date,
  resumen text,
  snapshot jsonb,
  created_at timestamptz default now(),
  unique (usuario_id, fecha)
);

do $$
declare t text;
begin
  foreach t in array array['fin_tareas_avances','fin_cierres_jornada'] loop
    if not exists (select 1 from pg_trigger where tgname = 'trg_inmutable' and tgrelid = ('public.' || t)::regclass) then
      execute format('create trigger trg_inmutable before update or delete on public.%I for each row execute function public.fin_log_inmutable()', t);
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- Permisos: Dirección puede asignar pendientes; Administración maneja los suyos
create or replace function public.fin__nivel(u public.fin_usuarios, p_mod text)
returns integer language sql stable as $$
  select coalesce(
    nullif(u.permisos->>p_mod, '')::int,
    case u.rol
      when 'admin' then 3
      when 'direccion' then case p_mod when 'pedidos' then 3 when 'tareas' then 3 when 'revision' then 2 when 'config' then 0 else 1 end
      when 'contadora' then case p_mod when 'pagos' then 1 when 'ingreso' then 1 when 'reportes' then 1 when 'auditoria' then 1
                                       when 'config' then 0 when 'tablero' then 1 else 2 end
      when 'administracion' then case p_mod when 'pedidos' then 3 when 'cxp' then 2 when 'fps' then 2 when 'tareas' then 2 when 'proveedores' then 1
                                       when 'auditoria' then 0 when 'config' then 0 when 'pagos' then 0 else 1 end
      when 'solicitante' then case p_mod when 'pedidos' then 2 when 'tablero' then 1 else 0 end
      else 1 end)
$$;

-- Crear pendiente
create or replace function public.fin_tarea_crear(p_usuario uuid, p_pin text, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; v_id uuid; v_resp uuid := coalesce(nullif(p_datos->>'responsable_id','')::uuid, p_usuario);
  v_pri text := coalesce(nullif(p_datos->>'prioridad',''), 'moderado'); v_lim date := nullif(p_datos->>'fecha_limite','')::date;
begin
  f := public.fin__firmar_mod(p_usuario, p_pin, 'tareas', 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_datos->>'titulo'), '') = '' then return jsonb_build_object('ok', false, 'error', 'titulo'); end if;
  if v_lim is null then return jsonb_build_object('ok', false, 'error', 'fecha'); end if;
  if v_pri not in ('critico','moderado','no_critico') then return jsonb_build_object('ok', false, 'error', 'prioridad'); end if;
  -- Asignar a otra persona: solo quien autoriza pendientes (Dirección General o Dirección)
  if v_resp <> p_usuario and public.fin__nivel(f.u, 'tareas') < 3 then return jsonb_build_object('ok', false, 'error', 'asignar'); end if;
  insert into public.fin_tareas (titulo, descripcion, entregable, prioridad, categoria, origen, sede, responsable_id,
    responsable_rol, fecha_limite, fecha_limite_original, estado, creada_por, frecuencia)
  values (trim(p_datos->>'titulo'), nullif(p_datos->>'descripcion',''), nullif(p_datos->>'entregable',''), v_pri,
    nullif(p_datos->>'categoria',''), 'manual', nullif(p_datos->>'sede',''), v_resp,
    (select rol from public.fin_usuarios where id = v_resp), v_lim, v_lim, 'pendiente', p_usuario, 'unica')
  returning id into v_id;
  insert into public.fin_tareas_avances (tarea_id, usuario_id, tipo, estado_nuevo, fecha_nueva, nota)
  values (v_id, p_usuario, 'creacion', 'pendiente', v_lim, nullif(p_datos->>'descripcion',''));
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Avance, cambio de estatus o reprogramación (todo queda en la bitácora)
create or replace function public.fin_tarea_avance(p_usuario uuid, p_pin text, p_tarea uuid, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; t public.fin_tareas; v_est text := nullif(p_datos->>'estado','');
  v_nota text := nullif(trim(p_datos->>'nota'),''); v_fecha date := nullif(p_datos->>'fecha_nueva','')::date;
  v_pri text := nullif(p_datos->>'prioridad','');
begin
  f := public.fin__firmar_mod(p_usuario, p_pin, 'tareas', 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  select * into t from public.fin_tareas where id = p_tarea for update;
  if t.id is null then return jsonb_build_object('ok', false, 'error', 'tarea'); end if;
  if t.estado in ('cumplida','cancelada') then return jsonb_build_object('ok', false, 'error', 'cerrada'); end if;
  if v_est is not null and v_est not in ('pendiente','en_proceso','bloqueado','cancelada') then return jsonb_build_object('ok', false, 'error', 'estado'); end if;
  if v_est = 'cancelada' and public.fin__nivel(f.u, 'tareas') < 3 then return jsonb_build_object('ok', false, 'error', 'solo_director'); end if;
  if v_pri is not null and public.fin__nivel(f.u, 'tareas') < 3 then return jsonb_build_object('ok', false, 'error', 'sin_permiso'); end if;
  if (v_est in ('bloqueado','cancelada') or v_fecha is not null) and v_nota is null then return jsonb_build_object('ok', false, 'error', 'motivo'); end if;
  if v_est is null and v_fecha is null and v_pri is null and v_nota is null then return jsonb_build_object('ok', false, 'error', 'nota'); end if;
  if v_fecha is not null and v_fecha <> t.fecha_limite then
    insert into public.fin_tareas_avances (tarea_id, usuario_id, tipo, fecha_ant, fecha_nueva, nota)
    values (p_tarea, p_usuario, 'reprogramacion', t.fecha_limite, v_fecha, v_nota);
  end if;
  if v_est is not null and v_est <> t.estado then
    insert into public.fin_tareas_avances (tarea_id, usuario_id, tipo, estado_ant, estado_nuevo, nota)
    values (p_tarea, p_usuario, 'estado', t.estado, v_est, v_nota);
  end if;
  if v_pri is not null and v_pri <> t.prioridad then
    insert into public.fin_tareas_avances (tarea_id, usuario_id, tipo, nota) values (p_tarea, p_usuario, 'prioridad', 'Prioridad ' || t.prioridad || ' → ' || v_pri);
  end if;
  if (v_est is null or v_est = t.estado) and (v_fecha is null or v_fecha = t.fecha_limite) and (v_pri is null or v_pri = t.prioridad) then
    insert into public.fin_tareas_avances (tarea_id, usuario_id, tipo, nota, evidencia_url) values (p_tarea, p_usuario, 'avance', v_nota, nullif(p_datos->>'evidencia_url',''));
  end if;
  update public.fin_tareas set
    estado = coalesce(v_est, estado),
    prioridad = coalesce(v_pri, prioridad),
    fecha_limite_original = coalesce(fecha_limite_original, fecha_limite),
    reprogramaciones = reprogramaciones + case when v_fecha is not null and v_fecha <> fecha_limite then 1 else 0 end,
    fecha_limite = coalesce(v_fecha, fecha_limite),
    ultimo_avance = coalesce(v_nota, ultimo_avance), ultimo_avance_at = now(), updated_at = now()
  where id = p_tarea;
  return jsonb_build_object('ok', true);
end $$;

-- Cumplir: evidencia o nota obligatoria
create or replace function public.fin_tarea_cumplir(p_usuario uuid, p_pin text, p_tarea uuid, p_evidencia text, p_nota text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; t public.fin_tareas;
begin
  f := public.fin__firmar_mod(p_usuario, p_pin, 'tareas', 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(p_evidencia, '') = '' and coalesce(trim(p_nota), '') = '' then return jsonb_build_object('ok', false, 'error', 'evidencia'); end if;
  select * into t from public.fin_tareas where id = p_tarea for update;
  if t.id is null or t.estado in ('cumplida','cancelada') then return jsonb_build_object('ok', false, 'error', 'cerrada'); end if;
  update public.fin_tareas set estado = 'cumplida', cumplida_por = (f.u).id, cumplida_at = now(),
    evidencia_url = nullif(p_evidencia, ''), nota = nullif(p_nota, ''), fecha_limite_original = coalesce(fecha_limite_original, fecha_limite),
    ultimo_avance = coalesce(nullif(p_nota, ''), 'Cumplida'), ultimo_avance_at = now(), updated_at = now() where id = p_tarea;
  insert into public.fin_tareas_avances (tarea_id, usuario_id, tipo, estado_ant, estado_nuevo, nota, evidencia_url)
  values (p_tarea, p_usuario, 'cumplida', t.estado, 'cumplida', nullif(p_nota, ''), nullif(p_evidencia, ''));
  return jsonb_build_object('ok', true);
end $$;

-- Cierre del día
create or replace function public.fin_cerrar_jornada(p_usuario uuid, p_pin text, p_resumen text, p_snapshot jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record;
begin
  f := public.fin__firmar(p_usuario, p_pin);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if exists (select 1 from public.fin_cierres_jornada where usuario_id = p_usuario and fecha = current_date) then
    return jsonb_build_object('ok', false, 'error', 'ya_cerrado');
  end if;
  insert into public.fin_cierres_jornada (usuario_id, fecha, resumen, snapshot) values (p_usuario, current_date, nullif(trim(p_resumen),''), p_snapshot);
  return jsonb_build_object('ok', true);
end $$;

-- Cronograma con prioridad
create or replace function public.fin_generar_tareas(p_mes date default current_date)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare m date := date_trunc('month', p_mes)::date; ult date := (date_trunc('month', p_mes) + interval '1 month - 1 day')::date; n int;
begin
  insert into public.fin_tareas (clave, titulo, descripcion, entregable, frecuencia, fecha_limite, fecha_limite_original, prioridad, categoria, origen,
    responsable_rol, responsable_id)
  select t.clave, t.titulo, t.descr, t.entregable, 'mensual', least(m + (t.dia - 1), ult), least(m + (t.dia - 1), ult), t.pri, 'Cronograma contable', 'cronograma',
    'contadora', (select id from public.fin_usuarios where activo and rol = 'contadora' order by created_at limit 1)
  from (values
    ('edo_cuenta', 'Estados de cuenta y XML al contador externo', 'Estados de cuenta bancarios del mes anterior y relación de XML emitidos y recibidos.', 'Acuse de envío', 5, 'critico'),
    ('conc_banc', 'Conciliación bancaria de todas las cuentas', 'Depurar partidas en tránsito.', 'Conciliación firmada', 10, 'moderado'),
    ('flujo', 'Flujo de efectivo proyectado del mes', 'Ingresos contra egresos y necesidades de liquidez.', 'Flujo mensual', 10, 'moderado'),
    ('inv_farm', 'Inventario de farmacia y parcial de óptica; pedido mensual de quirófano', 'Conteo con cuadre contra sistema y caducidades.', 'Acta de inventario y orden de compra', 15, 'moderado'),
    ('plan_compras', 'Planeación de pedidos de medicamentos y óptica', 'Con base en histórico y temporada.', 'Plan de compras', 18, 'no_critico'),
    ('polizas', 'Pago de pólizas y servicios mensuales', 'Seguros, mantenimientos, suscripciones, rentas.', 'Comprobantes', 22, 'critico'),
    ('antiguedad', 'Antigüedad de cuentas por cobrar y por pagar', 'Revisar saldos vencidos.', 'Reporte de antigüedad', 25, 'no_critico'),
    ('fact_pend', 'Facturas por solicitar en cero', 'Todas las facturas de pagos del mes conseguidas.', 'Lista en cero', 31, 'critico'),
    ('cierre', 'Cierre contable y reporte mensual a Dirección', 'Pólizas, provisiones, ajustes e indicadores.', 'Balanza y tablero', 30, 'critico')
  ) as t(clave, titulo, descr, entregable, dia, pri)
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
