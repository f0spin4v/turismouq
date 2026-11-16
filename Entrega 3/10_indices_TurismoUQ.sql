-- TurismoUQ - Bases de Datos II (2026-2), grupo 01N
-- Equipo: Andrés Ospina Vera, Juan Esteban Cuervo Jimenez
-- Script 10: índices y planes de ejecución - Entrega 3
-- Se corre con la conexión TurismoUQ, completo con F5. Tarda 1 o 2 minutos
-- porque mide cada consulta miles de veces antes y después del índice.
--
-- Tres consultas que la plataforma hace todo el tiempo y que hoy recorren
-- la tabla completa (TABLE ACCESS FULL):
--
--   Q1  ¿Está libre la habitación X entre dos fechas?  (la usan
--       sp_crear_reserva y el disparador de solapes en cada reserva)
--       -> índice COMPUESTO (id_habitacion, fecha_checkin, fecha_checkout)
--   Q2  Recepción busca un cliente por su correo, sin importar mayúsculas
--       -> índice BASADO EN FUNCIÓN sobre UPPER(correo)
--   Q3  Historial de reservas de un cliente, de la más reciente a la más
--       vieja
--       -> índice COMPUESTO (id_cliente, fecha_checkin)
--
-- Y un caso donde el índice NO ayuda: reservas por estado.
--
-- Cómo se mide cada consulta:
--   costo   el costo que calcula el optimizador (EXPLAIN PLAN)
--   tiempo  milisegundos que tarda en correr N veces seguidas con valores
--           distintos (DBMS_UTILITY.GET_TIME, que cuenta centésimas)
-- Todo queda en la tabla INDICE_MEDICION y al final sale el resumen.
-- El script se puede correr varias veces: al inicio borra los índices.

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200
SET PAGESIZE 200


-- =====================================================================
-- 0. Preparación
-- =====================================================================
-- Borrar los índices de este script si ya existen (para volver al "antes")
BEGIN
  FOR i IN (SELECT index_name FROM user_indexes
            WHERE  index_name IN ('IDX_RESHAB_HAB_FECHAS', 'IDX_CLIENTE_CORREO_UPPER',
                                  'IDX_RESERVA_CLIENTE_FECHA', 'IDX_RESERVA_ESTADO')) LOOP
    EXECUTE IMMEDIATE 'DROP INDEX ' || i.index_name;
  END LOOP;
END;
/

-- Tabla donde se guardan las mediciones
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE indice_medicion PURGE';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -942 THEN RAISE; END IF;
END;
/

CREATE TABLE indice_medicion (
  consulta     VARCHAR2(10)   NOT NULL,
  momento      VARCHAR2(10)   NOT NULL,
  costo        NUMBER,
  operaciones  VARCHAR2(400),
  ejecuciones  NUMBER,
  tiempo_ms    NUMBER,
  CONSTRAINT pk_indice_medicion PRIMARY KEY (consulta, momento)
);

-- Guarda el costo y las operaciones del plan que se acaba de explicar
CREATE OR REPLACE PROCEDURE sp_registrar_plan (
  p_consulta  IN VARCHAR2,
  p_momento   IN VARCHAR2
)
IS
  v_id     VARCHAR2(30) := p_consulta || '_' || p_momento;
  v_costo  NUMBER;
  v_ops    VARCHAR2(400);
BEGIN
  SELECT cost INTO v_costo
  FROM   plan_table
  WHERE  statement_id = v_id AND id = 0;

  SELECT LISTAGG(operation || ' ' || options || ' ' || object_name, ' / ')
           WITHIN GROUP (ORDER BY id)
  INTO   v_ops
  FROM   plan_table
  WHERE  statement_id = v_id
  AND    object_name IS NOT NULL;

  MERGE INTO indice_medicion m
  USING (SELECT p_consulta AS c, p_momento AS mo FROM dual) x
  ON (m.consulta = x.c AND m.momento = x.mo)
  WHEN MATCHED THEN UPDATE SET m.costo = v_costo, m.operaciones = v_ops
  WHEN NOT MATCHED THEN INSERT (consulta, momento, costo, operaciones)
                        VALUES (p_consulta, p_momento, v_costo, v_ops);
  COMMIT;
END sp_registrar_plan;
/

-- Estadísticas al día, para que el optimizador decida con datos reales
BEGIN
  DBMS_STATS.GATHER_TABLE_STATS(USER, 'RESERVA_HABITACION');
  DBMS_STATS.GATHER_TABLE_STATS(USER, 'RESERVA');
  DBMS_STATS.GATHER_TABLE_STATS(USER, 'CLIENTE');
END;
/

DELETE FROM plan_table;
COMMIT;

-- Tamaño de las tablas que se van a consultar
SELECT table_name, num_rows, blocks
FROM   user_tables
WHERE  table_name IN ('RESERVA_HABITACION', 'RESERVA', 'CLIENTE')
ORDER BY table_name;


-- =====================================================================
-- Q1. Disponibilidad de una habitación (índice compuesto)
-- =====================================================================
-- Hoy: no hay índice que empiece por id_habitacion (la única llave única
-- empieza por id_reserva), así que Oracle lee las ~30.000 líneas.

-- Q1 ANTES: plan
EXPLAIN PLAN SET STATEMENT_ID = 'Q1_ANTES' FOR
SELECT COUNT(*)
FROM   reserva_habitacion
WHERE  id_habitacion  = 150
AND    fecha_checkin  < DATE '2025-07-10'
AND    fecha_checkout > DATE '2025-07-01';

SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'Q1_ANTES', 'TYPICAL'));
BEGIN sp_registrar_plan('Q1', 'ANTES'); END;
/

-- Q1 ANTES: tiempo de 2.000 consultas con habitaciones y fechas distintas
DECLARE
  v_ini  PLS_INTEGER;
  v_n    PLS_INTEGER;
  v_d    DATE;
BEGIN
  v_ini := DBMS_UTILITY.GET_TIME;
  FOR i IN 1 .. 2000 LOOP
    v_d := DATE '2024-01-01' + MOD(i * 13, 900);
    SELECT COUNT(*) INTO v_n
    FROM   reserva_habitacion
    WHERE  id_habitacion  = MOD(i * 7, 700) + 1
    AND    fecha_checkin  < v_d + 5
    AND    fecha_checkout > v_d;
  END LOOP;
  UPDATE indice_medicion SET ejecuciones = 2000, tiempo_ms = (DBMS_UTILITY.GET_TIME - v_ini) * 10
  WHERE  consulta = 'Q1' AND momento = 'ANTES';
  COMMIT;
END;
/

-- Q1: el índice. Primero la habitación (igualdad) y después las fechas
-- (rango): así Oracle salta directo a las líneas de esa habitación y,
-- dentro de ellas, a las fechas. Como las tres columnas que usa la consulta
-- están en el índice, ni siquiera tiene que ir a la tabla.
CREATE INDEX idx_reshab_hab_fechas
  ON reserva_habitacion (id_habitacion, fecha_checkin, fecha_checkout);

-- Q1 DESPUÉS: plan
EXPLAIN PLAN SET STATEMENT_ID = 'Q1_DESPUES' FOR
SELECT COUNT(*)
FROM   reserva_habitacion
WHERE  id_habitacion  = 150
AND    fecha_checkin  < DATE '2025-07-10'
AND    fecha_checkout > DATE '2025-07-01';

SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'Q1_DESPUES', 'TYPICAL'));
BEGIN sp_registrar_plan('Q1', 'DESPUES'); END;
/

-- Q1 DESPUÉS: tiempo
DECLARE
  v_ini  PLS_INTEGER;
  v_n    PLS_INTEGER;
  v_d    DATE;
BEGIN
  v_ini := DBMS_UTILITY.GET_TIME;
  FOR i IN 1 .. 2000 LOOP
    v_d := DATE '2024-01-01' + MOD(i * 13, 900);
    SELECT COUNT(*) INTO v_n
    FROM   reserva_habitacion
    WHERE  id_habitacion  = MOD(i * 7, 700) + 1
    AND    fecha_checkin  < v_d + 5
    AND    fecha_checkout > v_d;
  END LOOP;
  UPDATE indice_medicion SET ejecuciones = 2000, tiempo_ms = (DBMS_UTILITY.GET_TIME - v_ini) * 10
  WHERE  consulta = 'Q1' AND momento = 'DESPUES';
  COMMIT;
END;
/


-- =====================================================================
-- Q2. Buscar un cliente por correo sin importar mayúsculas (basado en función)
-- =====================================================================
-- Ya existe un índice sobre CORREO (el de la llave única uq_cliente_correo),
-- pero la consulta compara UPPER(correo). Un índice normal guarda el correo
-- tal cual, no en mayúsculas, así que Oracle no lo puede usar y lee toda
-- la tabla.

-- Q2 ANTES: plan
EXPLAIN PLAN SET STATEMENT_ID = 'Q2_ANTES' FOR
SELECT id_cliente, nombres, apellidos
FROM   cliente
WHERE  UPPER(correo) = UPPER('Cliente.Prueba@Correo.com');

SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'Q2_ANTES', 'TYPICAL'));
BEGIN sp_registrar_plan('Q2', 'ANTES'); END;
/

-- Q2 ANTES: tiempo buscando cada uno de los clientes por su correo
DECLARE
  TYPE t_txt IS TABLE OF cliente.correo%TYPE;
  v_correos  t_txt;
  v_ini      PLS_INTEGER;
  v_n        PLS_INTEGER;
  v_id       cliente.id_cliente%TYPE;
BEGIN
  -- Se escriben en minúsculas para que la búsqueda de verdad necesite UPPER
  SELECT LOWER(correo) BULK COLLECT INTO v_correos FROM cliente;
  v_ini := DBMS_UTILITY.GET_TIME;
  FOR i IN 1 .. v_correos.COUNT LOOP
    SELECT MIN(id_cliente) INTO v_id
    FROM   cliente
    WHERE  UPPER(correo) = UPPER(v_correos(i));
  END LOOP;
  v_n := v_correos.COUNT;
  UPDATE indice_medicion SET ejecuciones = v_n,
                             tiempo_ms   = (DBMS_UTILITY.GET_TIME - v_ini) * 10
  WHERE  consulta = 'Q2' AND momento = 'ANTES';
  COMMIT;
END;
/

-- Q2: índice basado en función. Guarda UPPER(correo) ya calculado, así la
-- comparación se hace contra el índice y no fila por fila.
-- Después de crearlo se recogen estadísticas para que el optimizador
-- conozca la columna oculta que Oracle crea para la función.
CREATE INDEX idx_cliente_correo_upper ON cliente (UPPER(correo));

BEGIN
  DBMS_STATS.GATHER_TABLE_STATS(USER, 'CLIENTE', method_opt => 'FOR ALL HIDDEN COLUMNS SIZE 1');
END;
/

-- Q2 DESPUÉS: plan
EXPLAIN PLAN SET STATEMENT_ID = 'Q2_DESPUES' FOR
SELECT id_cliente, nombres, apellidos
FROM   cliente
WHERE  UPPER(correo) = UPPER('Cliente.Prueba@Correo.com');

SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'Q2_DESPUES', 'TYPICAL'));
BEGIN sp_registrar_plan('Q2', 'DESPUES'); END;
/

-- Q2 DESPUÉS: tiempo
DECLARE
  TYPE t_txt IS TABLE OF cliente.correo%TYPE;
  v_correos  t_txt;
  v_ini      PLS_INTEGER;
  v_n        PLS_INTEGER;
  v_id       cliente.id_cliente%TYPE;
BEGIN
  SELECT LOWER(correo) BULK COLLECT INTO v_correos FROM cliente;
  v_ini := DBMS_UTILITY.GET_TIME;
  FOR i IN 1 .. v_correos.COUNT LOOP
    SELECT MIN(id_cliente) INTO v_id
    FROM   cliente
    WHERE  UPPER(correo) = UPPER(v_correos(i));
  END LOOP;
  v_n := v_correos.COUNT;
  UPDATE indice_medicion SET ejecuciones = v_n,
                             tiempo_ms   = (DBMS_UTILITY.GET_TIME - v_ini) * 10
  WHERE  consulta = 'Q2' AND momento = 'DESPUES';
  COMMIT;
END;
/


-- =====================================================================
-- Q3. Historial de reservas de un cliente (índice compuesto)
-- =====================================================================
-- id_cliente es llave foránea de RESERVA pero Oracle no le crea índice
-- solo. Sin índice lee las 25.000 reservas para sacar las ~8 del cliente y
-- además las tiene que ordenar.

-- Q3 ANTES: plan
EXPLAIN PLAN SET STATEMENT_ID = 'Q3_ANTES' FOR
SELECT id_reserva, fecha_checkin, fecha_checkout, estado
FROM   reserva
WHERE  id_cliente = 1234
ORDER BY fecha_checkin DESC;

SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'Q3_ANTES', 'TYPICAL'));
BEGIN sp_registrar_plan('Q3', 'ANTES'); END;
/

-- Q3 ANTES: tiempo del historial de cada cliente
DECLARE
  TYPE t_res IS TABLE OF reserva.id_reserva%TYPE;
  v_ids   t_res;
  v_ini   PLS_INTEGER;
  v_max   PLS_INTEGER;
BEGIN
  SELECT MAX(id_cliente) INTO v_max FROM cliente;
  v_ini := DBMS_UTILITY.GET_TIME;
  FOR i IN 1 .. v_max LOOP
    SELECT id_reserva BULK COLLECT INTO v_ids
    FROM   reserva
    WHERE  id_cliente = i
    ORDER BY fecha_checkin DESC;
  END LOOP;
  UPDATE indice_medicion SET ejecuciones = v_max, tiempo_ms = (DBMS_UTILITY.GET_TIME - v_ini) * 10
  WHERE  consulta = 'Q3' AND momento = 'ANTES';
  COMMIT;
END;
/

-- Q3: índice compuesto. Primero el cliente (filtra) y después la fecha
-- (ya viene ordenada dentro del índice, así Oracle no tiene que ordenar).
-- También le sirve a Oracle para no bloquear toda la tabla RESERVA cuando
-- se borra o se cambia un cliente (llave foránea con índice).
CREATE INDEX idx_reserva_cliente_fecha ON reserva (id_cliente, fecha_checkin);

-- Q3 DESPUÉS: plan
EXPLAIN PLAN SET STATEMENT_ID = 'Q3_DESPUES' FOR
SELECT id_reserva, fecha_checkin, fecha_checkout, estado
FROM   reserva
WHERE  id_cliente = 1234
ORDER BY fecha_checkin DESC;

SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'Q3_DESPUES', 'TYPICAL'));
BEGIN sp_registrar_plan('Q3', 'DESPUES'); END;
/

-- Q3 DESPUÉS: tiempo
DECLARE
  TYPE t_res IS TABLE OF reserva.id_reserva%TYPE;
  v_ids   t_res;
  v_ini   PLS_INTEGER;
  v_max   PLS_INTEGER;
BEGIN
  SELECT MAX(id_cliente) INTO v_max FROM cliente;
  v_ini := DBMS_UTILITY.GET_TIME;
  FOR i IN 1 .. v_max LOOP
    SELECT id_reserva BULK COLLECT INTO v_ids
    FROM   reserva
    WHERE  id_cliente = i
    ORDER BY fecha_checkin DESC;
  END LOOP;
  UPDATE indice_medicion SET ejecuciones = v_max, tiempo_ms = (DBMS_UTILITY.GET_TIME - v_ini) * 10
  WHERE  consulta = 'Q3' AND momento = 'DESPUES';
  COMMIT;
END;
/


-- =====================================================================
-- Q4. Caso donde el índice NO ayuda: reservas por estado
-- =====================================================================
-- La columna ESTADO solo tiene 4 valores posibles y la mayoría de las
-- reservas están COMPLETADAS. Primero se ve cómo se reparten:
SELECT estado, COUNT(*) AS reservas,
       ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (), 1) AS porcentaje
FROM   reserva
GROUP BY estado
ORDER BY reservas DESC;

-- Se crea el índice sobre ESTADO
CREATE INDEX idx_reserva_estado ON reserva (estado);

BEGIN
  DBMS_STATS.GATHER_TABLE_STATS(USER, 'RESERVA', method_opt => 'FOR COLUMNS estado SIZE 254');
END;
/

-- Q4 con el índice creado: el optimizador NO lo usa, sigue con TABLE ACCESS FULL
EXPLAIN PLAN SET STATEMENT_ID = 'Q4_ANTES' FOR
SELECT id_reserva, fecha_checkin, fecha_checkout
FROM   reserva
WHERE  estado = 'COMPLETADA';

SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'Q4_ANTES', 'TYPICAL'));
BEGIN sp_registrar_plan('Q4', 'ANTES'); END;
/

-- Q4 obligando a Oracle a usar el índice con una pista (hint): el costo SUBE
EXPLAIN PLAN SET STATEMENT_ID = 'Q4_DESPUES' FOR
SELECT /*+ INDEX(r idx_reserva_estado) */ id_reserva, fecha_checkin, fecha_checkout
FROM   reserva r
WHERE  estado = 'COMPLETADA';

SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'Q4_DESPUES', 'TYPICAL'));
BEGIN sp_registrar_plan('Q4', 'DESPUES'); END;
/

-- Q4: tiempo de 50 corridas de cada forma
DECLARE
  TYPE t_res IS TABLE OF reserva.id_reserva%TYPE;
  v_ids   t_res;
  v_ini   PLS_INTEGER;
BEGIN
  -- Sin pista (el optimizador escoge recorrer la tabla)
  v_ini := DBMS_UTILITY.GET_TIME;
  FOR i IN 1 .. 50 LOOP
    SELECT id_reserva BULK COLLECT INTO v_ids
    FROM   reserva
    WHERE  estado = 'COMPLETADA';
  END LOOP;
  UPDATE indice_medicion SET ejecuciones = 50, tiempo_ms = (DBMS_UTILITY.GET_TIME - v_ini) * 10
  WHERE  consulta = 'Q4' AND momento = 'ANTES';

  -- Forzando el índice
  v_ini := DBMS_UTILITY.GET_TIME;
  FOR i IN 1 .. 50 LOOP
    SELECT /*+ INDEX(r idx_reserva_estado) */ id_reserva BULK COLLECT INTO v_ids
    FROM   reserva r
    WHERE  estado = 'COMPLETADA';
  END LOOP;
  UPDATE indice_medicion SET ejecuciones = 50, tiempo_ms = (DBMS_UTILITY.GET_TIME - v_ini) * 10
  WHERE  consulta = 'Q4' AND momento = 'DESPUES';
  COMMIT;
END;
/

-- Por qué no ayuda (baja selectividad):
--   El índice sirve para encontrar POCAS filas de muchas. Aquí la consulta
--   pide la mayoría de la tabla (las completadas son más de la mitad).
--   Con el índice Oracle tendría que leer el índice y luego ir a la tabla
--   una vez por cada fila encontrada (TABLE ACCESS BY INDEX ROWID), saltando
--   de bloque en bloque y leyendo el mismo bloque muchas veces. Recorrer la
--   tabla completa lee cada bloque una sola vez y en lecturas de varios
--   bloques, así que sale más barato. Por eso el optimizador ignora el
--   índice, y si se le obliga con la pista el costo y el tiempo suben.
--   Además el índice no es gratis: cada INSERT o UPDATE de una reserva
--   tiene que actualizarlo. Por eso se borra.
DROP INDEX idx_reserva_estado;


-- =====================================================================
-- Resumen de las mediciones
-- =====================================================================
-- En Q4 "ANTES" es sin pista (tabla completa) y "DESPUES" es forzando el índice.
SELECT consulta, momento, costo, ejecuciones, tiempo_ms, operaciones
FROM   indice_medicion
ORDER BY consulta, DECODE(momento, 'ANTES', 1, 2);

SELECT a.consulta,
       a.costo                                   AS costo_antes,
       d.costo                                   AS costo_despues,
       a.tiempo_ms                               AS ms_antes,
       d.tiempo_ms                               AS ms_despues,
       ROUND(a.tiempo_ms / NULLIF(d.tiempo_ms, 0), 1) AS veces_mas_rapido
FROM   indice_medicion a
JOIN   indice_medicion d ON d.consulta = a.consulta AND d.momento = 'DESPUES'
WHERE  a.momento = 'ANTES'
ORDER BY a.consulta;

-- Índices que quedan creados
SELECT index_name, table_name, index_type,
       LISTAGG(column_name, ', ') WITHIN GROUP (ORDER BY column_position) AS columnas
FROM   user_indexes
JOIN   user_ind_columns USING (index_name, table_name)
WHERE  index_name IN ('IDX_RESHAB_HAB_FECHAS', 'IDX_CLIENTE_CORREO_UPPER', 'IDX_RESERVA_CLIENTE_FECHA')
GROUP BY index_name, table_name, index_type
ORDER BY index_name;
