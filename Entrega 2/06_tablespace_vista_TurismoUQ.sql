-- TurismoUQ - Bases de Datos II (2026-2), grupo 01N
-- Equipo: Andrés Ospina Vera, Juan Esteban Cuervo Jimenez
-- Script 6: tablespace del histórico y vista materializada - Entrega 2
-- Orden de ejecución: scripts 01 a 03 de la Entrega 1, luego 04, 05, 06 y 07
-- Se corre con la conexión TurismoUQ, completo con F5.
--
-- Requisito (una sola vez): crear un tablespace y programar el refresco de
-- la vista son permisos de administrador. Antes de este script, desde la
-- conexión XE_SYSTEM se le dan a TURISMOUQ con:
--   GRANT CREATE TABLESPACE, UNLIMITED TABLESPACE, CREATE JOB TO turismouq
-- (sin punto y coma aquí: un comentario que termina en ; confunde a SQL Developer)
--
-- Por qué un tablespace aparte para el histórico:
--   - Las reservas viejas casi no se consultan, pero crecen todos los años.
--     Separadas, no compiten por espacio con las tablas que se usan a diario.
--   - Se le puede poner un límite de tamaño propio sin afectar la operación.
--   - Se puede respaldar con otra frecuencia, o dejar en solo lectura cuando
--     un año ya está cerrado, porque esos datos ya no cambian.
--   - El archivo de datos se puede mover a un disco más barato o más lento.

SET SERVEROUTPUT ON
SET DEFINE OFF


-- 1. Crear el tablespace TS_TURISMOUQ_HIST (50 MB que crecen hasta 500 MB)
-- Primero se revisa si ya existe: así el script se puede correr varias
-- veces sin error. El archivo de datos queda en la carpeta de la base de
-- datos, porque solo se da el nombre del archivo y no la ruta completa.
DECLARE
  v_existe PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_existe
  FROM   user_tablespaces
  WHERE  tablespace_name = 'TS_TURISMOUQ_HIST';

  IF v_existe > 0 THEN
    DBMS_OUTPUT.PUT_LINE('El tablespace TS_TURISMOUQ_HIST ya existía');
  ELSE
    EXECUTE IMMEDIATE 'CREATE TABLESPACE ts_turismouq_hist ' ||
                      'DATAFILE ''ts_turismouq_hist01.dbf'' ' ||
                      'SIZE 50M AUTOEXTEND ON NEXT 10M MAXSIZE 500M';
    DBMS_OUTPUT.PUT_LINE('Tablespace TS_TURISMOUQ_HIST creado (ts_turismouq_hist01.dbf)');
  END IF;
END;
/


-- 2. Borrar la vista y el histórico si ya existen (script re-ejecutable)
BEGIN
  EXECUTE IMMEDIATE 'DROP MATERIALIZED VIEW mv_ocupacion_mensual';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -12003 THEN RAISE; END IF;  -- -12003: la vista no existe
END;
/

BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE reserva_historico PURGE';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -942 THEN RAISE; END IF;
END;
/


-- 3. Histórico de reservas, guardado en el tablespace TS_TURISMOUQ_HIST
-- Guarda una foto de cada reserva ya cerrada (completada o cancelada) con
-- sus totales. Aquí se copian las de 2024, que es un año terminado.
-- No se borran de RESERVA porque las consultas de la Entrega 1 usan 2024.
-- en la operación real, después de copiarlas sí se borrarían de la tabla
-- principal para que esta no crezca sin fin.
CREATE TABLE reserva_historico (
  id_reserva         NUMBER(10)    NOT NULL,
  id_cliente         NUMBER(8)     NOT NULL,
  id_alojamiento     NUMBER(6)     NOT NULL,
  fecha_reserva      DATE          NOT NULL,
  fecha_checkin      DATE          NOT NULL,
  fecha_checkout     DATE          NOT NULL,
  estado             VARCHAR2(12)  NOT NULL,
  fecha_cancelacion  DATE,
  habitaciones       NUMBER(3)     NOT NULL,
  total_estadia      NUMBER(14,2)  NOT NULL,
  total_servicios    NUMBER(14,2)  NOT NULL,
  total_pagado       NUMBER(14,2)  NOT NULL,
  fecha_archivo      DATE          DEFAULT SYSDATE NOT NULL,
  CONSTRAINT pk_reserva_historico PRIMARY KEY (id_reserva)
    USING INDEX TABLESPACE ts_turismouq_hist,
  CONSTRAINT ck_historico_estado  CHECK (estado IN ('COMPLETADA', 'CANCELADA'))
)
TABLESPACE ts_turismouq_hist;

COMMENT ON TABLE reserva_historico IS 'Reservas cerradas de años anteriores; vive en el tablespace TS_TURISMOUQ_HIST';

INSERT INTO reserva_historico (id_reserva, id_cliente, id_alojamiento, fecha_reserva,
                               fecha_checkin, fecha_checkout, estado, fecha_cancelacion,
                               habitaciones, total_estadia, total_servicios, total_pagado)
SELECT r.id_reserva, r.id_cliente, r.id_alojamiento, r.fecha_reserva,
       r.fecha_checkin, r.fecha_checkout, r.estado, r.fecha_cancelacion,
       e.habitaciones, e.valor, NVL(s.valor, 0), NVL(p.valor, 0)
FROM   reserva r
JOIN  (SELECT id_reserva, COUNT(*) AS habitaciones, SUM(valor_estadia) AS valor
       FROM reserva_habitacion GROUP BY id_reserva) e ON e.id_reserva = r.id_reserva
LEFT JOIN (SELECT id_reserva, SUM(cantidad * precio_unitario) AS valor
           FROM reserva_servicio GROUP BY id_reserva) s ON s.id_reserva = r.id_reserva
LEFT JOIN (SELECT id_reserva, SUM(monto) AS valor
           FROM pago WHERE estado = 'EXITOSO' GROUP BY id_reserva) p ON p.id_reserva = r.id_reserva
WHERE  r.estado IN ('COMPLETADA', 'CANCELADA')
AND    r.fecha_checkout < DATE '2025-01-01';

COMMIT;


-- 4. Vista materializada de ocupación mensual
-- Una fila por alojamiento y mes: noches vendidas, habitaciones, días del
-- mes y porcentaje de ocupación. Cuentan las reservas CONFIRMADA y
-- COMPLETADA, y cada estadía se reparte noche por noche con CALENDARIO.
--
-- Política de refresco: COMPLETA, una vez al día a la 1:00 a.m., y a mano
-- cuando se necesite con DBMS_MVIEW.REFRESH.
--   - No es ON COMMIT: refrescar en cada reserva haría más lenta cada
--     operación del día, y la ocupación mensual es un informe de gerencia
--     que no necesita estar al segundo.
--   - No es FAST (incremental): la consulta une rangos de fechas con el
--     calendario y agrupa; Oracle no puede refrescar eso por partes, y
--     además pediría logs en cada tabla base.
--   - Una vez al día, de madrugada, cuando casi nadie reserva: el informe
--     amanece al día y el costo de recalcular no molesta a los usuarios.
CREATE MATERIALIZED VIEW mv_ocupacion_mensual
BUILD IMMEDIATE
REFRESH COMPLETE
START WITH TRUNC(SYSDATE) + 1 + 1/24
NEXT TRUNC(SYSDATE) + 1 + 1/24
AS
SELECT o.id_alojamiento,
       a.nombre_comercial,
       m.nombre                                                     AS municipio,
       o.anio,
       o.mes,
       o.noches_ocupadas,
       h.habitaciones,
       d.dias_mes,
       ROUND(100 * o.noches_ocupadas / (h.habitaciones * d.dias_mes), 1) AS pct_ocupacion
FROM  (SELECT r.id_alojamiento, c.anio, c.mes, COUNT(*) AS noches_ocupadas
       FROM   reserva_habitacion l
       JOIN   reserva r    ON r.id_reserva = l.id_reserva
       JOIN   calendario c ON c.fecha >= l.fecha_checkin
                          AND c.fecha <  l.fecha_checkout
       WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
       GROUP BY r.id_alojamiento, c.anio, c.mes) o
JOIN  (SELECT id_alojamiento, COUNT(*) AS habitaciones
       FROM habitacion GROUP BY id_alojamiento) h ON h.id_alojamiento = o.id_alojamiento
JOIN  (SELECT anio, mes, COUNT(*) AS dias_mes
       FROM calendario GROUP BY anio, mes) d ON d.anio = o.anio AND d.mes = o.mes
JOIN   alojamiento a ON a.id_alojamiento = o.id_alojamiento
JOIN   municipio m   ON m.id_municipio = a.id_municipio;

COMMENT ON MATERIALIZED VIEW mv_ocupacion_mensual IS 'Ocupación mensual por alojamiento; refresco completo diario a la 1:00 a.m.';


-- 5. Revisión
-- El tablespace nuevo y su archivo de datos
SELECT tablespace_name, status, contents
FROM   user_tablespaces
WHERE  tablespace_name = 'TS_TURISMOUQ_HIST';

-- El histórico debe estar en TS_TURISMOUQ_HIST y las tablas normales en USERS
SELECT table_name, tablespace_name
FROM   user_tables
WHERE  table_name IN ('RESERVA', 'RESERVA_HISTORICO')
ORDER BY table_name;

SELECT COUNT(*)                       AS reservas_archivadas,
       MIN(fecha_checkout)            AS primer_checkout,
       MAX(fecha_checkout)            AS ultimo_checkout,
       SUM(total_estadia + total_servicios) AS valor_archivado
FROM   reserva_historico;

-- La vista debe tener filas, refresco COMPLETE y fecha del último refresco
SELECT mview_name, refresh_method, refresh_mode, build_mode,
       TO_CHAR(last_refresh_date, 'DD/MM/YYYY HH24:MI') AS ultimo_refresco
FROM   user_mviews
WHERE  mview_name = 'MV_OCUPACION_MENSUAL';

SELECT COUNT(*) AS filas_vista FROM mv_ocupacion_mensual;
