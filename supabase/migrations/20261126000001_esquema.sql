-- MYRAC APPOINTMENTS — Esquema base
-- Multi-taller: toda tabla de negocio lleva taller_id.
-- Nombres alineados con MYRAC OS (talleres, clientes, vehiculos, servicios) para la integración futura.

create type rol_taller as enum ('dueno', 'recepcion', 'mecanico');
create type tipo_servicio as enum ('espera', 'deja_auto');
create type estado_cita as enum ('pendiente', 'confirmada', 'recibida', 'cancelada', 'no_asistio');
create type origen_cita as enum ('web', 'taller');
create type estado_estancia as enum ('diagnostico', 'esperando_refacciones', 'en_reparacion', 'listo', 'entregado');
create type estado_suscripcion as enum ('prueba', 'activa', 'vencida', 'cancelada');

-- Talleres ------------------------------------------------------------------
create table talleres (
  id                       uuid primary key default gen_random_uuid(),
  nombre                   text not null,
  slug                     text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  telefono                 text,
  direccion                text,
  zona_horaria             text not null default 'America/Mexico_City',
  -- Configuración del negocio (editable por el taller)
  bahias_total             int  not null default 5  check (bahias_total between 1 and 200),
  intervalo_min            int  not null default 30 check (intervalo_min in (15, 20, 30, 45, 60, 90, 120)),
  cupo_por_bloque          int  not null default 1  check (cupo_por_bloque between 1 and 50),
  dias_anticipacion_max    int  not null default 30 check (dias_anticipacion_max between 1 and 180),
  confirmacion_automatica  boolean not null default true,
  creado_en                timestamptz not null default now()
);

create table horario_taller (
  taller_id   uuid not null references talleres(id) on delete cascade,
  dia_semana  smallint not null check (dia_semana between 1 and 7), -- 1 = lunes ... 7 = domingo (ISO)
  abre        time not null,
  cierra      time not null,
  primary key (taller_id, dia_semana),
  check (cierra > abre)
);

create table bloqueos (
  id         uuid primary key default gen_random_uuid(),
  taller_id  uuid not null references talleres(id) on delete cascade,
  inicio     timestamptz not null,
  fin        timestamptz not null,
  motivo     text,
  check (fin > inicio)
);
create index on bloqueos (taller_id, inicio);

create table usuarios_taller (
  taller_id     uuid not null references talleres(id) on delete cascade,
  auth_user_id  uuid not null references auth.users(id) on delete cascade,
  rol           rol_taller not null default 'recepcion',
  nombre        text,
  primary key (taller_id, auth_user_id)
);
create index on usuarios_taller (auth_user_id);

-- Clientes y vehículos -------------------------------------------------------
create table clientes (
  id         uuid primary key default gen_random_uuid(),
  taller_id  uuid not null references talleres(id) on delete cascade,
  nombre     text not null,
  telefono   text not null,           -- solo dígitos, 10 en México
  email      text,
  creado_en  timestamptz not null default now(),
  unique (taller_id, telefono)
);

create table vehiculos (
  id          uuid primary key default gen_random_uuid(),
  taller_id   uuid not null references talleres(id) on delete cascade,
  cliente_id  uuid not null references clientes(id) on delete cascade,
  marca       text not null,
  modelo      text not null,
  anio        smallint check (anio between 1950 and 2100),
  placas      text,
  vin         text,
  creado_en   timestamptz not null default now()
);
create index on vehiculos (cliente_id);

-- Catálogo de servicios ------------------------------------------------------
create table categorias_servicio (
  id         uuid primary key default gen_random_uuid(),
  taller_id  uuid not null references talleres(id) on delete cascade,
  nombre     text not null,
  orden      int not null default 0,
  unique (taller_id, nombre)
);

create table servicios (
  id            uuid primary key default gen_random_uuid(),
  taller_id     uuid not null references talleres(id) on delete cascade,
  categoria_id  uuid references categorias_servicio(id) on delete set null,
  nombre        text not null,
  tipo          tipo_servicio not null default 'deja_auto',
  activo        boolean not null default true,
  orden         int not null default 0
);
create index on servicios (taller_id, activo);

-- Citas y estancias ----------------------------------------------------------
create table citas (
  id             uuid primary key default gen_random_uuid(),
  taller_id      uuid not null references talleres(id) on delete cascade,
  cliente_id     uuid not null references clientes(id) on delete restrict,
  vehiculo_id    uuid not null references vehiculos(id) on delete restrict,
  servicio_id    uuid not null references servicios(id) on delete restrict,
  inicio         timestamptz not null,
  estado         estado_cita not null default 'pendiente',
  origen         origen_cita not null default 'web',
  notas          text,
  token_cliente  uuid not null unique default gen_random_uuid(), -- enlace para cancelar/reprogramar
  creado_en      timestamptz not null default now()
);
create index on citas (taller_id, inicio);

-- Estancia = el auto dentro del taller ocupando una bahía.
-- En la integración con MYRAC OS equivale a una orden de trabajo.
create table estancias (
  id               uuid primary key default gen_random_uuid(),
  taller_id        uuid not null references talleres(id) on delete cascade,
  cita_id          uuid unique references citas(id) on delete set null,
  vehiculo_id      uuid not null references vehiculos(id) on delete restrict,
  bahia            int check (bahia >= 1),
  ingreso          timestamptz not null default now(),
  salida_estimada  date,          -- null = desconocida → cuenta como ocupada
  salida_real      timestamptz,
  estado           estado_estancia not null default 'diagnostico',
  notas            text
);
create index on estancias (taller_id) where salida_real is null;
-- Una bahía no puede tener dos autos al mismo tiempo
create unique index estancias_bahia_unica on estancias (taller_id, bahia) where salida_real is null and bahia is not null;

-- Suscripciones (Stripe se conecta en una fase posterior) --------------------
create table planes (
  id              text primary key,         -- 'basico', 'pro', ...
  nombre          text not null,
  precio_mensual  numeric(10,2) not null,
  moneda          text not null default 'MXN',
  stripe_price_id text,
  activo          boolean not null default true
);

create table suscripciones (
  taller_id               uuid primary key references talleres(id) on delete cascade,
  plan_id                 text references planes(id),
  estado                  estado_suscripcion not null default 'prueba',
  vence_en                timestamptz,
  stripe_customer_id      text,
  stripe_subscription_id  text
);
