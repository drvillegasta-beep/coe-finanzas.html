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

-- 6) (16/10/2026) Honorarios: pendiente crítico automático para la Contadora por prestador y mes
--    Título «Solicitar facturas de nómina · <prestador> · <mes>»; se crea al registrar la primera transferencia; límite = día 30 del mes (o último día si el mes es más corto);
--    se cierra solo cuando las 2 transferencias del mes tienen XML. Ver funciones en la base:
--    public.fin__honorarios_tarea() + trigger trg_honorarios_tarea (after insert/update en fin_facturas)
--    y public.fin__fps_regla() (límite de factura de honorarios = fin del mes de la quincena).
-- 7) (16/10/2026) Índice único fin_facturas_recurrente_periodo_uq (recurrente_id, recurrente_periodo) para evitar dobles registros por doble clic.

-- 8) (17/10/2026) Recurrentes administrados solo por Dirección General
alter table public.fin_recurrentes add column if not exists monto numeric(14,2), add column if not exists fecha_inicio date,
  add column if not exists fecha_fin date, add column if not exists prioridad text,
  add column if not exists eliminado_at timestamptz, add column if not exists eliminado_por uuid;
-- public.fin_guardar_recurrente(p_usuario, p_pin, p_id, p_datos jsonb, p_accion 'guardar'|'eliminar'):
--   solo rol admin; crea la empresa si es nueva; "eliminar" la quita de la lista y del calendario (activo=false, eliminado_at) conservando pagos hechos.

-- 9) (17/10/2026) Informes recurrentes con firma de conformidad
alter table public.fin_tareas add column if not exists requiere_conformidad boolean not null default false,
  add column if not exists conformidad_por uuid, add column if not exists conformidad_at timestamptz, add column if not exists conformidad_nota text,
  add column if not exists periodo_ini date, add column if not exists periodo_fin date, add column if not exists plantilla text;
-- public.fin_generar_informes(p_hasta): genera (sin duplicar) los informes de la Contadora:
--   semanal (lun-sáb, entrega lunes siguiente), quincenal (1-15 entrega el 17; 16-fin entrega el 2),
--   mensual (mes anterior, entrega el 5, crítico), trimestral (trimestre anterior, entrega el 10, crítico).
-- public.fin_tarea_conformidad(p_usuario, p_pin, p_tarea, p_conforme, p_nota): solo admin/direccion/administracion,
--   nunca quien lo entregó; "no conforme" exige motivo y regresa el informe a En proceso.
-- pg_cron 'fin_generar_pendientes_0600' (12:00 UTC): fin_generar_informes() + fin_generar_tareas(current_date + 35).

-- 10) (17/10/2026) Avisos push a computadora y teléfono (Web Push)
--  Tablas fin_push_subs (dispositivos por usuario) y fin_push_log; RPC fin_push_suscribir (con PIN), fin_push_estado, fin_push_quitar, fin_push_probar (con PIN).
--  Llaves VAPID y llave de la función en el vault (fin_vapid_public, fin_vapid_private, fin_avisos_key); fin__avisos_config solo para service_role.
--  fin__avisos_digest(momento): por usuario con dispositivo activo arma vencidos, hoy, críticos, informes, facturas por pedir,
--    pagos que vencen hoy; a Dirección/Administración: informes por firmar y ESCALADO de críticos del equipo con más de 2 días de atraso.
--  Edge Function fin-avisos (verify_jwt=false; valida x-coe-key) envía con web-push y desactiva suscripciones caducadas.
--  pg_cron: fin_avisos_0900 (15:00 UTC), fin_avisos_1300 (19:00 UTC), fin_avisos_1730 (23:30 UTC), lunes a sábado.
-- 11) (17/10/2026) Activar/quitar avisos en un equipo se autoriza con el PIN del Director General (fin_config 'director_general_id'),
--     aunque la sesión abierta sea de otra persona: fin_push_suscribir(p_usuario destino, p_pin del Director, ...) y fin_push_quitar(p_usuario, p_pin, p_endpoint).
--     La versión anterior fin_push_quitar(p_usuario, p_endpoint) quedó inhabilitada (responde director_requerido).
-- 12) (19/10/2026) Panorama COE para el tablero del Director
--   public.fin_panorama(p_usuario default null, p_pin default null): security definer, solo rol admin/direccion.
--   Identifica al usuario por la sesión segura (app_metadata.apps contiene 'fin' → app_user_id) o, si no hay, con usuario + PIN.
--   Devuelve métricas agregadas (sin datos de pacientes) de: Conciliación (con_turnos, con_cierres_dia, con_alertas),
--   Quirófano (qx_cotizaciones, qx_cirugias, qx_materiales/qx_lotes, qx_lio_unidades, qx_escalamientos),
--   Óptica (opt_trabajos, opt_pagos, opt_examenes) y Nómina (nom_empleados, nom_nominas, nom_asistencias, nom_incidencias).
-- 13) (20/10/2026) Pedidos de COE Farmacia → COE Finanzas
--   Causa: COE Farmacia guardaba sus pedidos solo en far_pedidos; Finanzas solo lee fin_pedidos, así que nunca llegaban.
--   fin_pedidos: columnas far_pedido_id (bigint) y origen.
--   trg_far_pedido_a_finanzas (after insert en far_pedidos) → crea el pedido en fin_pedidos (área Farmacia, partidas desde detalle, urgente si prioridad Urgente/Crítico).
--   trg_pedido_estado_a_farmacia (fin_pedidos.estado) → refleja el avance en far_pedidos.estado (0 Enviado, 1 Autorizado, 2 Pedido al proveedor, 3 Recibido) o anota rechazo/cancelación.
--   trg_far_pedido_recibido (far_pedidos.estado ≥ 3) → marca el pedido recibido en Finanzas.
--   Se migró PF-0001 → OC-00001. COE Quirófano ya inserta directo en fin_pedidos (área Quirófano); se verificó que el alta funciona.
-- 14) (20/10/2026) Almacén e inventarios desde Finanzas (escribe en las tablas de COE Farmacia)
--   far_productos: tipo_insumo (medicamento/insumo/material_quirurgico/equipo), unidad, marca, proveedor_id, registro_sanitario, controlado, red_fria, ubicacion_fisica.
--   far_lotes: serie, proveedor_id, fecha_entrada, garantia_hasta, notas.
--   fin_alm_entrada(p_usuario, p_pin, p_items, p_modo 'sumar'|'fijar', p_motivo): entrada de mercancía o inventario físico del almacén; da de alta productos nuevos.
--   fin_alm_traspaso(p_usuario, p_pin, p_items): almacén → farmacia mostrador (primero lo que caduca antes; no traspasa caducados); surte solicitudes de la farmacia.
