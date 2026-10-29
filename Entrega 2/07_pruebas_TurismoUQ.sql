-- TurismoUQ - Bases de Datos II (2026-2), grupo 01N
-- Equipo: Andrés Ospina Vera, Juan Esteban Cuervo Jimenez
-- Script 7: pruebas de la Entrega 2 (evidencia)
-- Orden de ejecución: scripts 01 a 03 de la Entrega 1, luego 04, 05, 06 y 07
-- Se corre con la conexión TurismoUQ, completo con F5.
--
-- Prueba cada componente con casos que deben funcionar y casos que deben
-- fallar. Las pruebas 1 a 5 cambian datos (reservas, tarifas, liquidación)
-- y al final se deshacen con ROLLBACK, así el script se puede correr las
-- veces que haga falta sin ensuciar la base. La salida de este script es la
-- evidencia que se entrega.

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200
SET PAGESIZE 100

COLUMN categoria        FORMAT A9
COLUMN nombre_comercial FORMAT A32
COLUMN municipio        FORMAT A12
COLUMN usuario_bd       FORMAT A12
COLUMN usuario_so       FORMAT A14
COLUMN equipo           FORMAT A16

VARIABLE b_hab NUMBER
VARIABLE b_res NUMBER


-- =====================================================================
-- PRUEBA 1: fn_valor_estadia
-- =====================================================================

-- 1.1 Estadía del 12 al 17 de diciembre de 2026 en la primera habitación.
-- Las noches del 12, 13 y 14 son temporada MEDIA (pre-temporada de
-- diciembre) y las del 15 y 16 son ALTA (fin de año). La noche del 17 no se
-- cobra porque es el checkout. Primero se ve el detalle noche por noche:
SELECT c.fecha, te.categoria, te.anio AS anio_temporada, t.valor_noche
FROM   calendario c
JOIN   temporada te ON te.id_temporada = c.id_temporada
JOIN   tarifa t     ON t.id_temporada  = c.id_temporada
                   AND t.id_habitacion = (SELECT MIN(id_habitacion) FROM habitacion)
WHERE  c.fecha >= DATE '2026-12-12'
AND    c.fecha <  DATE '2026-12-17'
ORDER BY c.fecha;

-- La función debe dar lo mismo que la suma de las cinco noches
SELECT pkg_turismouq.fn_valor_estadia((SELECT MIN(id_habitacion) FROM habitacion),
                                      DATE '2026-12-12', DATE '2026-12-17') AS valor_funcion,
       (SELECT SUM(t.valor_noche)
        FROM   calendario c
        JOIN   tarifa t ON t.id_temporada  = c.id_temporada
                       AND t.id_habitacion = (SELECT MIN(id_habitacion) FROM habitacion)
        WHERE  c.fecha >= DATE '2026-12-12'
        AND    c.fecha <  DATE '2026-12-17') AS suma_noche_por_noche
FROM   dual;

-- 1.2 Estadía que cruza de año y de temporada: del 10 al 14 de enero de 2026.
-- El 10 y el 11 son ALTA 2025 (fin de año 2025-2026); el 12 y el 13 son
-- MEDIA 2026 (post-temporada de enero).
SELECT c.fecha, te.categoria, te.anio AS anio_temporada, t.valor_noche
FROM   calendario c
JOIN   temporada te ON te.id_temporada = c.id_temporada
JOIN   tarifa t     ON t.id_temporada  = c.id_temporada
                   AND t.id_habitacion = (SELECT MIN(id_habitacion) FROM habitacion)
WHERE  c.fecha >= DATE '2026-01-10'
AND    c.fecha <  DATE '2026-01-14'
ORDER BY c.fecha;

SELECT pkg_turismouq.fn_valor_estadia((SELECT MIN(id_habitacion) FROM habitacion),
                                      DATE '2026-01-10', DATE '2026-01-14') AS valor_funcion
FROM   dual;

-- 1.3 La función debe dar el mismo valor que quedó guardado en las líneas de
-- reserva de la carga (2.000 líneas de muestra). DIFERENTES debe ser 0.
SELECT COUNT(*) AS lineas_revisadas,
       SUM(CASE WHEN l.valor_estadia =
                     pkg_turismouq.fn_valor_estadia(l.id_habitacion, l.fecha_checkin, l.fecha_checkout)
                THEN 1 ELSE 0 END) AS iguales,
       SUM(CASE WHEN l.valor_estadia <>
                     pkg_turismouq.fn_valor_estadia(l.id_habitacion, l.fecha_checkin, l.fecha_checkout)
                THEN 1 ELSE 0 END) AS diferentes
FROM   reserva_habitacion l
WHERE  l.id_reserva_hab <= 2000;

-- 1.4 Casos que deben fallar
BEGIN
  DBMS_OUTPUT.PUT_LINE('--- Prueba 1.4a: checkout antes del check-in');
  DBMS_OUTPUT.PUT_LINE(pkg_turismouq.fn_valor_estadia(1, DATE '2026-12-17', DATE '2026-12-12'));
  DBMS_OUTPUT.PUT_LINE('FALLA: debió dar error');
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('Error esperado: ' || SQLERRM);
END;
/

BEGIN
  DBMS_OUTPUT.PUT_LINE('--- Prueba 1.4b: fechas fuera del calendario');
  DBMS_OUTPUT.PUT_LINE(pkg_turismouq.fn_valor_estadia(1, DATE '2027-03-01', DATE '2027-03-05'));
  DBMS_OUTPUT.PUT_LINE('FALLA: debió dar error');
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('Error esperado: ' || SQLERRM);
END;
/


-- =====================================================================
-- PRUEBA 2: sp_crear_reserva
-- =====================================================================

-- 2.1 Caso exitoso: busca una habitación libre del 12 al 17 de diciembre de
-- 2026 que admita 2 huéspedes y le crea una reserva al cliente 1.
DECLARE
  v_hab  habitacion.id_habitacion%TYPE;
  v_res  reserva.id_reserva%TYPE;
BEGIN
  DBMS_OUTPUT.PUT_LINE('--- Prueba 2.1: reserva válida');

  SELECT MIN(h.id_habitacion) INTO v_hab
  FROM   habitacion h
  WHERE  h.capacidad >= 2
  AND NOT EXISTS (SELECT 1
                  FROM   reserva_habitacion l
                  JOIN   reserva r ON r.id_reserva = l.id_reserva
                  WHERE  l.id_habitacion = h.id_habitacion
                  AND    r.estado IN ('CONFIRMADA', 'COMPLETADA')
                  AND    l.fecha_checkin  < DATE '2026-12-17'
                  AND    l.fecha_checkout > DATE '2026-12-12');

  pkg_turismouq.sp_crear_reserva(
    p_id_cliente    => 1,
    p_id_habitacion => v_hab,
    p_fecha_in      => DATE '2026-12-12',
    p_fecha_out     => DATE '2026-12-17',
    p_num_huespedes => 2,
    p_id_reserva    => v_res);

  :b_hab := v_hab;
  :b_res := v_res;
  DBMS_OUTPUT.PUT_LINE('Reserva creada: ' || v_res || ' en la habitación ' || v_hab);
END;
/

-- Lo que quedó guardado
SELECT r.id_reserva, r.id_cliente, r.id_alojamiento, r.fecha_checkin, r.fecha_checkout,
       r.estado, l.id_habitacion, l.num_huespedes, l.valor_estadia
FROM   reserva r
JOIN   reserva_habitacion l ON l.id_reserva = r.id_reserva
WHERE  r.id_reserva = :b_res;

-- 2.2 Habitación no disponible: la misma habitación, fechas que se cruzan
BEGIN
  DBMS_OUTPUT.PUT_LINE('--- Prueba 2.2: habitación no disponible');
  DECLARE v_res NUMBER;
  BEGIN
    pkg_turismouq.sp_crear_reserva(2, :b_hab, DATE '2026-12-14', DATE '2026-12-19', 1, v_res);
    DBMS_OUTPUT.PUT_LINE('FALLA: debió dar error');
  END;
EXCEPTION
  WHEN pkg_turismouq.e_no_disponible THEN
    DBMS_OUTPUT.PUT_LINE('Error esperado (e_no_disponible): ' || SQLERRM);
END;
/

-- 2.3 Checkout igual al check-in
BEGIN
  DBMS_OUTPUT.PUT_LINE('--- Prueba 2.3: checkout igual al check-in');
  DECLARE v_res NUMBER;
  BEGIN
    pkg_turismouq.sp_crear_reserva(2, :b_hab, DATE '2026-12-20', DATE '2026-12-20', 1, v_res);
    DBMS_OUTPUT.PUT_LINE('FALLA: debió dar error');
  END;
EXCEPTION
  WHEN pkg_turismouq.e_fechas_invalidas THEN
    DBMS_OUTPUT.PUT_LINE('Error esperado (e_fechas_invalidas): ' || SQLERRM);
END;
/

-- 2.4 Más huéspedes de los que caben
BEGIN
  DBMS_OUTPUT.PUT_LINE('--- Prueba 2.4: capacidad excedida');
  DECLARE v_res NUMBER;
  BEGIN
    pkg_turismouq.sp_crear_reserva(2, :b_hab, DATE '2026-12-20', DATE '2026-12-22', 25, v_res);
    DBMS_OUTPUT.PUT_LINE('FALLA: debió dar error');
  END;
EXCEPTION
  WHEN pkg_turismouq.e_capacidad THEN
    DBMS_OUTPUT.PUT_LINE('Error esperado (e_capacidad): ' || SQLERRM);
END;
/

-- 2.5 Llegar el mismo día en que sale el otro huésped sí se puede
DECLARE
  v_res NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('--- Prueba 2.5: check-in el día del checkout anterior');
  pkg_turismouq.sp_crear_reserva(2, :b_hab, DATE '2026-12-17', DATE '2026-12-19', 1, v_res);
  DBMS_OUTPUT.PUT_LINE('Reserva creada: ' || v_res || ' (no se cruza con la anterior)');
END;
/


-- =====================================================================
-- PRUEBA 3: disparador de fila trg_reshab_solape
-- =====================================================================
-- Se inserta directo en las tablas, sin pasar por sp_crear_reserva, para
-- comprobar que el disparador frena el solape aunque alguien se salte el
-- procedimiento.
DECLARE
  v_aloj  habitacion.id_alojamiento%TYPE;
  v_res   reserva.id_reserva%TYPE;
BEGIN
  DBMS_OUTPUT.PUT_LINE('--- Prueba 3: insertar directo una línea que se cruza');

  SELECT id_alojamiento INTO v_aloj FROM habitacion WHERE id_habitacion = :b_hab;

  INSERT INTO reserva (id_cliente, id_alojamiento, fecha_reserva,
                       fecha_checkin, fecha_checkout, estado)
  VALUES (3, v_aloj, SYSDATE, DATE '2026-12-13', DATE '2026-12-15', 'CONFIRMADA')
  RETURNING id_reserva INTO v_res;

  INSERT INTO reserva_habitacion (id_reserva, id_alojamiento, id_habitacion,
                                  fecha_checkin, fecha_checkout, num_huespedes, valor_estadia)
  VALUES (v_res, v_aloj, :b_hab, DATE '2026-12-13', DATE '2026-12-15', 1, 100000);

  DBMS_OUTPUT.PUT_LINE('FALLA: el disparador no bloqueó el solape');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Bloqueado por el disparador: ' || SQLERRM);
END;
/


-- =====================================================================
-- PRUEBA 4: disparador de auditoría trg_tarifa_auditoria
-- =====================================================================
-- Una sola sentencia UPDATE sube 10.000 pesos las 10 tarifas de una
-- habitación. Deben quedar 10 filas de auditoría con el valor anterior, el
-- nuevo, quién y cuándo, y FILAS_EN_SENTENCIA = 10.
UPDATE tarifa
SET    valor_noche = valor_noche + 10000
WHERE  id_habitacion = :b_hab;

-- Un UPDATE que no cambia el valor no debe dejar auditoría
UPDATE tarifa
SET    valor_noche = valor_noche
WHERE  id_habitacion = :b_hab;

SELECT a.id_tarifa, te.anio, te.categoria, a.valor_anterior, a.valor_nuevo,
       a.usuario_bd, a.usuario_so, a.equipo,
       TO_CHAR(a.fecha_cambio, 'DD/MM/YYYY HH24:MI:SS') AS fecha_cambio,
       a.filas_en_sentencia
FROM   auditoria_tarifa a
JOIN   temporada te ON te.id_temporada = a.id_temporada
ORDER BY a.id_auditoria;


-- =====================================================================
-- PRUEBA 5: cursor de liquidación (sp_liquidacion_mensual)
-- =====================================================================
-- 5.1 Liquidación de diciembre de 2025 para todos los alojamientos.
-- El detalle sale en la salida de DBMS_OUTPUT.
EXEC pkg_turismouq.sp_liquidacion_mensual(2025, 12)

-- Las 10 liquidaciones más altas guardadas en la tabla
SELECT l.id_alojamiento, a.nombre_comercial, l.reservas, l.noches,
       l.ingreso_estadia, l.ingreso_servicios, l.total, l.comision, l.valor_a_pagar
FROM   liquidacion_mensual l
JOIN   alojamiento a ON a.id_alojamiento = l.id_alojamiento
WHERE  l.anio = 2025 AND l.mes = 12
ORDER BY l.total DESC
FETCH FIRST 10 ROWS ONLY;

-- 5.2 Comprobación: el total liquidado debe ser igual a lo que suman las
-- reservas completadas con checkout en diciembre de 2025. DIFERENCIA = 0.
SELECT (SELECT SUM(total) FROM liquidacion_mensual WHERE anio = 2025 AND mes = 12) AS total_liquidado,
       (SELECT SUM(l.valor_estadia)
        FROM   reserva_habitacion l JOIN reserva r ON r.id_reserva = l.id_reserva
        WHERE  r.estado = 'COMPLETADA'
        AND    r.fecha_checkout >= DATE '2025-12-01' AND r.fecha_checkout < DATE '2026-01-01')
     + (SELECT NVL(SUM(rs.cantidad * rs.precio_unitario), 0)
        FROM   reserva_servicio rs JOIN reserva r ON r.id_reserva = rs.id_reserva
        WHERE  r.estado = 'COMPLETADA'
        AND    r.fecha_checkout >= DATE '2025-12-01' AND r.fecha_checkout < DATE '2026-01-01') AS total_reservas,
       (SELECT SUM(total) FROM liquidacion_mensual WHERE anio = 2025 AND mes = 12)
     - (SELECT SUM(l.valor_estadia)
        FROM   reserva_habitacion l JOIN reserva r ON r.id_reserva = l.id_reserva
        WHERE  r.estado = 'COMPLETADA'
        AND    r.fecha_checkout >= DATE '2025-12-01' AND r.fecha_checkout < DATE '2026-01-01')
     - (SELECT NVL(SUM(rs.cantidad * rs.precio_unitario), 0)
        FROM   reserva_servicio rs JOIN reserva r ON r.id_reserva = rs.id_reserva
        WHERE  r.estado = 'COMPLETADA'
        AND    r.fecha_checkout >= DATE '2025-12-01' AND r.fecha_checkout < DATE '2026-01-01') AS diferencia
FROM   dual;

-- 5.3 Liquidación de un solo alojamiento (el tercer parámetro del cursor)
EXEC pkg_turismouq.sp_liquidacion_mensual(2025, 12, 1)

-- 5.4 Mes inválido: debe fallar
BEGIN
  DBMS_OUTPUT.PUT_LINE('--- Prueba 5.4: mes 13');
  pkg_turismouq.sp_liquidacion_mensual(2025, 13);
  DBMS_OUTPUT.PUT_LINE('FALLA: debió dar error');
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('Error esperado: ' || SQLERRM);
END;
/


-- Se deshacen los cambios de las pruebas 1 a 5 (reservas de prueba,
-- tarifas modificadas, auditoría y liquidaciones)
ROLLBACK;


-- =====================================================================
-- PRUEBA 6: tablespace del histórico
-- =====================================================================
-- RESERVA_HISTORICO y su índice deben estar en TS_TURISMOUQ_HIST
SELECT segment_name, segment_type, tablespace_name,
       ROUND(bytes / 1024 / 1024, 2) AS mb
FROM   user_segments
WHERE  segment_name IN ('RESERVA_HISTORICO', 'PK_RESERVA_HISTORICO', 'RESERVA')
ORDER BY segment_name;

SELECT estado, COUNT(*) AS reservas, SUM(total_estadia + total_servicios) AS valor
FROM   reserva_historico
GROUP BY estado;


-- =====================================================================
-- PRUEBA 7: vista materializada de ocupación mensual
-- =====================================================================
-- 7.1 Política de refresco y trabajo programado
SELECT mview_name, refresh_method, refresh_mode,
       TO_CHAR(last_refresh_date, 'DD/MM/YYYY HH24:MI:SS') AS ultimo_refresco
FROM   user_mviews
WHERE  mview_name = 'MV_OCUPACION_MENSUAL';

-- La vista quedó en su propio grupo de refresco con la próxima fecha y el
-- intervalo (todos los días a la 1:00 a.m.)
SELECT rname AS grupo, TO_CHAR(next_date, 'DD/MM/YYYY HH24:MI') AS proximo_refresco,
       "INTERVAL" AS intervalo
FROM   user_refresh;

-- 7.2 Los 10 alojamientos con más ocupación en diciembre de 2025
SELECT nombre_comercial, municipio, noches_ocupadas, habitaciones, dias_mes, pct_ocupacion
FROM   mv_ocupacion_mensual
WHERE  anio = 2025 AND mes = 12
ORDER BY pct_ocupacion DESC
FETCH FIRST 10 ROWS ONLY;

-- 7.3 La vista cuadra con un cálculo en vivo: DIFERENCIA = 0
SELECT (SELECT SUM(noches_ocupadas) FROM mv_ocupacion_mensual) AS noches_en_vista,
       (SELECT COUNT(*)
        FROM   reserva_habitacion l
        JOIN   reserva r    ON r.id_reserva = l.id_reserva
        JOIN   calendario c ON c.fecha >= l.fecha_checkin AND c.fecha < l.fecha_checkout
        WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')) AS noches_en_vivo,
       (SELECT SUM(noches_ocupadas) FROM mv_ocupacion_mensual)
     - (SELECT COUNT(*)
        FROM   reserva_habitacion l
        JOIN   reserva r    ON r.id_reserva = l.id_reserva
        JOIN   calendario c ON c.fecha >= l.fecha_checkin AND c.fecha < l.fecha_checkout
        WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')) AS diferencia
FROM   dual;

-- 7.4 Refresco manual: la fecha del último refresco debe cambiar
EXEC DBMS_MVIEW.REFRESH('MV_OCUPACION_MENSUAL', 'C')

SELECT mview_name, TO_CHAR(last_refresh_date, 'DD/MM/YYYY HH24:MI:SS') AS ultimo_refresco
FROM   user_mviews
WHERE  mview_name = 'MV_OCUPACION_MENSUAL';
