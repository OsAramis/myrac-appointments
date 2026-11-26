-- MYRAC APPOINTMENTS — Seguridad (Row Level Security)
-- Público (anon): solo lee datos de vitrina del taller y usa las funciones de reserva.
-- Personal del taller: ve y opera únicamente los datos de SU taller.
-- Dueño: además edita la configuración del negocio y el catálogo.

alter table talleres            enable row level security;
alter table horario_taller      enable row level security;
alter table bloqueos            enable row level security;
alter table usuarios_taller     enable row level security;
alter table clientes            enable row level security;
alter table vehiculos           enable row level security;
alter table categorias_servicio enable row level security;
alter table servicios           enable row level security;
alter table citas               enable row level security;
alter table estancias           enable row level security;
alter table planes              enable row level security;
alter table suscripciones       enable row level security;

-- Vitrina pública
create policy talleres_lectura_publica   on talleres            for select using (true);
create policy horario_lectura_publica    on horario_taller      for select using (true);
create policy categorias_lectura_publica on categorias_servicio for select using (true);
create policy servicios_lectura_publica  on servicios           for select using (activo or es_miembro(taller_id));
create policy planes_lectura_publica     on planes              for select using (activo);

-- Configuración del negocio: solo el dueño
create policy talleres_dueno_edita on talleres for update
  using (es_dueno(id)) with check (es_dueno(id));
create policy horario_dueno on horario_taller for all
  using (es_dueno(taller_id)) with check (es_dueno(taller_id));
create policy categorias_dueno on categorias_servicio for all
  using (es_dueno(taller_id)) with check (es_dueno(taller_id));
create policy servicios_dueno on servicios for all
  using (es_dueno(taller_id)) with check (es_dueno(taller_id));

-- Equipo del taller
create policy usuarios_ver_equipo on usuarios_taller for select using (es_miembro(taller_id));
create policy usuarios_dueno_gestiona on usuarios_taller for all
  using (es_dueno(taller_id)) with check (es_dueno(taller_id));

-- Operación diaria: cualquier miembro del taller
create policy bloqueos_miembros  on bloqueos  for all using (es_miembro(taller_id)) with check (es_miembro(taller_id));
create policy clientes_miembros  on clientes  for all using (es_miembro(taller_id)) with check (es_miembro(taller_id));
create policy vehiculos_miembros on vehiculos for all using (es_miembro(taller_id)) with check (es_miembro(taller_id));
create policy citas_miembros     on citas     for all using (es_miembro(taller_id)) with check (es_miembro(taller_id));
create policy estancias_miembros on estancias for all using (es_miembro(taller_id)) with check (es_miembro(taller_id));

-- Suscripción: el taller la ve; solo el servidor (webhook de Stripe con service_role) la modifica
create policy suscripcion_miembros_ven on suscripciones for select using (es_miembro(taller_id));

-- Permisos de funciones
revoke execute on function horarios_disponibles(text, uuid, date, date) from public;
revoke execute on function crear_cita_publica(text, uuid, timestamptz, text, text, text, text, text, int, text, text) from public;
revoke execute on function cita_por_token(uuid) from public;
revoke execute on function cancelar_cita_publica(uuid) from public;
revoke execute on function reprogramar_cita_publica(uuid, timestamptz) from public;
revoke execute on function recibir_cita(uuid, int, date) from public;
revoke execute on function entregar_auto(uuid) from public;
revoke execute on function crear_taller(text, text) from public;
revoke execute on function bahias_ocupadas(uuid, date) from public;

grant execute on function horarios_disponibles(text, uuid, date, date) to anon, authenticated;
grant execute on function crear_cita_publica(text, uuid, timestamptz, text, text, text, text, text, int, text, text) to anon, authenticated;
grant execute on function cita_por_token(uuid) to anon, authenticated;
grant execute on function cancelar_cita_publica(uuid) to anon, authenticated;
grant execute on function reprogramar_cita_publica(uuid, timestamptz) to anon, authenticated;
grant execute on function recibir_cita(uuid, int, date) to authenticated;
grant execute on function entregar_auto(uuid) to authenticated;
grant execute on function crear_taller(text, text) to authenticated;
grant execute on function bahias_ocupadas(uuid, date) to authenticated;

-- Tiempo real: la agenda y el tablero de bahías se actualizan solos (solo existe en Supabase)
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table citas, estancias;
  end if;
end $$;
