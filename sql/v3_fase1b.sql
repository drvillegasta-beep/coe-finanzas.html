-- COE Finanzas v3 · Fase 1b (aditivo, no borra nada) · APLICADO en Supabase el 07/10/2026 (después de v3_fase1c)
-- Usuario+contraseña, pedidos, tareas, correos a proveedor, CFDI y tiempo real.

-- 1. Acceso con usuario y contraseña ------------------------------------
alter table public.fin_usuarios add column if not exists usuario text;
alter table public.fin_usuarios add column if not exists password_hash text;
create unique index if not exists fin_usuarios_usuario_uk on public.fin_usuarios (lower(usuario)) where usuario is not null;

create or replace function public.fin_login(p_usuario text, p_password text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u public.fin_usuarios;
begin
  select * into u from public.fin_usuarios where activo and lower(usuario) = lower(trim(p_usuario)) limit 1;
  if not found then return jsonb_build_object('ok', false, 'error', 'credenciales'); end if;
  if u.bloqueado_hasta is not null and u.bloqueado_hasta > now() then
    return jsonb_build_object('ok', false, 'error', 'bloqueado', 'hasta', u.bloqueado_hasta);
  end if;
  if u.password_hash = encode(extensions.digest(u.id::text || ':' || p_password, 'sha256'), 'hex') then
    update public.fin_usuarios set intentos_fallidos = 0, bloqueado_hasta = null where id = u.id;
    return jsonb_build_object('ok', true, 'id', u.id, 'nombre', u.nombre, 'rol', u.rol, 'usuario', u.usuario,
      'permisos', u.permisos, 'sede', u.sede, 'limite', u.limite_autoriza, 'email', u.email);
  end if;
  update public.fin_usuarios set intentos_fallidos = intentos_fallidos + 1,
    bloqueado_hasta = case when intentos_fallidos + 1 >= 5 then now() + interval '5 minutes' end where id = u.id;
  return jsonb_build_object('ok', false, 'error', 'credenciales');
end $$;

-- Primer acceso: nombre + PIN actual -> crea usuario y contraseña
create or replace function public.fin_primer_acceso(p_nombre text, p_pin text, p_usuario text, p_password text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u public.fin_usuarios;
begin
  if length(coalesce(p_password, '')) < 6 then return jsonb_build_object('ok', false, 'error', 'password_corta'); end if;
  if coalesce(trim(p_usuario), '') = '' then return jsonb_build_object('ok', false, 'error', 'usuario'); end if;
  select * into u from public.fin_usuarios
   where activo and lower(nombre) = lower(trim(p_nombre))
     and pin_hash = encode(extensions.digest(p_pin, 'sha256'), 'hex') limit 1;
  if not found then return jsonb_build_object('ok', false, 'error', 'pin'); end if;
  if exists (select 1 from public.fin_usuarios where lower(usuario) = lower(trim(p_usuario)) and id <> u.id) then
    return jsonb_build_object('ok', false, 'error', 'usuario_ocupado');
  end if;
  perform set_config('app.usuario_id', u.id::text, true);
  perform set_config('app.usuario_nombre', u.nombre, true);
  update public.fin_usuarios set usuario = lower(trim(p_usuario)),
    password_hash = encode(extensions.digest(u.id::text || ':' || p_password, 'sha256'), 'hex') where id = u.id;
  return jsonb_build_object('ok', true);
end $$;

-- 2. Pedidos / órdenes de compra ------------------------------------------
create sequence if not exists public.fin_pedidos_folio_seq;
create table if not exists public.fin_pedidos (
  id uuid primary key default gen_random_uuid(),
  folio text unique default ('OC-' || lpad(nextval('public.fin_pedidos_folio_seq')::text, 5, '0')),
  area text not null,
  sede text default 'Tacámbaro',
  entidad_id uuid references public.fin_entidades(id),
  razon_social_id uuid references public.fin_razones_sociales(id),
  descripcion text not null,
  partidas jsonb default '[]'::jsonb,
  monto_estimado numeric default 0,
  urgente boolean default false,
  fecha_requerida date,
  estado text default 'solicitado',
  solicitado_por uuid, solicitado_at timestamptz default now(),
  autorizado_por uuid, autorizado_at timestamptz,
  firma2_por uuid, firma2_at timestamptz,
  rechazo_motivo text,
  enviado_at timestamptz, recibido_at timestamptz, recibido_por uuid,
  factura_id uuid references public.fin_facturas(id),
  pedido_lio_id uuid,
  notas text,
  created_at timestamptz default now(), updated_at timestamptz default now()
);

create or replace function public.fin_pedido_crear(p_usuario uuid, p_pin text, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; v_id uuid; v_folio text;
begin
  f := public.fin__firmar_mod(p_usuario, p_pin, 'pedidos', 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_datos->>'descripcion'), '') = '' then return jsonb_build_object('ok', false, 'error', 'descripcion'); end if;
  insert into public.fin_pedidos (area, sede, entidad_id, razon_social_id, descripcion, partidas, monto_estimado,
                                  urgente, fecha_requerida, notas, solicitado_por)
  values (coalesce(nullif(p_datos->>'area',''), 'General'), coalesce(nullif(p_datos->>'sede',''), (f.u).sede, 'Tacámbaro'),
          nullif(p_datos->>'entidad_id','')::uuid,
          coalesce(nullif(p_datos->>'razon_social_id','')::uuid, (select id from public.fin_razones_sociales where activo order by created_at limit 1)),
          trim(p_datos->>'descripcion'), coalesce(p_datos->'partidas', '[]'::jsonb),
          coalesce(nullif(p_datos->>'monto_estimado','')::numeric, 0), coalesce((p_datos->>'urgente')::boolean, false),
          nullif(p_datos->>'fecha_requerida','')::date, nullif(p_datos->>'notas',''), (f.u).id)
  returning id, folio into v_id, v_folio;
  return jsonb_build_object('ok', true, 'id', v_id, 'folio', v_folio);
end $$;

-- Autorizar o rechazar. Arriba del límite (3,000) firma también el Director.
create or replace function public.fin_pedido_autorizar(p_usuario uuid, p_pin text, p_pin_director text,
  p_pedido uuid, p_decision text, p_nota text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; dd record; v_dir public.fin_usuarios; p public.fin_pedidos;
begin
  f := public.fin__firmar_mod(p_usuario, p_pin, 'pedidos', 3);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  select * into p from public.fin_pedidos where id = p_pedido for update;
  if p.id is null or p.estado <> 'solicitado' then return jsonb_build_object('ok', false, 'error', 'estado'); end if;
  if p_decision = 'rechazar' then
    if coalesce(trim(p_nota), '') = '' then return jsonb_build_object('ok', false, 'error', 'motivo'); end if;
    update public.fin_pedidos set estado = 'rechazado', rechazo_motivo = p_nota, autorizado_por = (f.u).id,
      autorizado_at = now(), updated_at = now() where id = p_pedido;
    return jsonb_build_object('ok', true);
  end if;
  if (f.u).rol = 'administracion' and (f.u).sede is not null and p.sede <> (f.u).sede then
    return jsonb_build_object('ok', false, 'error', 'sede');
  end if;
  if p.monto_estimado > public.fin__limite() and (f.u).rol <> 'admin' then
    dd := public.fin__director(p_usuario, p_pin_director);
    if dd.err is not null then return jsonb_build_object('ok', false, 'error', dd.err); end if;
    v_dir := dd.d;
  end if;
  update public.fin_pedidos set estado = 'autorizado', autorizado_por = (f.u).id, autorizado_at = now(),
    firma2_por = v_dir.id, firma2_at = case when v_dir.id is not null then now() end,
    notas = coalesce(nullif(p_nota,''), notas), updated_at = now() where id = p_pedido;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.fin_pedido_estado(p_usuario uuid, p_pin text, p_pedido uuid, p_estado text, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; p public.fin_pedidos;
begin
  f := public.fin__firmar_mod(p_usuario, p_pin, 'pedidos', 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  select * into p from public.fin_pedidos where id = p_pedido for update;
  if p.id is null then return jsonb_build_object('ok', false, 'error', 'pedido'); end if;
  if p_estado = 'enviado' and p.estado <> 'autorizado' then return jsonb_build_object('ok', false, 'error', 'no_autorizado'); end if;
  if p_estado = 'recibido' and p.estado not in ('autorizado','enviado') then return jsonb_build_object('ok', false, 'error', 'estado'); end if;
  if p_estado = 'cancelado' and coalesce(trim(p_datos->>'motivo'),'') = '' then return jsonb_build_object('ok', false, 'error', 'motivo'); end if;
  if p_estado not in ('enviado','recibido','facturado','cancelado') then return jsonb_build_object('ok', false, 'error', 'estado'); end if;
  update public.fin_pedidos set estado = p_estado,
    enviado_at = case when p_estado = 'enviado' then now() else enviado_at end,
    recibido_at = case when p_estado = 'recibido' then now() else recibido_at end,
    recibido_por = case when p_estado = 'recibido' then (f.u).id else recibido_por end,
    factura_id = coalesce(nullif(p_datos->>'factura_id','')::uuid, factura_id),
    rechazo_motivo = case when p_estado = 'cancelado' then p_datos->>'motivo' else rechazo_motivo end,
    updated_at = now() where id = p_pedido;
  return jsonb_build_object('ok', true);
end $$;

-- 3. Tareas y cumplimiento --------------------------------------------------
create table if not exists public.fin_tareas (
  id uuid primary key default gen_random_uuid(),
  clave text,
  titulo text not null,
  descripcion text,
  entregable text,
  responsable_rol text default 'contadora',
  responsable_id uuid,
  frecuencia text,
  fecha_limite date not null,
  estado text default 'pendiente',
  cumplida_por uuid, cumplida_at timestamptz,
  evidencia_url text, nota text,
  created_at timestamptz default now()
);
create unique index if not exists fin_tareas_clave_fecha_uk on public.fin_tareas (clave, fecha_limite) where clave is not null;

-- Genera las tareas fijas del cronograma de la contadora para un mes (idempotente)
create or replace function public.fin_generar_tareas(p_mes date default current_date)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare m date := date_trunc('month', p_mes)::date; ult date := (date_trunc('month', p_mes) + interval '1 month - 1 day')::date; n int;
begin
  insert into public.fin_tareas (clave, titulo, descripcion, entregable, frecuencia, fecha_limite)
  select t.clave, t.titulo, t.descr, t.entregable, 'mensual', least(m + (t.dia - 1), ult)
  from (values
    ('edo_cuenta', 'Estados de cuenta y XML al contador externo', 'Estados de cuenta bancarios del mes anterior y relación de XML emitidos y recibidos.', 'Acuse de envío', 5),
    ('conc_banc', 'Conciliación bancaria de todas las cuentas', 'Depurar partidas en tránsito.', 'Conciliación firmada', 10),
    ('flujo', 'Flujo de efectivo proyectado del mes', 'Ingresos contra egresos y necesidades de liquidez.', 'Flujo mensual', 10),
    ('inv_farm', 'Inventario de farmacia y parcial de óptica; pedido mensual de quirófano', 'Conteo con cuadre contra sistema y caducidades.', 'Acta de inventario y orden de compra', 15),
    ('plan_compras', 'Planeación de pedidos de medicamentos y óptica', 'Con base en histórico y temporada.', 'Plan de compras', 18),
    ('polizas', 'Pago de pólizas y servicios mensuales', 'Seguros, mantenimientos, suscripciones, rentas.', 'Comprobantes', 22),
    ('antiguedad', 'Antigüedad de cuentas por cobrar y por pagar', 'Revisar saldos vencidos.', 'Reporte de antigüedad', 25),
    ('fact_pend', 'Facturas por solicitar en cero', 'Todas las facturas de pagos del mes conseguidas.', 'Lista en cero', 31),
    ('cierre', 'Cierre contable y reporte mensual a Dirección', 'Pólizas, provisiones, ajustes e indicadores.', 'Balanza y tablero', 30)
  ) as t(clave, titulo, descr, entregable, dia)
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.fin_tarea_cumplir(p_usuario uuid, p_pin text, p_tarea uuid, p_evidencia text, p_nota text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record;
begin
  f := public.fin__firmar_mod(p_usuario, p_pin, 'tareas', 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(p_evidencia, '') = '' then return jsonb_build_object('ok', false, 'error', 'evidencia'); end if;
  update public.fin_tareas set estado = 'cumplida', cumplida_por = (f.u).id, cumplida_at = now(),
    evidencia_url = p_evidencia, nota = nullif(p_nota, '') where id = p_tarea and estado <> 'cumplida';
  return jsonb_build_object('ok', true);
end $$;

-- 4. Correos a proveedor (bitácora firmada) ---------------------------------
create table if not exists public.fin_correos (
  id uuid primary key default gen_random_uuid(),
  entidad_id uuid, pedido_id uuid, factura_id uuid,
  para text, asunto text, cuerpo text, motivo text,
  enviado_por uuid, enviado_at timestamptz default now()
);

create or replace function public.fin_registrar_correo(p_usuario uuid, p_pin text, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; v_id uuid;
begin
  f := public.fin__firmar(p_usuario, p_pin);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  insert into public.fin_correos (entidad_id, pedido_id, factura_id, para, asunto, cuerpo, motivo, enviado_por)
  values (nullif(p_datos->>'entidad_id','')::uuid, nullif(p_datos->>'pedido_id','')::uuid, nullif(p_datos->>'factura_id','')::uuid,
          p_datos->>'para', p_datos->>'asunto', p_datos->>'cuerpo', p_datos->>'motivo', (f.u).id)
  returning id into v_id;
  if nullif(p_datos->>'pedido_id','') is not null and p_datos->>'motivo' = 'pedido' then
    update public.fin_pedidos set estado = 'enviado', enviado_at = now(), updated_at = now()
     where id = (p_datos->>'pedido_id')::uuid and estado = 'autorizado';
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- 5. CFDI: aplicar datos leídos del XML a una cuenta --------------------------
create or replace function public.fin_aplicar_cfdi(p_usuario uuid, p_pin text, p_factura uuid, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; v_uuid text := upper(nullif(p_datos->>'uuid_cfdi',''));
begin
  f := public.fin__firmar_mod(p_usuario, p_pin, 'cxp', 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if v_uuid is not null and exists (select 1 from public.fin_facturas where upper(uuid_cfdi) = v_uuid and id <> p_factura and not coalesce(anulado,false)) then
    return jsonb_build_object('ok', false, 'error', 'uuid_duplicado');
  end if;
  update public.fin_facturas set
    uuid_cfdi = coalesce(v_uuid, uuid_cfdi),
    rfc_emisor = coalesce(nullif(p_datos->>'rfc_emisor',''), rfc_emisor),
    numero_factura = coalesce(nullif(p_datos->>'numero_factura',''), numero_factura),
    documento_tipo = case when documento_tipo = 'sin_factura' then 'factura' else coalesce(documento_tipo, 'factura') end,
    factura_pendiente = false,
    updated_by = (f.u).id, updated_at = now()
  where id = p_factura;
  return jsonb_build_object('ok', true);
end $$;

-- 6. Crear movimiento (egreso o ingreso), respetando doble firma ------------
create or replace function public.fin_crear_cxp(p_usuario uuid, p_pin text, p_pin_director text, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; dd record; v_dir public.fin_usuarios; v_id uuid;
  v_monto numeric := nullif(p_datos->>'monto_total','')::numeric;
  v_tipo text := coalesce(nullif(p_datos->>'documento_tipo',''), 'por_pagar');
  v_mov text := coalesce(nullif(p_datos->>'tipo',''), 'egreso');
  v_uuid text := upper(nullif(p_datos->>'uuid_cfdi',''));
  v_venc date := nullif(p_datos->>'fecha_vencimiento','')::date;
begin
  f := public.fin__firmar_mod(p_usuario, p_pin, case when v_mov = 'ingreso' then 'cxc' else 'cxp' end, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if v_mov not in ('egreso','ingreso') then return jsonb_build_object('ok', false, 'error', 'tipo'); end if;
  if v_monto is null or v_monto <= 0 then return jsonb_build_object('ok', false, 'error', 'monto'); end if;
  if nullif(p_datos->>'entidad_id','') is null then return jsonb_build_object('ok', false, 'error', 'proveedor'); end if;
  if coalesce(trim(p_datos->>'descripcion'), '') = '' then return jsonb_build_object('ok', false, 'error', 'descripcion'); end if;
  if v_uuid is not null and exists (select 1 from public.fin_facturas where upper(uuid_cfdi) = v_uuid and not coalesce(anulado,false)) then
    return jsonb_build_object('ok', false, 'error', 'uuid_duplicado');
  end if;
  if v_mov = 'egreso' and v_monto > public.fin__limite() and (f.u).rol <> 'admin' then
    dd := public.fin__director(p_usuario, p_pin_director);
    if dd.err is not null then return jsonb_build_object('ok', false, 'error', dd.err); end if;
    v_dir := dd.d;
  end if;
  if v_venc is null then
    select current_date + coalesce(dias_credito, 0) into v_venc from public.fin_entidades where id = (p_datos->>'entidad_id')::uuid;
  end if;
  insert into public.fin_facturas (
    tipo, tipo_movimiento, entidad_id, numero_factura, descripcion, categoria, monto_total, monto_pagado,
    fecha_vencimiento, estado, uuid_cfdi, rfc_emisor, notas, created_by, updated_by,
    razon_social_id, sede, origen, documento_tipo, factura_pendiente, factura_limite,
    factura_origen_id, es_recurrente, recurrente_id, recurrente_periodo,
    firma1_por, firma1_at, firma2_por, firma2_at, aprobado_por, aprobado_at)
  values (
    v_mov, coalesce(nullif(p_datos->>'tipo_movimiento',''), 'normal'), (p_datos->>'entidad_id')::uuid, nullif(p_datos->>'numero_factura',''),
    trim(p_datos->>'descripcion'), nullif(p_datos->>'categoria',''), v_monto, 0,
    v_venc, 'pendiente', v_uuid, nullif(p_datos->>'rfc_emisor',''), nullif(p_datos->>'notas',''), (f.u).id, (f.u).id,
    coalesce(nullif(p_datos->>'razon_social_id','')::uuid, (select id from public.fin_razones_sociales where activo order by created_at limit 1)),
    coalesce(nullif(p_datos->>'sede',''), (f.u).sede, 'Tacámbaro'), coalesce(nullif(p_datos->>'origen',''), 'manual'), v_tipo,
    v_tipo = 'sin_factura',
    case when v_tipo = 'sin_factura' then (date_trunc('month', current_date) + interval '1 month - 1 day')::date end,
    nullif(p_datos->>'factura_origen_id','')::uuid, nullif(p_datos->>'recurrente_id','') is not null,
    nullif(p_datos->>'recurrente_id','')::uuid, nullif(p_datos->>'recurrente_periodo',''),
    (f.u).id, now(), v_dir.id, case when v_dir.id is not null then now() end,
    coalesce(v_dir.nombre, case when (f.u).rol = 'admin' then (f.u).nombre end),
    case when v_dir.id is not null or (f.u).rol = 'admin' then now() end)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- 7. Bitácora en tablas nuevas y tiempo real --------------------------------
do $$
declare t text;
begin
  foreach t in array array['fin_pedidos','fin_tareas','fin_correos'] loop
    if not exists (select 1 from pg_trigger where tgname = 'trg_audit' and tgrelid = ('public.' || t)::regclass) then
      execute format('create trigger trg_audit after insert or update or delete on public.%I for each row execute function public.fin_audit()', t);
    end if;
  end loop;
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['fin_facturas','fin_abonos','fin_pedidos','fin_tareas','fin_documentos','fin_entidades','fin_recurrentes','fin_correos','con_cierres_dia'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

select public.fin_generar_tareas(current_date);
select public.fin_generar_tareas((current_date + interval '1 month')::date);
