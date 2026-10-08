-- COE Finanzas v3 · Fase 1c: permisos por perfil y propuesta de pagos (aditivo) · APLICADO en Supabase el 07/10/2026
-- Niveles: 0 sin acceso · 1 ver · 2 operar · 3 autorizar. permisos jsonb del usuario sobrescribe el default del rol.

alter table public.fin_facturas add column if not exists propuesta_pago date;
alter table public.fin_facturas add column if not exists propuesta_por uuid;
alter table public.fin_facturas add column if not exists propuesta_at timestamptz;

create or replace function public.fin__nivel(u public.fin_usuarios, p_mod text)
returns integer language sql stable as $$
  select coalesce(
    nullif(u.permisos->>p_mod, '')::int,
    case u.rol
      when 'admin' then 3
      when 'direccion' then case p_mod when 'pedidos' then 3 when 'revision' then 2 when 'config' then 0 else 1 end
      when 'contadora' then case p_mod when 'pagos' then 1 when 'ingreso' then 1 when 'reportes' then 1 when 'auditoria' then 1
                                       when 'config' then 0 when 'tablero' then 1 else 2 end
      when 'administracion' then case p_mod when 'pedidos' then 3 when 'cxp' then 2 when 'fps' then 2 when 'proveedores' then 1
                                       when 'auditoria' then 0 when 'config' then 0 when 'pagos' then 0 else 1 end
      when 'solicitante' then case p_mod when 'pedidos' then 2 when 'tablero' then 1 else 0 end
      else 1 end)
$$;

-- Firma con PIN + verificación de permiso del módulo
create or replace function public.fin__firmar_mod(p_usuario uuid, p_pin text, p_mod text, p_nivel int, OUT u public.fin_usuarios, OUT err text)
returns record language plpgsql security definer set search_path to 'public' as $$
declare f record;
begin
  f := public.fin__firmar(p_usuario, p_pin);
  if f.err is not null then err := f.err; return; end if;
  u := f.u;
  if public.fin__nivel(u, p_mod) < p_nivel then err := 'sin_permiso'; end if;
end $$;

-- Propuesta de pagos: la contadora prepara, el Director paga
create or replace function public.fin_proponer_pago(p_usuario uuid, p_pin text, p_facturas uuid[], p_fecha date)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record;
begin
  f := public.fin__firmar_mod(p_usuario, p_pin, 'cxp', 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  update public.fin_facturas set propuesta_pago = p_fecha,
    propuesta_por = case when p_fecha is null then null else (f.u).id end,
    propuesta_at = case when p_fecha is null then null else now() end,
    updated_by = (f.u).id, updated_at = now()
  where id = any(p_facturas) and tipo = 'egreso' and estado <> 'pagado';
  return jsonb_build_object('ok', true);
end $$;

-- Permisos en las operaciones existentes ----------------------------------
create or replace function public.fin_revisar(p_usuario uuid, p_pin text, p_factura uuid, p_estado text, p_nota text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record;
begin
  f := public.fin__firmar_mod(p_usuario, p_pin, 'revision', 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if p_estado not in ('revisado','observado','pendiente') then return jsonb_build_object('ok', false, 'error', 'estado'); end if;
  if p_estado = 'observado' and coalesce(trim(p_nota), '') = '' then return jsonb_build_object('ok', false, 'error', 'nota'); end if;
  update public.fin_facturas set revision = p_estado, revision_por = (f.u).id, revision_at = now(),
         revision_nota = nullif(p_nota, '') where id = p_factura;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.fin_guardar_proveedor(p_usuario uuid, p_pin text, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; v_id uuid := nullif(p_datos->>'id','')::uuid;
begin
  -- Alta automática desde una factura: basta con poder operar cuentas por pagar
  f := public.fin__firmar_mod(p_usuario, p_pin, case when v_id is null and coalesce((p_datos->>'desde_cfdi')::boolean,false) then 'cxp' else 'proveedores' end, 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(trim(p_datos->>'nombre'), '') = '' then return jsonb_build_object('ok', false, 'error', 'nombre'); end if;
  if v_id is null then
    insert into public.fin_entidades (nombre, tipo, categoria, rfc, dias_credito, clabe, banco, convenio_cie, email, telefono, activo)
    values (trim(p_datos->>'nombre'), 'proveedor', nullif(p_datos->>'categoria',''), upper(nullif(trim(p_datos->>'rfc'),'')),
            coalesce(nullif(p_datos->>'dias_credito','')::int, 0), nullif(p_datos->>'clabe',''), nullif(p_datos->>'banco',''),
            nullif(p_datos->>'convenio_cie',''), nullif(p_datos->>'email',''), nullif(p_datos->>'telefono',''), true)
    returning id into v_id;
  else
    update public.fin_entidades set nombre = trim(p_datos->>'nombre'), categoria = nullif(p_datos->>'categoria',''),
           rfc = upper(nullif(trim(p_datos->>'rfc'),'')), dias_credito = coalesce(nullif(p_datos->>'dias_credito','')::int, 0),
           clabe = nullif(p_datos->>'clabe',''), banco = nullif(p_datos->>'banco',''), convenio_cie = nullif(p_datos->>'convenio_cie',''),
           email = nullif(p_datos->>'email',''), telefono = nullif(p_datos->>'telefono','')
     where id = v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.fin_adjuntar(p_usuario uuid, p_pin text, p_tabla text, p_registro uuid, p_tipo text, p_url text, p_sha256 text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; v_id uuid; v_mod text;
begin
  select case when tipo = 'ingreso' then 'cxc' else 'cxp' end into v_mod from public.fin_facturas where id = p_registro;
  f := public.fin__firmar_mod(p_usuario, p_pin, coalesce(v_mod, 'cxp'), 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if p_tabla not in ('fin_facturas','fin_abonos') then return jsonb_build_object('ok', false, 'error', 'tabla'); end if;
  insert into public.fin_documentos (tabla, registro_id, tipo, url, sha256, subido_por)
  values (p_tabla, p_registro, p_tipo, p_url, p_sha256, (f.u).id) returning id into v_id;
  if p_tabla = 'fin_facturas' and p_tipo = 'xml' then
    update public.fin_facturas set xml_url = p_url, updated_by = (f.u).id, updated_at = now() where id = p_registro;
  elsif p_tabla = 'fin_facturas' and p_tipo = 'pdf' then
    update public.fin_facturas set pdf_url = p_url, factura_pendiente = false, updated_by = (f.u).id, updated_at = now() where id = p_registro;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Guardar permisos de un usuario (solo Dirección General)
create or replace function public.fin_guardar_usuario(p_usuario uuid, p_pin text, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f record; v_id uuid := nullif(p_datos->>'id','')::uuid;
begin
  f := public.fin__firmar(p_usuario, p_pin);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if (f.u).rol <> 'admin' then return jsonb_build_object('ok', false, 'error', 'solo_director'); end if;
  if coalesce(trim(p_datos->>'nombre'), '') = '' then return jsonb_build_object('ok', false, 'error', 'nombre'); end if;
  if v_id is null then
    if coalesce(p_datos->>'pin','') !~ '^\d{4}$' then return jsonb_build_object('ok', false, 'error', 'pin_nuevo'); end if;
    insert into public.fin_usuarios (nombre, rol, sede, email, permisos, activo, pin_hash)
    values (trim(p_datos->>'nombre'), p_datos->>'rol', nullif(p_datos->>'sede',''), nullif(p_datos->>'email',''),
            coalesce(p_datos->'permisos', '{}'::jsonb), true, encode(extensions.digest(p_datos->>'pin', 'sha256'), 'hex'))
    returning id into v_id;
  else
    update public.fin_usuarios set nombre = trim(p_datos->>'nombre'), rol = p_datos->>'rol', sede = nullif(p_datos->>'sede',''),
      email = nullif(p_datos->>'email',''), permisos = coalesce(p_datos->'permisos', '{}'::jsonb),
      activo = coalesce((p_datos->>'activo')::boolean, true),
      pin_hash = case when coalesce(p_datos->>'pin','') ~ '^\d{4}$' then encode(extensions.digest(p_datos->>'pin', 'sha256'), 'hex') else pin_hash end,
      password_hash = case when coalesce((p_datos->>'reset_password')::boolean, false) then null else password_hash end,
      usuario = case when coalesce((p_datos->>'reset_password')::boolean, false) then null else usuario end
    where id = v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
