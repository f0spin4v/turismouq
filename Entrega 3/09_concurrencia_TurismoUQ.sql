-- TurismoUQ - Bases de Datos II (2026-2), grupo 01N
-- Equipo: Andrés Ospina Vera, Juan Esteban Cuervo Jimenez
-- Script 9: concurrencia con dos sesiones - Entrega 3
-- Se corre con la conexión TurismoUQ, completo con F5. Prepara el
-- experimento; los pasos de cada sesión están en 09a_sesion_A.sql y
-- 09b_sesion_B.sql.
--
-- El experimento: dos personas de recepción intentan reservar la MISMA
-- habitación para las MISMAS noches al mismo tiempo.
--
--   Antes  (sin FOR UPDATE): cada sesión revisa la disponibilidad, ve la
--          habitación libre y la reserva. Las dos quedan guardadas: la
--          habitación queda vendida dos veces.
--          Ni siquiera el disparador de solapes lo evita, porque cada sesión
--          no ve lo que la otra todavía no ha confirmado con COMMIT.
--
--   Después (con SELECT ... FOR UPDATE): la primera sesión bloquea la fila
--          de la habitación. La segunda se queda esperando en el FOR UPDATE
--          hasta que la primera hace COMMIT; cuando sigue, ya ve la reserva
--          de la primera y la rechaza con -20002.
--
-- Cómo abrir dos sesiones en SQL Developer: con la conexión TurismoUQ
-- abierta, Herramientas > Hoja de trabajo no compartida (Ctrl+Shift+N) dos
-- veces. Cada hoja no compartida es una sesión distinta de Oracle.
-- Abrir 09a_sesion_A.sql en una y 09b_sesion_B.sql en la otra.

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF


-- =====================================================================
-- 1. Habitaciones del experimento
-- =====================================================================
-- Se guardan en una tabla para que las dos sesiones usen exactamente la
-- misma habitación y las mismas fechas. Una habitación para el "antes" y
-- otra para el "después", las dos libres del 8 al 10 de diciembre de 2026.
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE conc_prueba PURGE';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -942 THEN RAISE; END IF;
END;
/

CREATE TABLE conc_prueba (
  experimento    VARCHAR2(7)  NOT NULL,
  id_habitacion  NUMBER(8)    NOT NULL,
  fecha_in       DATE         NOT NULL,
  fecha_out      DATE         NOT NULL,
  CONSTRAINT pk_conc_prueba PRIMARY KEY (experimento),
  CONSTRAINT ck_conc_exp    CHECK (experimento IN ('ANTES', 'DESPUES'))
);

INSERT INTO conc_prueba (experimento, id_habitacion, fecha_in, fecha_out)
SELECT CASE fila WHEN 1 THEN 'ANTES' ELSE 'DESPUES' END,
       id_habitacion, DATE '2026-12-08', DATE '2026-12-10'
FROM  (SELECT h.id_habitacion, ROW_NUMBER() OVER (ORDER BY h.id_habitacion) AS fila
       FROM   habitacion h
       WHERE  h.capacidad >= 2
       AND NOT EXISTS (SELECT 1
                       FROM   reserva_habitacion l
                       JOIN   reserva r ON r.id_reserva = l.id_reserva
                       WHERE  l.id_habitacion = h.id_habitacion
                       AND    r.estado <> 'CANCELADA'
                       AND    l.fecha_checkin  < DATE '2026-12-10'
                       AND    l.fecha_checkout > DATE '2026-12-08'))
WHERE  fila <= 2;

COMMIT;

SELECT * FROM conc_prueba ORDER BY experimento;


-- =====================================================================
-- 2. Versión SIN bloqueo (el "antes")
-- =====================================================================
-- Hace lo mismo que sp_crear_reserva pero sin FOR UPDATE: revisa si la
-- habitación está libre, espera p_pausa segundos (para que dé tiempo de
-- correr la otra sesión, como pasaría con dos personas reales) y guarda.
-- No hace COMMIT: eso lo hace cada sesión a mano.
CREATE OR REPLACE PROCEDURE sp_reservar_sin_bloqueo (
  p_id_cliente  IN NUMBER,
  p_pausa       IN NUMBER DEFAULT 0
)
IS
  v_hab      NUMBER;
  v_in       DATE;
  v_out      DATE;
  v_aloj     NUMBER;
  v_choques  PLS_INTEGER;
  v_res      NUMBER;
BEGIN
  SELECT id_habitacion, fecha_in, fecha_out INTO v_hab, v_in, v_out
  FROM   conc_prueba WHERE experimento = 'ANTES';

  SELECT id_alojamiento INTO v_aloj FROM habitacion WHERE id_habitacion = v_hab;
  DBMS_OUTPUT.PUT_LINE(TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || ' Revisando la habitación ' || v_hab);

  -- Revisión de disponibilidad SIN bloquear nada
  SELECT COUNT(*) INTO v_choques
  FROM   reserva_habitacion l
  JOIN   reserva r ON r.id_reserva = l.id_reserva
  WHERE  l.id_habitacion = v_hab
  AND    r.estado IN ('CONFIRMADA', 'COMPLETADA')
  AND    l.fecha_checkin  < v_out
  AND    l.fecha_checkout > v_in;

  IF v_choques > 0 THEN
    RAISE_APPLICATION_ERROR(-20002, 'La habitación ' || v_hab || ' no está disponible');
  END IF;
  DBMS_OUTPUT.PUT_LINE(TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || ' Está libre');

  DBMS_SESSION.SLEEP(p_pausa);

  INSERT INTO reserva (id_cliente, id_alojamiento, fecha_reserva, fecha_checkin, fecha_checkout, estado)
  VALUES (p_id_cliente, v_aloj, SYSDATE, v_in, v_out, 'CONFIRMADA')
  RETURNING id_reserva INTO v_res;

  INSERT INTO reserva_habitacion (id_reserva, id_alojamiento, id_habitacion,
                                  fecha_checkin, fecha_checkout, num_huespedes, valor_estadia)
  VALUES (v_res, v_aloj, v_hab, v_in, v_out, 2, pkg_turismouq.fn_valor_estadia(v_hab, v_in, v_out));

  DBMS_OUTPUT.PUT_LINE(TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || ' Reserva ' || v_res ||
                       ' guardada (falta COMMIT)');
END sp_reservar_sin_bloqueo;
/

SHOW ERRORS PROCEDURE sp_reservar_sin_bloqueo


-- =====================================================================
-- 3. Versión CON bloqueo (el "después")
-- =====================================================================
-- Igual, pero lo primero que hace es SELECT ... FOR UPDATE sobre la fila de
-- la habitación. Si otra sesión ya la tiene bloqueada, esta se queda
-- esperando ahí hasta que la otra termine su transacción (COMMIT o
-- ROLLBACK). Es el mismo bloqueo que usa pkg_turismouq.sp_crear_reserva.
CREATE OR REPLACE PROCEDURE sp_reservar_con_bloqueo (
  p_id_cliente  IN NUMBER,
  p_pausa       IN NUMBER DEFAULT 0
)
IS
  v_hab      NUMBER;
  v_in       DATE;
  v_out      DATE;
  v_aloj     NUMBER;
  v_choques  PLS_INTEGER;
  v_res      NUMBER;
BEGIN
  SELECT id_habitacion, fecha_in, fecha_out INTO v_hab, v_in, v_out
  FROM   conc_prueba WHERE experimento = 'DESPUES';

  DBMS_OUTPUT.PUT_LINE(TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || ' Pidiendo el bloqueo de la habitación ' || v_hab);

  -- El bloqueo: solo una sesión a la vez pasa de aquí con esta habitación
  SELECT id_alojamiento INTO v_aloj
  FROM   habitacion
  WHERE  id_habitacion = v_hab
  FOR UPDATE;

  DBMS_OUTPUT.PUT_LINE(TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || ' Bloqueo obtenido');

  SELECT COUNT(*) INTO v_choques
  FROM   reserva_habitacion l
  JOIN   reserva r ON r.id_reserva = l.id_reserva
  WHERE  l.id_habitacion = v_hab
  AND    r.estado IN ('CONFIRMADA', 'COMPLETADA')
  AND    l.fecha_checkin  < v_out
  AND    l.fecha_checkout > v_in;

  IF v_choques > 0 THEN
    RAISE_APPLICATION_ERROR(-20002, 'La habitación ' || v_hab || ' no está disponible del ' ||
                            TO_CHAR(v_in, 'DD/MM/YYYY') || ' al ' || TO_CHAR(v_out, 'DD/MM/YYYY'));
  END IF;
  DBMS_OUTPUT.PUT_LINE(TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || ' Está libre');

  DBMS_SESSION.SLEEP(p_pausa);

  INSERT INTO reserva (id_cliente, id_alojamiento, fecha_reserva, fecha_checkin, fecha_checkout, estado)
  VALUES (p_id_cliente, v_aloj, SYSDATE, v_in, v_out, 'CONFIRMADA')
  RETURNING id_reserva INTO v_res;

  INSERT INTO reserva_habitacion (id_reserva, id_alojamiento, id_habitacion,
                                  fecha_checkin, fecha_checkout, num_huespedes, valor_estadia)
  VALUES (v_res, v_aloj, v_hab, v_in, v_out, 2, pkg_turismouq.fn_valor_estadia(v_hab, v_in, v_out));

  DBMS_OUTPUT.PUT_LINE(TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || ' Reserva ' || v_res ||
                       ' guardada (falta COMMIT)');
END sp_reservar_con_bloqueo;
/

SHOW ERRORS PROCEDURE sp_reservar_con_bloqueo


-- =====================================================================
-- 4. Resultado del experimento (correr DESPUÉS de las dos sesiones)
-- =====================================================================
-- Antes: deben salir DOS reservas confirmadas de la misma habitación y
-- las mismas noches (la habitación vendida dos veces).
-- Después: debe salir UNA sola.
SELECT c.experimento, l.id_habitacion, r.id_reserva, r.id_cliente,
       CASE r.id_cliente WHEN 5 THEN 'Sesión A' WHEN 6 THEN 'Sesión B' END AS sesion,
       r.estado, l.fecha_checkin, l.fecha_checkout,
       TO_CHAR(r.fecha_reserva, 'HH24:MI:SS') AS hora
FROM   conc_prueba c
JOIN   reserva_habitacion l ON l.id_habitacion = c.id_habitacion
                           AND l.fecha_checkin  < c.fecha_out
                           AND l.fecha_checkout > c.fecha_in
JOIN   reserva r ON r.id_reserva = l.id_reserva
WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
ORDER BY c.experimento, r.id_reserva;


-- =====================================================================
-- 5. Para ver el bloqueo mientras pasa (opcional, con XE_SYSTEM)
-- =====================================================================
-- Mientras la sesión B está esperando, correr esto en la conexión
-- XE_SYSTEM: BLOCKING_SESSION dice qué sesión la tiene bloqueada y EVENT
-- dice "enq: TX - row lock contention".
--
--   SELECT sid, serial#, username, status, blocking_session, event,
--          seconds_in_wait
--   FROM   v$session
--   WHERE  username = 'TURISMOUQ'
--   ORDER BY sid


-- =====================================================================
-- 6. Limpieza (correr al final, cuando ya se tomaron las capturas)
-- =====================================================================
-- Borra las reservas del experimento (clientes 5 y 6, hechas después de la
-- fecha de corte de la carga). Se deja comentado para no borrar las
-- evidencias por accidente.
--
-- BEGIN
--   FOR r IN (SELECT id_reserva FROM reserva
--             WHERE  fecha_reserva >= DATE '2026-09-30'
--             AND    id_cliente IN (5, 6)) LOOP
--     DELETE FROM reserva_habitacion WHERE id_reserva = r.id_reserva;
--     DELETE FROM reserva            WHERE id_reserva = r.id_reserva;
--   END LOOP;
--   COMMIT;
-- END;
-- /
