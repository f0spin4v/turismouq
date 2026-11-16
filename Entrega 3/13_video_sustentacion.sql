-- TurismoUQ - Bases de Datos II (2026-2), grupo 01N
-- Equipo: Andrés Ospina Vera, Juan Esteban Cuervo Jimenez
-- Script 13: demostración en vivo para el video de sustentación
--
-- Se abre con la conexión TurismoUQ, DESPUÉS de correr los scripts 00 a 12.
-- Cada bloque se corre por separado: se selecciona el bloque con el mouse y
-- se presiona F5 (ejecutar script) sobre la selección.
-- El orden es el que pide el enunciado del video. Ningún bloque deja datos
-- nuevos: los que cambian algo terminan en ROLLBACK.
-- Antes de grabar: Herramientas > Preferencias > Editor de código > Fuentes,
-- tamaño 16 o más.

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200
SET PAGESIZE 100

COLUMN tabla          FORMAT A20
COLUMN categoria      FORMAT A9
COLUMN operacion      FORMAT A9
COLUMN usuario_bd     FORMAT A13
COLUMN usuario_so     FORMAT A10
COLUMN equipo         FORMAT A12
COLUMN fecha_cambio   FORMAT A19
COLUMN municipio      FORMAT A12
COLUMN alojamiento    FORMAT A32
COLUMN tipo_alojamiento FORMAT A16


-- =====================================================================
-- PARTE 2. MODELO (2 min): volumen cargado
-- =====================================================================
SELECT 'MUNICIPIO' AS tabla, COUNT(*) AS filas FROM municipio UNION ALL
SELECT 'TIPO_ALOJAMIENTO',   COUNT(*) FROM tipo_alojamiento UNION ALL
SELECT 'ALOJAMIENTO',        COUNT(*) FROM alojamiento UNION ALL
SELECT 'HABITACION',         COUNT(*) FROM habitacion UNION ALL
SELECT 'TEMPORADA',          COUNT(*) FROM temporada UNION ALL
SELECT 'PERIODO_TEMPORADA',  COUNT(*) FROM periodo_temporada UNION ALL
SELECT 'CALENDARIO',         COUNT(*) FROM calendario UNION ALL
SELECT 'TARIFA',             COUNT(*) FROM tarifa UNION ALL
SELECT 'CLIENTE',            COUNT(*) FROM cliente UNION ALL
SELECT 'RESERVA',            COUNT(*) FROM reserva UNION ALL
SELECT 'RESERVA_HABITACION', COUNT(*) FROM reserva_habitacion UNION ALL
SELECT 'PAGO',               COUNT(*) FROM pago UNION ALL
SELECT 'SERVICIO',           COUNT(*) FROM servicio UNION ALL
SELECT 'RESERVA_SERVICIO',   COUNT(*) FROM reserva_servicio UNION ALL
SELECT 'RESENA',             COUNT(*) FROM resena UNION ALL
SELECT 'USUARIO_SISTEMA',    COUNT(*) FROM usuario_sistema;

-- Decisión 1: una reserva puede tener VARIAS habitaciones (RESERVA es la
-- cabecera y RESERVA_HABITACION las líneas). Ejemplo real:
SELECT r.id_reserva, COUNT(*) AS habitaciones, SUM(l.valor_estadia) AS valor
FROM   reserva r
JOIN   reserva_habitacion l ON l.id_reserva = r.id_reserva
GROUP BY r.id_reserva
HAVING COUNT(*) >= 3
ORDER BY r.id_reserva
FETCH FIRST 3 ROWS ONLY;


-- =====================================================================
-- PARTE 3. CONSULTAS DE ANÁLISIS (2 min)
-- =====================================================================
-- 3.1 PIVOT: porcentaje de ocupación de cada municipio en cada mes de 2025
WITH noches AS (
  SELECT a.id_municipio, c.mes, COUNT(*) AS noches_ocupadas
  FROM   reserva_habitacion l
  JOIN   reserva r     ON r.id_reserva = l.id_reserva
  JOIN   alojamiento a ON a.id_alojamiento = r.id_alojamiento
  JOIN   calendario c  ON c.fecha >= l.fecha_checkin AND c.fecha < l.fecha_checkout
  WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA') AND c.anio = 2025
  GROUP BY a.id_municipio, c.mes
),
capacidad AS (
  SELECT a.id_municipio, COUNT(*) AS habitaciones
  FROM   habitacion h JOIN alojamiento a ON a.id_alojamiento = h.id_alojamiento
  GROUP BY a.id_municipio
),
dias AS (
  SELECT mes, COUNT(*) AS dias_mes FROM calendario WHERE anio = 2025 GROUP BY mes
)
SELECT *
FROM (
  SELECT m.nombre AS municipio, n.mes,
         ROUND(100 * n.noches_ocupadas / (cp.habitaciones * d.dias_mes), 1) AS pct_ocupacion
  FROM   noches n
  JOIN   capacidad cp ON cp.id_municipio = n.id_municipio
  JOIN   dias d       ON d.mes = n.mes
  JOIN   municipio m  ON m.id_municipio = n.id_municipio
)
PIVOT (
  MAX(pct_ocupacion)
  FOR mes IN (1 AS ene, 2 AS feb, 3 AS mar, 4 AS abr, 5 AS may, 6 AS jun,
              7 AS jul, 8 AS ago, 9 AS sep, 10 AS oct, 11 AS nov, 12 AS dic)
)
ORDER BY municipio;

-- 3.2 RANK: los 3 alojamientos con más ingresos dentro de cada municipio
WITH estadia AS (
  SELECT id_reserva, SUM(valor_estadia) AS valor FROM reserva_habitacion GROUP BY id_reserva
),
servicios AS (
  SELECT id_reserva, SUM(cantidad * precio_unitario) AS valor FROM reserva_servicio GROUP BY id_reserva
),
ingreso_alojamiento AS (
  SELECT r.id_alojamiento, COUNT(*) AS reservas, SUM(e.valor + NVL(s.valor, 0)) AS ingresos
  FROM   reserva r
  JOIN   estadia e      ON e.id_reserva = r.id_reserva
  LEFT JOIN servicios s ON s.id_reserva = r.id_reserva
  WHERE  r.estado = 'COMPLETADA'
  GROUP BY r.id_alojamiento
)
SELECT municipio, puesto, alojamiento, tipo_alojamiento, reservas, ingresos
FROM (
  SELECT m.nombre AS municipio, a.nombre_comercial AS alojamiento, ta.nombre AS tipo_alojamiento,
         i.reservas, i.ingresos,
         RANK() OVER (PARTITION BY a.id_municipio ORDER BY i.ingresos DESC) AS puesto
  FROM   ingreso_alojamiento i
  JOIN   alojamiento a       ON a.id_alojamiento = i.id_alojamiento
  JOIN   municipio m         ON m.id_municipio = a.id_municipio
  JOIN   tipo_alojamiento ta ON ta.id_tipo = a.id_tipo
)
WHERE  puesto <= 3
ORDER BY municipio, puesto;


-- =====================================================================
-- PARTE 4. CAPA PL/SQL (3 min)
-- =====================================================================
-- 4.1 Estadía del 10 al 14 de enero de 2026 que cruza dos temporadas.
-- Primero noche por noche (para hacer la cuenta a mano):
SELECT c.fecha, te.categoria, te.anio AS temporada, t.valor_noche
FROM   calendario c
JOIN   temporada te ON te.id_temporada = c.id_temporada
JOIN   tarifa t     ON t.id_temporada = c.id_temporada AND t.id_habitacion = 1
WHERE  c.fecha >= DATE '2026-01-10' AND c.fecha < DATE '2026-01-14'
ORDER BY c.fecha;

-- A mano: 2 x 152.000 + 2 x 107.000 = 518.000. Ahora la función:
SELECT pkg_turismouq.fn_valor_estadia(1, DATE '2026-01-10', DATE '2026-01-14') AS valor_funcion
FROM   dual;

-- 4.2 Error propio de sp_crear_reserva: 25 huéspedes en una habitación
-- de 3 -> ORA-20003
DECLARE
  v_res NUMBER;
BEGIN
  pkg_turismouq.sp_crear_reserva(1, 3, DATE '2026-12-20', DATE '2026-12-22', 25, v_res);
END;
/

-- 4.3 El disparador rechaza un solape: se inserta directo, sin el
-- procedimiento, una línea encima de una reserva confirmada -> ORA-20010
DECLARE
  v_hab   reserva_habitacion.id_habitacion%TYPE;
  v_aloj  reserva_habitacion.id_alojamiento%TYPE;
  v_in    DATE;
  v_out   DATE;
  v_res   reserva.id_reserva%TYPE;
BEGIN
  -- Una reserva confirmada que ya existe
  SELECT l.id_habitacion, l.id_alojamiento, l.fecha_checkin, l.fecha_checkout
  INTO   v_hab, v_aloj, v_in, v_out
  FROM   reserva_habitacion l JOIN reserva r ON r.id_reserva = l.id_reserva
  WHERE  r.estado = 'CONFIRMADA'
  ORDER BY l.id_reserva_hab
  FETCH FIRST 1 ROW ONLY;
  DBMS_OUTPUT.PUT_LINE('Habitación ' || v_hab || ' ocupada del ' || TO_CHAR(v_in, 'DD/MM/YYYY') ||
                       ' al ' || TO_CHAR(v_out, 'DD/MM/YYYY') || '. Intento reservarla encima:');

  INSERT INTO reserva (id_cliente, id_alojamiento, fecha_reserva, fecha_checkin, fecha_checkout, estado)
  VALUES (3, v_aloj, SYSDATE, v_in, v_out, 'CONFIRMADA')
  RETURNING id_reserva INTO v_res;

  INSERT INTO reserva_habitacion (id_reserva, id_alojamiento, id_habitacion,
                                  fecha_checkin, fecha_checkout, num_huespedes, valor_estadia)
  VALUES (v_res, v_aloj, v_hab, v_in, v_out, 1, 100000);
END;
/
ROLLBACK;

-- 4.4 Auditoría de TARIFA: se sube una tarifa y queda registrado quién,
-- cuándo, el valor anterior y el nuevo
UPDATE tarifa SET valor_noche = valor_noche + 5000 WHERE id_tarifa = 1;

SELECT operacion, id_tarifa, valor_anterior, valor_nuevo, usuario_bd, usuario_so, equipo,
       TO_CHAR(fecha_cambio, 'DD/MM/YYYY HH24:MI:SS') AS fecha_cambio, filas_en_sentencia
FROM   auditoria_tarifa
ORDER BY id_auditoria DESC
FETCH FIRST 3 ROWS ONLY;

ROLLBACK;


-- =====================================================================
-- PARTE 5. TRANSACCIONES, ÍNDICES Y SEGURIDAD (3 min)
-- =====================================================================
-- 5.1 Rollback parcial con SAVEPOINT
-- Paso 1: la reserva (cabecera y línea), sin pago
DECLARE
  v_hab   habitacion.id_habitacion%TYPE;
  v_aloj  habitacion.id_alojamiento%TYPE;
  v_res   reserva.id_reserva%TYPE;
BEGIN
  -- Primera habitación libre del 26 al 28 de diciembre de 2026
  SELECT MIN(h.id_habitacion) INTO v_hab
  FROM   habitacion h
  WHERE  h.capacidad >= 2
  AND NOT EXISTS (SELECT 1 FROM reserva_habitacion l JOIN reserva r ON r.id_reserva = l.id_reserva
                  WHERE  l.id_habitacion = h.id_habitacion
                  AND    r.estado IN ('CONFIRMADA', 'COMPLETADA')
                  AND    l.fecha_checkin < DATE '2026-12-28' AND l.fecha_checkout > DATE '2026-12-26');
  SELECT id_alojamiento INTO v_aloj FROM habitacion WHERE id_habitacion = v_hab;

  INSERT INTO reserva (id_cliente, id_alojamiento, fecha_reserva, fecha_checkin, fecha_checkout, estado)
  VALUES (7, v_aloj, SYSDATE, DATE '2026-12-26', DATE '2026-12-28', 'PENDIENTE')
  RETURNING id_reserva INTO v_res;
  INSERT INTO reserva_habitacion (id_reserva, id_alojamiento, id_habitacion,
                                  fecha_checkin, fecha_checkout, num_huespedes, valor_estadia)
  VALUES (v_res, v_aloj, v_hab, DATE '2026-12-26', DATE '2026-12-28', 2,
          pkg_turismouq.fn_valor_estadia(v_hab, DATE '2026-12-26', DATE '2026-12-28'));
  DBMS_OUTPUT.PUT_LINE('Reserva ' || v_res || ' creada en la habitación ' || v_hab || ', sin pago');
END;
/

-- Paso 2: punto de guardado
SAVEPOINT antes_pago;

-- Paso 3: un pago equivocado de 1.000 pesos
INSERT INTO pago (id_reserva, fecha_pago, monto, metodo, estado)
SELECT id_reserva, SYSDATE, 1000, 'PSE', 'EXITOSO'
FROM   reserva WHERE id_cliente = 7 AND fecha_reserva >= TRUNC(SYSDATE);

SELECT r.id_reserva, r.estado, p.id_pago, p.monto
FROM   reserva r LEFT JOIN pago p ON p.id_reserva = r.id_reserva
WHERE  r.id_cliente = 7 AND r.fecha_reserva >= TRUNC(SYSDATE);

-- Paso 4: se deshace solo el pago
ROLLBACK TO antes_pago;

SELECT r.id_reserva, r.estado, p.id_pago, p.monto
FROM   reserva r LEFT JOIN pago p ON p.id_reserva = r.id_reserva
WHERE  r.id_cliente = 7 AND r.fecha_reserva >= TRUNC(SYSDATE);

-- (Para no dejar datos de la demostración se deshace todo)
ROLLBACK;

-- 5.2 Índice con su plan antes y después: historial de un cliente
DROP INDEX idx_reserva_cliente_fecha;

EXPLAIN PLAN SET STATEMENT_ID = 'VIDEO_ANTES' FOR
SELECT id_reserva, fecha_checkin, estado FROM reserva
WHERE  id_cliente = 1234 ORDER BY fecha_checkin DESC;
SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'VIDEO_ANTES', 'BASIC +COST +ROWS'));

CREATE INDEX idx_reserva_cliente_fecha ON reserva (id_cliente, fecha_checkin);

EXPLAIN PLAN SET STATEMENT_ID = 'VIDEO_DESPUES' FOR
SELECT id_reserva, fecha_checkin, estado FROM reserva
WHERE  id_cliente = 1234 ORDER BY fecha_checkin DESC;
SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'VIDEO_DESPUES', 'BASIC +COST +ROWS'));

-- Mediciones completas del script 10 (costo y milisegundos)
SELECT a.consulta, a.costo AS costo_antes, d.costo AS costo_despues,
       a.tiempo_ms AS ms_antes, d.tiempo_ms AS ms_despues
FROM   indice_medicion a
JOIN   indice_medicion d ON d.consulta = a.consulta AND d.momento = 'DESPUES'
WHERE  a.momento = 'ANTES'
ORDER BY a.consulta;

-- 5.3 Caso donde el índice NO ayuda: reservas COMPLETADAS (la mayoría)
SELECT estado, COUNT(*) AS reservas,
       ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (), 1) AS porcentaje
FROM   reserva GROUP BY estado ORDER BY reservas DESC;

CREATE INDEX idx_reserva_estado ON reserva (estado);

EXPLAIN PLAN SET STATEMENT_ID = 'VIDEO_ESTADO' FOR
SELECT id_reserva, fecha_checkin FROM reserva WHERE estado = 'COMPLETADA';
SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'VIDEO_ESTADO', 'BASIC +COST +ROWS'));

DROP INDEX idx_reserva_estado;

-- 5.4 Seguridad: el usuario de recepción intenta leer la tabla directamente
-- (este bloque cambia la conexión de la hoja; va de último)
CONNECT u_recepcion/Recepcion2026@localhost:1521/XEPDB1

SELECT COUNT(*) FROM turismouq.reserva;

-- Por la vista sí puede
SELECT * FROM turismouq.v_rec_habitaciones WHERE municipio = 'Salento' FETCH FIRST 5 ROWS ONLY;
