-- TurismoUQ - Bases de Datos II (2026-2), grupo 01N
-- Equipo: Andrés Ospina Vera, Juan Esteban Cuervo Jimenez
-- Script 11: roles, usuarios, perfil, vistas y GRANT - Entrega 3
-- Se corre con la conexión XE_SYSTEM (usuario SYSTEM, contenedor XEPDB1),
-- completo con F5, DESPUÉS de los scripts 00 a 10.
-- Las pruebas de cada usuario están en 12_pruebas_seguridad.sql.
--
-- Cuatro roles con privilegios distintos:
--
--   ROL_RECEPCION       atiende al cliente: busca habitaciones libres,
--                       registra clientes y hace reservas con su pago.
--                       NUNCA toca las tablas: solo vistas y el
--                       procedimiento sp_reservar_y_pagar.
--   ROL_ADMIN_ALOJ      administra su oferta: habitaciones, tarifas y
--                       servicios. Ve las reservas, pero no las cambia.
--   ROL_GERENTE         solo lectura de todo el negocio, la vista de
--                       ocupación y las liquidaciones; puede correr la
--                       liquidación mensual.
--   ROL_AUDITOR         solo lectura de la auditoría de tarifas, los pagos,
--                       las reservas y el histórico. No cambia nada.
--
-- Un perfil PERFIL_TURISMOUQ con límites de sesión para los cuatro usuarios.

SET SERVEROUTPUT ON
SET DEFINE OFF

-- 0. Confirmar el contenedor y el usuario
SELECT SYS_CONTEXT('USERENV', 'CON_NAME') AS contenedor, USER AS usuario FROM dual;


-- =====================================================================
-- 1. Limpieza (el script se puede correr varias veces)
-- =====================================================================
DECLARE
  PROCEDURE borrar(p_sql VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
  EXCEPTION
    WHEN OTHERS THEN NULL;   -- si no existe, se sigue
  END;
BEGIN
  borrar('DROP USER u_recepcion CASCADE');
  borrar('DROP USER u_admin_aloj CASCADE');
  borrar('DROP USER u_gerente CASCADE');
  borrar('DROP USER u_auditor CASCADE');
  borrar('DROP ROLE rol_recepcion');
  borrar('DROP ROLE rol_admin_aloj');
  borrar('DROP ROLE rol_gerente');
  borrar('DROP ROLE rol_auditor');
  borrar('DROP PROFILE perfil_turismouq CASCADE');
END;
/


-- =====================================================================
-- 2. Perfil con límites de sesión
-- =====================================================================
--   SESSIONS_PER_USER      2   máximo dos sesiones abiertas a la vez por usuario
--   IDLE_TIME              15  minutos sin hacer nada y se cierra la sesión
--   CONNECT_TIME           480 minutos (un turno de 8 horas) por sesión
--   FAILED_LOGIN_ATTEMPTS  3   al tercer intento con clave mala se bloquea
--   PASSWORD_LOCK_TIME     1/24 la cuenta queda bloqueada una hora
--   PASSWORD_LIFE_TIME     90  días para cambiar la clave
CREATE PROFILE perfil_turismouq LIMIT
  SESSIONS_PER_USER      2
  IDLE_TIME              15
  CONNECT_TIME           480
  FAILED_LOGIN_ATTEMPTS  3
  PASSWORD_LOCK_TIME     1/24
  PASSWORD_LIFE_TIME     90;

-- Los límites de sesión (SESSIONS_PER_USER, IDLE_TIME, CONNECT_TIME) solo
-- se aplican si RESOURCE_LIMIT está en TRUE (en Oracle 21c ya viene así)
SELECT name, value FROM v$parameter WHERE name = 'resource_limit';


-- =====================================================================
-- 3. Vistas para recepción (en el esquema TURISMOUQ)
-- =====================================================================
-- Recepción ve solo lo que necesita para atender: nada de valores pagados,
-- tarifas internas ni datos de otros usuarios.

-- Habitaciones con su alojamiento y municipio
CREATE OR REPLACE VIEW turismouq.v_rec_habitaciones AS
SELECT h.id_habitacion, a.id_alojamiento, a.nombre_comercial AS alojamiento,
       m.nombre AS municipio, h.numero, h.tipo_habitacion, h.capacidad
FROM   turismouq.habitacion  h
JOIN   turismouq.alojamiento a ON a.id_alojamiento = h.id_alojamiento
JOIN   turismouq.municipio   m ON m.id_municipio   = a.id_municipio;

-- Noches ocupadas por habitación (para saber qué está libre), sin datos
-- del cliente
CREATE OR REPLACE VIEW turismouq.v_rec_ocupacion AS
SELECT l.id_habitacion, l.fecha_checkin, l.fecha_checkout, r.estado
FROM   turismouq.reserva_habitacion l
JOIN   turismouq.reserva r ON r.id_reserva = l.id_reserva
WHERE  r.estado IN ('PENDIENTE', 'CONFIRMADA');

-- Clientes: recepción los consulta y registra los nuevos. Es una vista
-- sobre una sola tabla, así que acepta INSERT (fecha_registro y el id se
-- llenan solos).
CREATE OR REPLACE VIEW turismouq.v_rec_clientes AS
SELECT id_cliente, tipo_documento, num_documento, nombres, apellidos,
       correo, telefono, ciudad_origen
FROM   turismouq.cliente;

-- Reservas vigentes con el nombre del cliente y del alojamiento
CREATE OR REPLACE VIEW turismouq.v_rec_reservas AS
SELECT r.id_reserva, r.id_cliente, c.nombres || ' ' || c.apellidos AS cliente,
       a.nombre_comercial AS alojamiento, r.fecha_checkin, r.fecha_checkout, r.estado
FROM   turismouq.reserva     r
JOIN   turismouq.cliente     c ON c.id_cliente     = r.id_cliente
JOIN   turismouq.alojamiento a ON a.id_alojamiento = r.id_alojamiento
WHERE  r.estado IN ('PENDIENTE', 'CONFIRMADA');


-- =====================================================================
-- 4. Roles y privilegios
-- =====================================================================
CREATE ROLE rol_recepcion;
CREATE ROLE rol_admin_aloj;
CREATE ROLE rol_gerente;
CREATE ROLE rol_auditor;

-- Todos pueden conectarse
GRANT CREATE SESSION TO rol_recepcion, rol_admin_aloj, rol_gerente, rol_auditor;

-- 4.1 Recepción: SOLO vistas y el procedimiento de reserva + pago.
-- Ningún GRANT sobre tablas.
GRANT SELECT         ON turismouq.v_rec_habitaciones TO rol_recepcion;
GRANT SELECT         ON turismouq.v_rec_ocupacion    TO rol_recepcion;
GRANT SELECT, INSERT ON turismouq.v_rec_clientes     TO rol_recepcion;
GRANT SELECT         ON turismouq.v_rec_reservas     TO rol_recepcion;
-- El procedimiento corre con los permisos de su dueño (TURISMOUQ), así que
-- recepción puede reservar y pagar sin tener permiso sobre las tablas.
GRANT EXECUTE        ON turismouq.sp_reservar_y_pagar TO rol_recepcion;

-- 4.2 Administrador de alojamiento: su oferta (habitaciones, tarifas,
-- servicios) y consulta de reservas. No borra nada.
GRANT SELECT, INSERT, UPDATE ON turismouq.habitacion  TO rol_admin_aloj;
GRANT SELECT, INSERT, UPDATE ON turismouq.servicio    TO rol_admin_aloj;
GRANT SELECT                 ON turismouq.tarifa      TO rol_admin_aloj;
GRANT UPDATE (valor_noche)   ON turismouq.tarifa      TO rol_admin_aloj;
GRANT SELECT ON turismouq.alojamiento        TO rol_admin_aloj;
GRANT SELECT ON turismouq.temporada          TO rol_admin_aloj;
GRANT SELECT ON turismouq.reserva            TO rol_admin_aloj;
GRANT SELECT ON turismouq.reserva_habitacion TO rol_admin_aloj;
GRANT SELECT ON turismouq.reserva_servicio   TO rol_admin_aloj;
GRANT SELECT ON turismouq.resena             TO rol_admin_aloj;

-- 4.3 Gerente: lectura de todo el negocio y la liquidación mensual
BEGIN
  FOR t IN (SELECT table_name FROM dba_tables
            WHERE  owner = 'TURISMOUQ'
            AND    table_name IN ('MUNICIPIO', 'TIPO_ALOJAMIENTO', 'ALOJAMIENTO', 'HABITACION',
                                  'TEMPORADA', 'PERIODO_TEMPORADA', 'CALENDARIO', 'TARIFA',
                                  'CLIENTE', 'RESERVA', 'RESERVA_HABITACION', 'PAGO',
                                  'SERVICIO', 'RESERVA_SERVICIO', 'RESENA',
                                  'LIQUIDACION_MENSUAL', 'RESERVA_HISTORICO')) LOOP
    EXECUTE IMMEDIATE 'GRANT SELECT ON turismouq.' || t.table_name || ' TO rol_gerente';
  END LOOP;
END;
/
GRANT SELECT  ON turismouq.mv_ocupacion_mensual TO rol_gerente;
GRANT EXECUTE ON turismouq.pkg_turismouq        TO rol_gerente;

-- 4.4 Auditor: solo lectura de lo que se revisa en una auditoría
GRANT SELECT ON turismouq.auditoria_tarifa   TO rol_auditor;
GRANT SELECT ON turismouq.pago               TO rol_auditor;
GRANT SELECT ON turismouq.reserva            TO rol_auditor;
GRANT SELECT ON turismouq.reserva_historico  TO rol_auditor;
GRANT SELECT ON turismouq.usuario_sistema    TO rol_auditor;
GRANT SELECT ON turismouq.tarifa             TO rol_auditor;


-- =====================================================================
-- 5. Usuarios de prueba, uno por rol, todos con el perfil
-- =====================================================================
CREATE USER u_recepcion IDENTIFIED BY "Recepcion2026" PROFILE perfil_turismouq;
CREATE USER u_admin_aloj IDENTIFIED BY "AdminAloj2026" PROFILE perfil_turismouq;
CREATE USER u_gerente   IDENTIFIED BY "Gerente2026"   PROFILE perfil_turismouq;
CREATE USER u_auditor   IDENTIFIED BY "Auditor2026"   PROFILE perfil_turismouq;

GRANT rol_recepcion  TO u_recepcion;
GRANT rol_admin_aloj TO u_admin_aloj;
GRANT rol_gerente    TO u_gerente;
GRANT rol_auditor    TO u_auditor;


-- =====================================================================
-- 6. Revisión
-- =====================================================================
-- Privilegios sobre objetos de cada rol
SELECT grantee AS rol, table_name AS objeto, privilege AS privilegio
FROM   dba_tab_privs
WHERE  grantee IN ('ROL_RECEPCION', 'ROL_ADMIN_ALOJ', 'ROL_GERENTE', 'ROL_AUDITOR')
ORDER BY grantee, table_name, privilege;

-- UPDATE por columna del administrador (solo valor_noche de TARIFA)
SELECT grantee AS rol, table_name, column_name, privilege
FROM   dba_col_privs
WHERE  grantee = 'ROL_ADMIN_ALOJ';

-- Recepción no tiene ningún privilegio sobre tablas: debe salir 0
SELECT COUNT(*) AS tablas_de_recepcion
FROM   dba_tab_privs p
JOIN   dba_tables    t ON t.owner = p.owner AND t.table_name = p.table_name
WHERE  p.grantee = 'ROL_RECEPCION';

-- Usuarios con su rol y su perfil
SELECT u.username, r.granted_role, u.profile, u.account_status
FROM   dba_users u
JOIN   dba_role_privs r ON r.grantee = u.username
WHERE  u.username IN ('U_RECEPCION', 'U_ADMIN_ALOJ', 'U_GERENTE', 'U_AUDITOR')
ORDER BY u.username;

-- Límites del perfil
SELECT resource_name, limit
FROM   dba_profiles
WHERE  profile = 'PERFIL_TURISMOUQ'
AND    resource_name IN ('SESSIONS_PER_USER', 'IDLE_TIME', 'CONNECT_TIME',
                         'FAILED_LOGIN_ATTEMPTS', 'PASSWORD_LOCK_TIME', 'PASSWORD_LIFE_TIME')
ORDER BY resource_name;
