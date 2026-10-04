-- TurismoUQ - Bases de Datos II (2026-2), grupo 01N
-- Equipo: Andrés Ospina Vera, <integrante 2>, <integrante 3>
-- Script 3: consultas de análisis (Oracle XE 21c)
-- Correr después de 01_ddl.sql y 02_carga.sql, completo con F5.
--
-- Ingreso de una reserva = habitaciones + servicios. Solo reservas COMPLETADAS.
-- Ocupación = noches vendidas / noches disponibles (reservas CONFIRMADAS y COMPLETADAS).
-- Las estadías se reparten noche por noche con la tabla CALENDARIO.

SET LINESIZE 220
SET PAGESIZE 200
SET SERVEROUTPUT ON

-- Formato de salida: ancho de las columnas de texto y separador de miles
-- en los valores en pesos (evita la notación científica en cifras grandes)
COLUMN municipio              FORMAT A14
COLUMN alojamiento            FORMAT A34
COLUMN tipo_alojamiento       FORMAT A18
COLUMN temporada              FORMAT A14
COLUMN concepto               FORMAT A10
COLUMN diagnostico            FORMAT A14
COLUMN ingresos               FORMAT 999,999,999,999
COLUMN ingresos_estadia       FORMAT 999,999,999,999
COLUMN ingresos_mes_anterior  FORMAT 999,999,999,999
COLUMN variacion              FORMAT 999,999,999,999
COLUMN valor                  FORMAT 999,999,999,999


-- Consulta 1 (PIVOT)
-- Porcentaje de ocupación de cada municipio en cada mes de 2025.
-- Se cuentan las noches ocupadas por municipio y mes, se dividen entre
-- habitaciones x días del mes y el PIVOT pasa los meses a columnas.
WITH noches AS (
  SELECT a.id_municipio,
         c.mes,
         COUNT(*) AS noches_ocupadas
  FROM   reserva_habitacion l
  JOIN   reserva r     ON r.id_reserva = l.id_reserva
  JOIN   alojamiento a ON a.id_alojamiento = r.id_alojamiento
  JOIN   calendario c  ON c.fecha >= l.fecha_checkin
                      AND c.fecha <  l.fecha_checkout
  WHERE  r.estado IN ('CONFIRMADA', 'COMPLETADA')
  AND    c.anio = 2025
  GROUP BY a.id_municipio, c.mes
),
capacidad AS (
  SELECT a.id_municipio, COUNT(*) AS habitaciones
  FROM   habitacion h
  JOIN   alojamiento a ON a.id_alojamiento = h.id_alojamiento
  GROUP BY a.id_municipio
),
dias AS (
  SELECT mes, COUNT(*) AS dias_mes
  FROM   calendario
  WHERE  anio = 2025
  GROUP BY mes
)
SELECT *
FROM (
  SELECT m.nombre AS municipio,
         n.mes,
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


-- Consulta 2 (ROLLUP con GROUPING)
-- Ingresos por estadía por municipio, tipo de alojamiento y temporada,
-- con subtotales y total general.
-- Cada noche se cruza con CALENDARIO y TARIFA para saber su temporada y su valor.
-- GROUPING vale 1 en las filas de subtotal; se usa para ponerles nombre.
-- NIVEL: 0 detalle, 1 subtotal de tipo, 3 subtotal de municipio, 7 total.
SELECT CASE WHEN GROUPING(m.nombre) = 1 THEN 'TOTAL GENERAL'
            ELSE m.nombre END                               AS municipio,
       CASE WHEN GROUPING(m.nombre)  = 1 THEN '-'
            WHEN GROUPING(ta.nombre) = 1 THEN 'Subtotal municipio'
            ELSE ta.nombre END                              AS tipo_alojamiento,
       CASE WHEN GROUPING(ta.nombre)    = 1 THEN '-'
            WHEN GROUPING(te.categoria) = 1 THEN 'Subtotal tipo'
            ELSE te.categoria END                           AS temporada,
       COUNT(*)                                             AS noches_vendidas,
       SUM(t.valor_noche)                                   AS ingresos_estadia,
       GROUPING_ID(m.nombre, ta.nombre, te.categoria)       AS nivel
FROM   reserva_habitacion l
JOIN   reserva r           ON r.id_reserva = l.id_reserva
JOIN   alojamiento a       ON a.id_alojamiento = r.id_alojamiento
JOIN   municipio m         ON m.id_municipio = a.id_municipio
JOIN   tipo_alojamiento ta ON ta.id_tipo = a.id_tipo
JOIN   calendario c        ON c.fecha >= l.fecha_checkin
                          AND c.fecha <  l.fecha_checkout
JOIN   temporada te        ON te.id_temporada = c.id_temporada
JOIN   tarifa t            ON t.id_habitacion = l.id_habitacion
                          AND t.id_temporada  = c.id_temporada
WHERE  r.estado = 'COMPLETADA'
GROUP BY ROLLUP (m.nombre, ta.nombre, te.categoria)
ORDER BY GROUPING(m.nombre), m.nombre,
         GROUPING(ta.nombre), ta.nombre,
         GROUPING(te.categoria), te.categoria;


-- Consulta 3 (RANK con PARTITION BY)
-- Los 3 alojamientos con más ingresos dentro de cada municipio.
-- Estadía y servicios se suman por separado para no duplicar valores.
-- El RANK se reinicia en cada municipio y el filtro va en la consulta de afuera.
WITH estadia AS (
  SELECT id_reserva, SUM(valor_estadia) AS valor
  FROM   reserva_habitacion
  GROUP BY id_reserva
),
servicios AS (
  SELECT id_reserva, SUM(cantidad * precio_unitario) AS valor
  FROM   reserva_servicio
  GROUP BY id_reserva
),
ingreso_alojamiento AS (
  SELECT r.id_alojamiento,
         COUNT(*)                        AS reservas,
         SUM(e.valor + NVL(s.valor, 0))  AS ingresos
  FROM   reserva r
  JOIN   estadia e        ON e.id_reserva = r.id_reserva
  LEFT JOIN servicios s   ON s.id_reserva = r.id_reserva
  WHERE  r.estado = 'COMPLETADA'
  GROUP BY r.id_alojamiento
)
SELECT municipio, puesto, alojamiento, tipo_alojamiento, reservas, ingresos
FROM (
  SELECT m.nombre           AS municipio,
         a.nombre_comercial AS alojamiento,
         ta.nombre          AS tipo_alojamiento,
         i.reservas,
         i.ingresos,
         RANK() OVER (PARTITION BY a.id_municipio ORDER BY i.ingresos DESC) AS puesto
  FROM   ingreso_alojamiento i
  JOIN   alojamiento a       ON a.id_alojamiento = i.id_alojamiento
  JOIN   municipio m         ON m.id_municipio = a.id_municipio
  JOIN   tipo_alojamiento ta ON ta.id_tipo = a.id_tipo
)
WHERE  puesto <= 3
ORDER BY municipio, puesto;


-- Consulta 4 (LAG)
-- Variación de los ingresos frente al mes anterior y frente al mismo mes
-- del año pasado. LAG(ingresos) trae el mes anterior y LAG(ingresos, 12)
-- el de hace un año.
WITH estadia AS (
  SELECT id_reserva, SUM(valor_estadia) AS valor
  FROM   reserva_habitacion
  GROUP BY id_reserva
),
servicios AS (
  SELECT id_reserva, SUM(cantidad * precio_unitario) AS valor
  FROM   reserva_servicio
  GROUP BY id_reserva
),
ingreso_mes AS (
  SELECT TRUNC(r.fecha_checkin, 'MM')    AS mes,
         COUNT(*)                        AS reservas,
         SUM(e.valor + NVL(s.valor, 0))  AS ingresos
  FROM   reserva r
  JOIN   estadia e        ON e.id_reserva = r.id_reserva
  LEFT JOIN servicios s   ON s.id_reserva = r.id_reserva
  WHERE  r.estado = 'COMPLETADA'
  GROUP BY TRUNC(r.fecha_checkin, 'MM')
)
SELECT TO_CHAR(mes, 'YYYY-MM')                              AS mes,
       reservas,
       ingresos,
       LAG(ingresos) OVER (ORDER BY mes)                    AS ingresos_mes_anterior,
       ingresos - LAG(ingresos) OVER (ORDER BY mes)         AS variacion,
       ROUND(100 * (ingresos - LAG(ingresos) OVER (ORDER BY mes))
                 / LAG(ingresos) OVER (ORDER BY mes), 1)    AS variacion_pct,
       ROUND(100 * (ingresos - LAG(ingresos, 12) OVER (ORDER BY mes))
                 / LAG(ingresos, 12) OVER (ORDER BY mes), 1) AS variacion_pct_anual
FROM   ingreso_mes
ORDER BY mes;


-- Consulta 5 (parametrizada)
-- Reservas, cancelaciones e ingresos por alojamiento entre dos fechas de llegada.
-- :p_desde y :p_hasta son variables de enlace. Van como texto porque VARIABLE
-- no acepta DATE. Para otro rango se cambian los dos EXEC.
VARIABLE p_desde VARCHAR2(10)
VARIABLE p_hasta VARCHAR2(10)
EXEC :p_desde := '2025-12-15'
EXEC :p_hasta := '2026-01-11'

WITH estadia AS (
  SELECT id_reserva, SUM(valor_estadia) AS valor
  FROM   reserva_habitacion
  GROUP BY id_reserva
),
servicios AS (
  SELECT id_reserva, SUM(cantidad * precio_unitario) AS valor
  FROM   reserva_servicio
  GROUP BY id_reserva
)
SELECT a.nombre_comercial                                             AS alojamiento,
       m.nombre                                                       AS municipio,
       COUNT(*)                                                       AS reservas,
       SUM(CASE WHEN r.estado = 'CANCELADA' THEN 1 ELSE 0 END)        AS canceladas,
       ROUND(100 * SUM(CASE WHEN r.estado = 'CANCELADA' THEN 1 ELSE 0 END)
                 / COUNT(*), 1)                                       AS pct_cancelacion,
       NVL(SUM(CASE WHEN r.estado = 'COMPLETADA'
                    THEN e.valor + NVL(s.valor, 0) END), 0)           AS ingresos
FROM   reserva r
JOIN   estadia e        ON e.id_reserva = r.id_reserva
LEFT JOIN servicios s   ON s.id_reserva = r.id_reserva
JOIN   alojamiento a    ON a.id_alojamiento = r.id_alojamiento
JOIN   municipio m      ON m.id_municipio = a.id_municipio
WHERE  r.fecha_checkin BETWEEN TO_DATE(:p_desde, 'YYYY-MM-DD')
                           AND TO_DATE(:p_hasta, 'YYYY-MM-DD')
GROUP BY a.nombre_comercial, m.nombre
ORDER BY ingresos DESC, reservas DESC
FETCH FIRST 15 ROWS ONLY;


-- Consulta 6 (UNPIVOT)
-- Qué parte del ingreso de cada tipo de alojamiento es estadía y qué parte
-- son servicios. El UNPIVOT pasa las columnas estadia y servicios a filas.
WITH estadia AS (
  SELECT id_reserva, SUM(valor_estadia) AS valor
  FROM   reserva_habitacion
  GROUP BY id_reserva
),
servicios AS (
  SELECT id_reserva, SUM(cantidad * precio_unitario) AS valor
  FROM   reserva_servicio
  GROUP BY id_reserva
),
resumen AS (
  SELECT ta.nombre               AS tipo_alojamiento,
         SUM(e.valor)            AS estadia,
         SUM(NVL(s.valor, 0))    AS servicios
  FROM   reserva r
  JOIN   estadia e           ON e.id_reserva = r.id_reserva
  LEFT JOIN servicios s      ON s.id_reserva = r.id_reserva
  JOIN   alojamiento a       ON a.id_alojamiento = r.id_alojamiento
  JOIN   tipo_alojamiento ta ON ta.id_tipo = a.id_tipo
  WHERE  r.estado = 'COMPLETADA'
  GROUP BY ta.nombre
)
SELECT tipo_alojamiento,
       concepto,
       valor,
       ROUND(100 * RATIO_TO_REPORT(valor) OVER (PARTITION BY tipo_alojamiento), 1) AS pct_del_tipo
FROM   resumen
UNPIVOT (
  valor FOR concepto IN (estadia AS 'Estadía', servicios AS 'Servicios')
)
ORDER BY tipo_alojamiento, concepto;


-- Consulta 7 (libre)
-- ¿Las estrellas que se pone cada alojamiento coinciden con sus reseñas?
-- Brecha = estrellas propias - promedio de reseñas. Solo alojamientos con
-- 30 reseñas o más.
SELECT DENSE_RANK() OVER (ORDER BY a.estrellas - AVG(rs.calificacion) DESC) AS puesto,
       a.nombre_comercial                               AS alojamiento,
       ta.nombre                                        AS tipo_alojamiento,
       m.nombre                                         AS municipio,
       a.estrellas                                      AS estrellas_propias,
       ROUND(AVG(rs.calificacion), 2)                   AS promedio_resenas,
       COUNT(*)                                         AS resenas,
       ROUND(a.estrellas - AVG(rs.calificacion), 2)     AS brecha,
       ROUND(AVG(AVG(rs.calificacion)) OVER (PARTITION BY ta.nombre), 2) AS promedio_del_tipo,
       CASE
         WHEN a.estrellas - AVG(rs.calificacion) >=  1 THEN 'Sobrevalorado'
         WHEN a.estrellas - AVG(rs.calificacion) <= -1 THEN 'Subvalorado'
         ELSE 'Coherente'
       END                                              AS diagnostico
FROM   resena rs
JOIN   reserva r           ON r.id_reserva = rs.id_reserva
JOIN   alojamiento a       ON a.id_alojamiento = r.id_alojamiento
JOIN   tipo_alojamiento ta ON ta.id_tipo = a.id_tipo
JOIN   municipio m         ON m.id_municipio = a.id_municipio
GROUP BY a.id_alojamiento, a.nombre_comercial, a.estrellas, ta.nombre, m.nombre
HAVING COUNT(*) >= 30
ORDER BY puesto, resenas DESC;
