# MYRAC APPOINTMENTS

Plataforma web de citas para talleres automotrices: el cliente ve los horarios con espacio real y el taller administra su agenda y sus bahías. Producto de MYRAC OS, diseñado para integrarse con él más adelante.

## Stack
- **Next.js** (app web responsiva, instalable como PWA): en construcción
- **Supabase**: PostgreSQL, autenticación y tiempo real
- **Stripe**: suscripciones de los talleres (fase posterior)

## Base de datos (`supabase/`)
| Archivo | Contenido |
|---|---|
| `migrations/…_esquema.sql` | Tablas: talleres, horario, bloqueos, usuarios, clientes, vehículos, servicios, citas, estancias, planes y suscripciones |
| `migrations/…_funciones.sql` | Regla de disponibilidad, reserva pública con bloqueo contra doble reserva, cancelar/reprogramar por enlace, recibir y entregar autos, alta de talleres con plantilla de servicios |
| `migrations/…_seguridad.sql` | Row Level Security: cada taller solo ve sus datos; el público solo puede reservar |
| `seed.sql` | Planes y el taller MYRAC (7 bahías, 3 recepciones cada 30 min, L–V 9–18, S 9–14, 42 servicios) |

### Regla de disponibilidad
Un bloque de horario se ofrece si:
1. Está dentro del horario del taller y no choca con un bloqueo.
2. Las citas de ese bloque son menos que el cupo (`cupo_por_bloque`).
3. Si el servicio deja el auto: las bahías ocupadas proyectadas ese día son menos que `bahias_total`.

**Bahías ocupadas proyectadas** = autos dentro sin fecha estimada de salida, con fecha vencida o con fecha estimada ≥ ese día, más las citas de ese día que dejan el auto.

### Aplicar en Supabase
1. En el panel de Supabase, abre **SQL Editor**.
2. Ejecuta, en orden, los tres archivos de `migrations/` y después `seed.sql`.
3. Regístrate en la app y ejecuta la consulta comentada al final de `seed.sql` (con tu correo) para quedar como dueño de MYRAC.
