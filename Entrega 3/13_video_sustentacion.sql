-- TurismoUQ - Bases de Datos II (2026-2), grupo 01N
-- Equipo: Andrés Ospina Vera, Juan Esteban Cuervo Jiménez
-- Script 13: demostración en vivo del video, en el orden del enunciado.
-- Uso: abrir con la conexión TurismoUQ, correr el bloque 0 antes de grabar
-- y luego seleccionar cada bloque con el mouse y pulsar F5.
-- Ningún bloque deja datos nuevos: los que cambian algo terminan en ROLLBACK.

-- =====================================================================
-- 0. PREPARACIÓN (antes de grabar)
-- =====================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200
SET PAGESIZE 100
COLUMN tabla FORMAT A20
COLUMN categoria FORMAT A9
COLUMN operacion FORMAT A9
COLUMN usuario_bd FORMAT A13
COLUMN usuario_so FORMAT A10
COLUMN equipo FORMAT A12
COLUMN fecha_cambio FORMAT A19
COLUMN municipio FORMAT A12
COLUMN alojamiento FORMAT A32
COLUMN tipo_alojamiento FORMAT A16


-- =====================================================================
-- 2. DISEÑO Y DECISIONES DE NEGOCIO (Andrés)
-- =====================================================================
-- 2.1 Decisión 1: reservas con varias habitaciones
SELECT r.id_reserva, COUNT(*) AS habitaciones, SUM(l.valor_estadia) AS valor
FROM   reserva r
JOIN   reserva_habitacion l ON l.id_reserva = r.id_reserva
GROUP BY r.id_reserva
HAVING COUNT(*) >= 3
ORDER BY r.id_reserva
FETCH FIRST 3 ROWS ONLY;

-- 2.2 Decisión 2: estadía que cruza temporadas, noche por noche
SELECT c.fecha, te.categoria, te.anio AS temporada, t.valor_noche
FROM   calendario c
JOIN   temporada te ON te.id_temporada = c.id_temporada
JOIN   tarifa t     ON t.id_temporada = c.id_temporada AND t.id_habitacion = 1
WHERE  c.fecha >= DATE '2026-01-10' AND c.fecha < DATE '2026-01-14'
ORDER BY c.fecha;

-- A mano: 2 x 152.000 + 2 x 107.000 = 518.000. Ahora la función:
SELECT pkg_turismouq.fn_valor_estadia(1, DATE '2026-01-10', DATE '2026-01-14') AS valor_funcion
FROM   dual;

-- 2.3 Regla 1: habitación de otro alojamiento -> ORA-02291
INSERT INTO reserva_habitacion (id_reserva, id_alojamiento, id_habitacion,
                                fecha_checkin, fecha_checkout, num_huespedes, valor_estadia)
SELECT r.id_reserva, r.id_alojamiento, h.id_habitacion,
       r.fecha_checkin, r.fecha_checkout, 1, 100000
FROM   reserva r, habitacion h
WHERE  r.id_reserva = 1
AND    h.id_alojamiento <> r.id_alojamiento
AND    ROWNUM = 1;

-- 2.4 Regla 2: un día en dos temporadas -> ORA-00001
INSERT INTO calendario (fecha, id_periodo, id_temporada)
SELECT DATE '2025-12-24', id_periodo, id_temporada
FROM   calendario
WHERE  fecha = DATE '2025-09-10';

ROLLBACK;

-- 2.5 Volumen cargado
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


-- =====================================================================
-- 3. CONSULTAS DE ANÁLISIS (Andrés)
-- =====================================================================
-- 3.1 PIVOT: ocupación por municipio y mes de 2025
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

-- 3.2 RANK: los 3 alojamientos con más ingresos en cada municipio
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
-- 4. CAPA PL/SQL (Juan)
-- =====================================================================
-- 4.1 Error propio de sp_crear_reserva -> ORA-20003
DECLARE
  v_res NUMBER;
BEGIN
  pkg_turismouq.sp_crear_reserva(1, 3, DATE '2026-12-20', DATE '2026-12-22', 25, v_res);
END;
/

-- 4.2 El disparador rechaza un solape -> ORA-20010
DECLARE
  v_hab   reserva_habitacion.id_habitacion%TYPE;
  v_aloj  reserva_habitacion.id_alojamiento%TYPE;
  v_in    DATE;
  v_out   DATE;
  v_res   reserva.id_reserva%TYPE;
BEGIN
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

-- 4.3 Auditoría de TARIFA: UPDATE, DELETE e INSERT
UPDATE tarifa SET valor_noche = valor_noche + 5000 WHERE id_tarifa = 1;

DECLARE
  v_hab  tarifa.id_habitacion%TYPE;
  v_tem  tarifa.id_temporada%TYPE;
  v_val  tarifa.valor_noche%TYPE;
BEGIN
  SELECT id_habitacion, id_temporada, valor_noche
  INTO   v_hab, v_tem, v_val
  FROM   tarifa WHERE id_tarifa = 2;
  DELETE FROM tarifa WHERE id_tarifa = 2;
  INSERT INTO tarifa (id_habitacion, id_temporada, valor_noche)
  VALUES (v_hab, v_tem, v_val + 10000);
END;
/

SELECT operacion, id_tarifa, valor_anterior, valor_nuevo, usuario_bd, usuario_so, equipo,
       TO_CHAR(fecha_cambio, 'DD/MM/YYYY HH24:MI:SS') AS fecha_cambio, filas_en_sentencia
FROM   auditoria_tarifa
ORDER BY id_auditoria DESC
FETCH FIRST 3 ROWS ONLY;

ROLLBACK;


-- =====================================================================
-- 5. TRANSACCIONES, ÍNDICES Y SEGURIDAD (Juan)
-- =====================================================================
-- 5.1 Rollback parcial con SAVEPOINT
-- Paso 1: la reserva sin pago
DECLARE
  v_hab   habitacion.id_habitacion%TYPE;
  v_aloj  habitacion.id_alojamiento%TYPE;
  v_res   reserva.id_reserva%TYPE;
BEGIN
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

ROLLBACK;

-- 5.2 Índice con su plan antes y después
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

-- Mediciones de las tres consultas (script 10)
SELECT a.consulta, a.costo AS costo_antes, d.costo AS costo_despues,
       a.tiempo_ms AS ms_antes, d.tiempo_ms AS ms_despues
FROM   indice_medicion a
JOIN   indice_medicion d ON d.consulta = a.consulta AND d.momento = 'DESPUES'
WHERE  a.momento = 'ANTES'
ORDER BY a.consulta;

-- 5.3 El índice que no ayuda
SELECT estado, COUNT(*) AS reservas,
       ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (), 1) AS porcentaje
FROM   reserva GROUP BY estado ORDER BY reservas DESC;

CREATE INDEX idx_reserva_estado ON reserva (estado);

EXPLAIN PLAN SET STATEMENT_ID = 'VIDEO_ESTADO' FOR
SELECT id_reserva, fecha_checkin FROM reserva WHERE estado = 'COMPLETADA';
SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'VIDEO_ESTADO', 'BASIC +COST +ROWS'));

EXPLAIN PLAN SET STATEMENT_ID = 'VIDEO_FORZADO' FOR
SELECT /*+ INDEX(r idx_reserva_estado) */ id_reserva, fecha_checkin
FROM   reserva r WHERE estado = 'COMPLETADA';
SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'VIDEO_FORZADO', 'BASIC +COST +ROWS'));

DROP INDEX idx_reserva_estado;

-- 5.4 Recepción intenta leer una tabla -> ORA-00942 (va de último)
CONNECT u_recepcion/Recepcion2026@localhost:1521/XEPDB1

SELECT COUNT(*) FROM turismouq.reserva;

SELECT * FROM turismouq.v_rec_habitaciones WHERE municipio = 'Salento' FETCH FIRST 5 ROWS ONLY;
