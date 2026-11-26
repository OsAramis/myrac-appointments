-- Datos iniciales: planes y el taller MYRAC (configuración confirmada en la Fase 1).
-- Precios de planes: PROVISIONALES, pendientes de decisión.

insert into planes (id, nombre, precio_mensual) values
  ('basico', 'Citas', 0),
  ('pro',    'Citas + operación', 0)
on conflict (id) do nothing;

do $$
declare v_id uuid;
begin
  insert into talleres (nombre, slug, zona_horaria, bahias_total, intervalo_min, cupo_por_bloque, confirmacion_automatica)
  values ('MYRAC', 'myrac', 'America/Mexico_City', 7, 30, 3, true)
  on conflict (slug) do nothing
  returning id into v_id;

  if v_id is null then return; end if;  -- ya existía

  insert into horario_taller (taller_id, dia_semana, abre, cierra) values
    (v_id, 1, '09:00', '18:00'), (v_id, 2, '09:00', '18:00'), (v_id, 3, '09:00', '18:00'),
    (v_id, 4, '09:00', '18:00'), (v_id, 5, '09:00', '18:00'), (v_id, 6, '09:00', '14:00');

  perform aplicar_plantilla_servicios(v_id);

  insert into suscripciones (taller_id, plan_id, estado) values (v_id, 'pro', 'activa');
end $$;

-- Para darte acceso como dueño, después de registrarte en la app ejecuta (con tu correo):
-- insert into usuarios_taller (taller_id, auth_user_id, rol)
-- select t.id, u.id, 'dueno' from talleres t, auth.users u
-- where t.slug = 'myrac' and u.email = 'TU_CORREO@ejemplo.com';
