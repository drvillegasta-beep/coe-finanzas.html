-- APLICADO 15/10/2026 (por partes)
-- COE Finanzas v3 · Facturas por solicitar automáticas
-- Regla: toda cuenta por pagar con pago (total o parcial) y sin XML de factura
-- entra a "Facturas por solicitar", salvo proveedores marcados "no factura".
-- Sale sola en cuanto se sube el XML (xml_url o uuid_cfdi).

-- 1) Completa xml_url desde documentos XML ya adjuntos
update public.fin_facturas f set xml_url = d.url
from (select distinct on (registro_id) registro_id, url from public.fin_documentos
      where tabla = 'fin_facturas' and tipo = 'xml' order by registro_id, subido_at desc) d
where d.registro_id = f.id and f.xml_url is null;

-- 2) Regla permanente
create or replace function public.fin__fps_regla() returns trigger language plpgsql security definer set search_path = public as $$
declare v_nf boolean;
begin
  if coalesce(new.origen,'') = 'nomina' then return new; end if;  -- COE Nómina maneja su propia regla
  if new.tipo = 'egreso' and coalesce(new.estado,'') <> 'cancelado' and coalesce(new.monto_pagado,0) > 0.009
     and new.xml_url is null and new.uuid_cfdi is null then
    select coalesce(no_factura,false) into v_nf from public.fin_entidades where id = new.entidad_id;
    if coalesce(v_nf,false) then
      new.factura_pendiente := false;
    else
      new.factura_pendiente := true;
      if new.factura_limite is null then
        new.factura_limite := (date_trunc('month', coalesce(new.fecha_pago, current_date)) + interval '1 month - 1 day')::date;
      end if;
    end if;
  elsif new.tipo = 'egreso' and (new.xml_url is not null or new.uuid_cfdi is not null
        or coalesce(new.monto_pagado,0) <= 0.009 or new.estado = 'cancelado') then
    new.factura_pendiente := false;
  end if;
  return new;
end $$;
drop trigger if exists trg_fps_regla on public.fin_facturas;
create trigger trg_fps_regla before insert or update on public.fin_facturas
  for each row execute function public.fin__fps_regla();

-- 3) Rezago: límite al fin del mes en curso
update public.fin_facturas f
set factura_limite = coalesce(f.factura_limite, (date_trunc('month', current_date) + interval '1 month - 1 day')::date),
    factura_pendiente = true
where f.tipo = 'egreso' and coalesce(f.origen,'') <> 'nomina' and coalesce(f.estado,'') <> 'cancelado' and coalesce(f.monto_pagado,0) > 0.009
  and f.xml_url is null and f.uuid_cfdi is null
  and not exists (select 1 from public.fin_entidades e where e.id = f.entidad_id and coalesce(e.no_factura,false));

-- 4) Evidencia obligatoria para cumplir un pendiente
create or replace function public.fin_tarea_cumplir(p_usuario uuid, p_pin text, p_tarea uuid, p_evidencia text, p_nota text)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare f record; t public.fin_tareas;
begin
  f := public.fin__firmar_mod(p_usuario, p_pin, 'tareas', 2);
  if f.err is not null then return jsonb_build_object('ok', false, 'error', f.err); end if;
  if coalesce(p_evidencia, '') = '' then return jsonb_build_object('ok', false, 'error', 'evidencia'); end if;
  select * into t from public.fin_tareas where id = p_tarea for update;
  if t.id is null or t.estado in ('cumplida','cancelada') then return jsonb_build_object('ok', false, 'error', 'cerrada'); end if;
  update public.fin_tareas set estado = 'cumplida', cumplida_por = (f.u).id, cumplida_at = now(),
    evidencia_url = p_evidencia, nota = nullif(p_nota, ''), fecha_limite_original = coalesce(fecha_limite_original, fecha_limite),
    ultimo_avance = coalesce(nullif(p_nota, ''), 'Cumplida'), ultimo_avance_at = now(), updated_at = now() where id = p_tarea;
  insert into public.fin_tareas_avances (tarea_id, usuario_id, tipo, estado_ant, estado_nuevo, nota, evidencia_url)
  values (p_tarea, p_usuario, 'cumplida', t.estado, 'cumplida', nullif(p_nota, ''), p_evidencia);
  return jsonb_build_object('ok', true);
end $function$;

-- 5) Nómina: baja de Dora, honorarios ligados a su proveedor, entidad NÓMINA COE, exclusiones en Finanzas
-- update nom_empleados set activo=false, fecha_baja='2026-10-15', motivo_baja='Indicación de Dirección General' where id='8244502c-3b27-411a-b274-316031465a95';
-- update nom_empleados e set entidad_id=f.id from fin_entidades f where f.notas like 'nom:'||e.id||'%' and e.entidad_id is null;
-- update fin_entidades set nombre='NÓMINA COE' where id='7dd6fae7-5c4d-47c7-b48e-90b86d95119c';
-- insert into fin_config (clave,valor) values ('nomina_excluir','<ilse>,<dora>');
