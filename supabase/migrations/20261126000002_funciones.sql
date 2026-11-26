-- MYRAC APPOINTMENTS — Lógica de negocio
-- Regla de disponibilidad (Fase 1, decisiones D2, D4, D6):
--   Un bloque se ofrece si:
--   1) está dentro del horario y no choca con un bloqueo,
--   2) las citas activas en ese bloque < cupo_por_bloque,
--   3) si el servicio deja el auto: bahías ocupadas proyectadas ese día < bahias_total.
--   Bahías ocupadas proyectadas(fecha) =
--     autos dentro (sin salida real) cuya salida estimada es desconocida, ya vencida o >= fecha
--     + citas activas de servicios "deja_auto" para esa fecha (aún no recibidas).

-- Utilidades -----------------------------------------------------------------
create or replace function solo_digitos(p text) returns text
language sql immutable as $$ select regexp_replace(coalesce(p, ''), '\D', '', 'g') $$;

create or replace function hoy_taller(p_taller talleres) returns date
language sql stable as $$ select (now() at time zone p_taller.zona_horaria)::date $$;

-- Membresía (usada por RLS) ---------------------------------------------------
create or replace function es_miembro(p_taller uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from usuarios_taller
                 where taller_id = p_taller and auth_user_id = auth.uid());
$$;

create or replace function es_dueno(p_taller uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from usuarios_taller
                 where taller_id = p_taller and auth_user_id = auth.uid() and rol = 'dueno');
$$;

-- Bahías ocupadas proyectadas para una fecha -----------------------------------
create or replace function bahias_ocupadas(p_taller_id uuid, p_fecha date) returns int
language sql stable security definer set search_path = public as $$
  with t as (select * from talleres where id = p_taller_id)
  select
    (select count(*) from estancias e, t
      where e.taller_id = t.id and e.salida_real is null
        and (e.salida_estimada is null
             or e.salida_estimada < hoy_taller(t)      -- vencida: la estimación falló, se considera ocupada
             or e.salida_estimada >= p_fecha))::int
  + (select count(*) from citas c join servicios s on s.id = c.servicio_id, t
      where c.taller_id = t.id
        and c.estado in ('pendiente', 'confirmada')
        and s.tipo = 'deja_auto'
        and (c.inicio at time zone t.zona_horaria)::date = p_fecha)::int;
$$;

-- Horarios disponibles (página pública) ----------------------------------------
create or replace function horarios_disponibles(
  p_slug text, p_servicio_id uuid, p_desde date, p_hasta date
) returns table (inicio timestamptz, cupos_libres int)
language plpgsql stable security definer set search_path = public as $$
declare
  t talleres;
  s servicios;
  v_desde date;
  v_hasta date;
begin
  select * into t from talleres where slug = p_slug;
  if not found then return; end if;

  select * into s from servicios where id = p_servicio_id and taller_id = t.id and activo;
  if not found then return; end if;

  -- Taller sin suscripción vigente no recibe citas en línea
  if not exists (select 1 from suscripciones su where su.taller_id = t.id
                 and su.estado in ('prueba', 'activa')
                 and (su.vence_en is null or su.vence_en > now())) then
    return;
  end if;

  v_desde := greatest(p_desde, hoy_taller(t));
  v_hasta := least(p_hasta, hoy_taller(t) + t.dias_anticipacion_max);

  return query
  with dias as (
    select d::date as fecha from generate_series(v_desde, v_hasta, interval '1 day') d
  ),
  bloques as (
    select dias.fecha,
           ((dias.fecha + h.abre + make_interval(mins => n * t.intervalo_min)) at time zone t.zona_horaria) as b_inicio
    from dias
    join horario_taller h on h.taller_id = t.id and h.dia_semana = extract(isodow from dias.fecha)
    cross join lateral generate_series(
      0, (extract(epoch from (h.cierra - h.abre)) / 60 / t.intervalo_min)::int - 1
    ) as n
  ),
  ocupacion_dia as (
    select fecha, bahias_ocupadas(t.id, fecha) as ocupadas
    from (select distinct fecha from bloques) f
  )
  select b.b_inicio,
         (t.cupo_por_bloque - (
            select count(*) from citas c
            where c.taller_id = t.id
              and c.estado in ('pendiente', 'confirmada', 'recibida')
              and c.inicio >= b.b_inicio
              and c.inicio <  b.b_inicio + make_interval(mins => t.intervalo_min)
         ))::int as libres
  from bloques b
  join ocupacion_dia o on o.fecha = b.fecha
  where b.b_inicio > now()
    and not exists (
      select 1 from bloqueos bl
      where bl.taller_id = t.id
        and bl.inicio < b.b_inicio + make_interval(mins => t.intervalo_min)
        and bl.fin    > b.b_inicio)
    and (s.tipo = 'espera' or o.ocupadas < t.bahias_total)
    and (t.cupo_por_bloque - (
            select count(*) from citas c
            where c.taller_id = t.id
              and c.estado in ('pendiente', 'confirmada', 'recibida')
              and c.inicio >= b.b_inicio
              and c.inicio <  b.b_inicio + make_interval(mins => t.intervalo_min))) > 0
  order by b.b_inicio;
end;
$$;

-- Reserva pública ------------------------------------------------------------
-- Bloqueo por taller para que dos clientes no tomen el último lugar al mismo tiempo.
create or replace function crear_cita_publica(
  p_slug text, p_servicio_id uuid, p_inicio timestamptz,
  p_nombre text, p_telefono text, p_email text,
  p_marca text, p_modelo text, p_anio int, p_placas text,
  p_notas text default null
) returns table (cita_id uuid, token uuid, estado estado_cita)
language plpgsql volatile security definer set search_path = public as $$
declare
  t talleres;
  v_tel text := solo_digitos(p_telefono);
  v_placas text := nullif(upper(regexp_replace(coalesce(p_placas, ''), '[^A-Za-z0-9]', '', 'g')), '');
  v_cliente uuid;
  v_vehiculo uuid;
  v_cita citas;
begin
  select * into t from talleres where slug = p_slug;
  if not found then raise exception 'TALLER_NO_ENCONTRADO'; end if;

  if length(v_tel) <> 10 then raise exception 'TELEFONO_INVALIDO'; end if;
  if coalesce(trim(p_nombre), '') = '' or coalesce(trim(p_marca), '') = '' or coalesce(trim(p_modelo), '') = '' then
    raise exception 'DATOS_INCOMPLETOS';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(t.id::text, 0));

  if not exists (
    select 1 from horarios_disponibles(p_slug, p_servicio_id,
                    (p_inicio at time zone t.zona_horaria)::date,
                    (p_inicio at time zone t.zona_horaria)::date) h
    where h.inicio = p_inicio
  ) then
    raise exception 'HORARIO_NO_DISPONIBLE';
  end if;

  insert into clientes (taller_id, nombre, telefono, email)
  values (t.id, trim(p_nombre), v_tel, nullif(trim(p_email), ''))
  on conflict (taller_id, telefono) do update
    set nombre = excluded.nombre,
        email  = coalesce(excluded.email, clientes.email)
  returning id into v_cliente;

  select v.id into v_vehiculo from vehiculos v
  where v.cliente_id = v_cliente
    and ((v_placas is not null and v.placas = v_placas)
      or (v_placas is null and lower(v.marca) = lower(trim(p_marca))
          and lower(v.modelo) = lower(trim(p_modelo)) and v.anio is not distinct from p_anio::smallint))
  limit 1;

  if v_vehiculo is null then
    insert into vehiculos (taller_id, cliente_id, marca, modelo, anio, placas)
    values (t.id, v_cliente, trim(p_marca), trim(p_modelo), p_anio, v_placas)
    returning id into v_vehiculo;
  end if;

  insert into citas (taller_id, cliente_id, vehiculo_id, servicio_id, inicio, estado, origen, notas)
  values (t.id, v_cliente, v_vehiculo, p_servicio_id, p_inicio,
          case when t.confirmacion_automatica then 'confirmada'::estado_cita else 'pendiente'::estado_cita end,
          'web', nullif(trim(p_notas), ''))
  returning * into v_cita;

  return query select v_cita.id, v_cita.token_cliente, v_cita.estado;
end;
$$;

-- Consulta de la cita por el cliente (enlace con token) -----------------------
create or replace function cita_por_token(p_token uuid)
returns table (
  cita_id uuid, inicio timestamptz, estado estado_cita,
  taller_nombre text, taller_slug text, taller_telefono text, taller_direccion text, zona_horaria text,
  servicio_id uuid, servicio_nombre text, vehiculo text, cliente_nombre text
)
language sql stable security definer set search_path = public as $$
  select c.id, c.inicio, c.estado,
         t.nombre, t.slug, t.telefono, t.direccion, t.zona_horaria,
         s.id, s.nombre,
         concat_ws(' ', v.marca, v.modelo, v.anio::text, nullif('· ' || v.placas, '· ')),
         cl.nombre
  from citas c
  join talleres t   on t.id = c.taller_id
  join servicios s  on s.id = c.servicio_id
  join vehiculos v  on v.id = c.vehiculo_id
  join clientes cl  on cl.id = c.cliente_id
  where c.token_cliente = p_token;
$$;

create or replace function cancelar_cita_publica(p_token uuid) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  update citas set estado = 'cancelada'
  where token_cliente = p_token and estado in ('pendiente', 'confirmada') and inicio > now();
  if not found then raise exception 'CITA_NO_CANCELABLE'; end if;
end;
$$;

create or replace function reprogramar_cita_publica(p_token uuid, p_nuevo_inicio timestamptz) returns void
language plpgsql volatile security definer set search_path = public as $$
declare
  c citas;
  t talleres;
begin
  select * into c from citas where token_cliente = p_token;
  if not found or c.estado not in ('pendiente', 'confirmada') or c.inicio <= now() then
    raise exception 'CITA_NO_REPROGRAMABLE';
  end if;
  select * into t from talleres where id = c.taller_id;

  perform pg_advisory_xact_lock(hashtextextended(t.id::text, 0));

  -- Se libera su lugar actual mientras se valida el nuevo; si falla, todo se revierte.
  update citas set estado = 'cancelada' where id = c.id;

  if not exists (
    select 1 from horarios_disponibles(t.slug, c.servicio_id,
                    (p_nuevo_inicio at time zone t.zona_horaria)::date,
                    (p_nuevo_inicio at time zone t.zona_horaria)::date) h
    where h.inicio = p_nuevo_inicio
  ) then
    raise exception 'HORARIO_NO_DISPONIBLE';
  end if;

  update citas set inicio = p_nuevo_inicio, estado = c.estado where id = c.id;
end;
$$;

-- Operación del taller ---------------------------------------------------------
-- Recibir el auto: la cita pasa a "recibida" y se abre la estancia en una bahía.
create or replace function recibir_cita(p_cita_id uuid, p_bahia int, p_salida_estimada date default null)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare
  c citas;
  t talleres;
  v_estancia uuid;
begin
  select * into c from citas where id = p_cita_id;
  if not found or not es_miembro(c.taller_id) then raise exception 'SIN_PERMISO'; end if;
  if c.estado not in ('pendiente', 'confirmada') then raise exception 'CITA_NO_RECIBIBLE'; end if;
  select * into t from talleres where id = c.taller_id;
  if p_bahia is not null and (p_bahia < 1 or p_bahia > t.bahias_total) then raise exception 'BAHIA_INVALIDA'; end if;

  update citas set estado = 'recibida' where id = c.id;
  insert into estancias (taller_id, cita_id, vehiculo_id, bahia, salida_estimada)
  values (c.taller_id, c.id, c.vehiculo_id, p_bahia, p_salida_estimada)
  returning id into v_estancia;
  return v_estancia;
end;
$$;

-- Entregar el auto: libera la bahía.
create or replace function entregar_auto(p_estancia_id uuid) returns void
language plpgsql volatile security definer set search_path = public as $$
declare e estancias;
begin
  select * into e from estancias where id = p_estancia_id;
  if not found or not es_miembro(e.taller_id) then raise exception 'SIN_PERMISO'; end if;
  update estancias set estado = 'entregado', salida_real = now() where id = e.id and salida_real is null;
end;
$$;

-- Alta de talleres (onboarding SaaS) ------------------------------------------
create or replace function aplicar_plantilla_servicios(p_taller_id uuid) returns void
language plpgsql volatile security definer set search_path = public as $$
declare
  cat record;
  v_cat uuid;
  i int;
begin
  for cat in
    select * from (values
      (1,  'Mantenimiento', array['Cambio de aceite y filtro','Afinación','Servicio mayor','Servicio por kilometraje','Cambio de filtros de aire y cabina','Revisión de niveles','Revisión antes de viaje']),
      (2,  'Frenos', array['Cambio de balatas','Rectificado de discos o tambores','Servicio completo de frenos','Cambio de líquido de frenos']),
      (3,  'Suspensión y dirección', array['Diagnóstico de suspensión','Amortiguadores','Rótulas, terminales y bujes','Dirección hidráulica o eléctrica','Alineación y balanceo']),
      (4,  'Motor', array['Diagnóstico de motor','Banda o cadena de distribución','Fugas y juntas','Empaque de cabeza','Ajuste de motor']),
      (5,  'Transmisión', array['Servicio de transmisión mecatrónica (DSG / doble embrague)','Reparación de transmisión mecatrónica','Clutch']),
      (6,  'Enfriamiento', array['Servicio de anticongelante','Radiador, termostato o bomba de agua','Ventiladores']),
      (7,  'Eléctrico y electrónico', array['Diagnóstico con escáner','Batería','Alternador o marcha','Fallas eléctricas','Programación de llaves o módulos','Focos y luces']),
      (8,  'Inyección y combustible', array['Limpieza de inyectores','Limpieza de cuerpo de aceleración','Bomba de gasolina']),
      (9,  'Escape', array['Reparación de escape o catalizador']),
      (10, 'Multimedia y accesorios', array['Instalación de estéreo, CarPlay o Android Auto','Cámaras y sensores']),
      (11, 'Otros', array['Revisión antes de comprar un auto','Revisión para verificación','Llantas'])
    ) as x(orden, nombre, servicios)
  loop
    insert into categorias_servicio (taller_id, nombre, orden)
    values (p_taller_id, cat.nombre, cat.orden)
    on conflict (taller_id, nombre) do update set orden = excluded.orden
    returning id into v_cat;

    for i in 1 .. array_length(cat.servicios, 1) loop
      insert into servicios (taller_id, categoria_id, nombre, tipo, orden)
      select p_taller_id, v_cat, cat.servicios[i], 'deja_auto', i
      where not exists (select 1 from servicios where taller_id = p_taller_id and nombre = cat.servicios[i]);
    end loop;
  end loop;
end;
$$;

-- Un usuario autenticado crea su taller y queda como dueño.
create or replace function crear_taller(p_nombre text, p_slug text) returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'SIN_SESION'; end if;

  insert into talleres (nombre, slug) values (trim(p_nombre), lower(trim(p_slug))) returning id into v_id;
  insert into usuarios_taller (taller_id, auth_user_id, rol) values (v_id, auth.uid(), 'dueno');

  insert into horario_taller (taller_id, dia_semana, abre, cierra)
  select v_id, d, '09:00', case when d = 6 then '14:00'::time else '18:00'::time end
  from generate_series(1, 6) d;

  perform aplicar_plantilla_servicios(v_id);

  insert into suscripciones (taller_id, estado, vence_en) values (v_id, 'prueba', now() + interval '30 days');
  return v_id;
end;
$$;

revoke execute on function aplicar_plantilla_servicios(uuid) from public;
