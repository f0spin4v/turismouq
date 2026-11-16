-- TurismoUQ - Bases de Datos II (2026-2), grupo 01N
-- Equipo: Andrés Ospina Vera, Juan Esteban Cuervo Jimenez
-- Script 8: transacciones con SAVEPOINT - Entrega 3
-- Orden de ejecución: 00 a 03 (Entrega 1), 04 a 07 (Entrega 2) y luego este.
-- Se corre con la conexión TurismoUQ, completo con F5.
--
-- Contenido:
--   1. Procedimiento sp_reservar_y_pagar: reserva, servicio y pago en una
--      sola transacción, con tres SAVEPOINT
--   2. Demostración paso a paso de un rollback parcial (para el documento
--      y el video)
--   3. Pruebas del procedimiento: todo bien, servicio que falla, pago que
--      falla y reserva que falla
--   4. Limpieza de los datos de prueba
--
-- Marca de los datos de prueba: la carga (script 02) nunca crea reservas con
-- fecha_reserva después del 29/09/2026, así que todo lo que tenga
-- fecha_reserva desde el 30/09/2026 es de pruebas y se borra al final.

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
SET LINESIZE 200
SET PAGESIZE 100


-- =====================================================================
-- 1. Procedimiento sp_reservar_y_pagar
-- =====================================================================
-- Registra en UNA transacción la reserva (cabecera + línea), un servicio
-- opcional y el pago. Usa tres puntos de guardado:
--
--   sp_inicio      antes de todo
--   sp_reserva     la reserva ya está guardada (PENDIENTE)
--   sp_antes_pago  la reserva y el servicio ya están guardados
--
-- Qué pasa si algo falla:
--   - Falla la reserva  -> ROLLBACK TO sp_inicio: no queda nada y se
--                          devuelve el error (todo o nada).
--   - Falla el servicio -> ROLLBACK TO sp_reserva: rollback PARCIAL, se
--                          pierde solo el servicio y se sigue con el pago.
--   - Falla el pago     -> ROLLBACK TO sp_antes_pago: rollback PARCIAL, se
--                          pierde solo el pago; la reserva queda PENDIENTE
--                          (pendiente de pago) y no CONFIRMADA.
--   - Todo bien         -> la reserva pasa a CONFIRMADA y se hace COMMIT.
--
-- Una reserva nunca queda CONFIRMADA sin su pago, ni una cabecera sin su
-- línea: eso es lo atómico. El pago debe ser por el valor exacto de la
-- estadía más los servicios. Si p_monto llega vacío (NULL) se cobra el total
-- exacto (así lo usa recepción, que no ve las tarifas).
--
-- p_confirmar = 'S' hace COMMIT al final. Con 'N' el que llama decide
-- (sirve para probar sin dejar datos).
CREATE OR REPLACE PROCEDURE sp_reservar_y_pagar (
  p_id_cliente     IN  cliente.id_cliente%TYPE,
  p_id_habitacion  IN  habitacion.id_habitacion%TYPE,
  p_fecha_in       IN  DATE,
  p_fecha_out      IN  DATE,
  p_num_huespedes  IN  NUMBER,
  p_monto          IN  NUMBER,
  p_metodo         IN  VARCHAR2,
  p_id_servicio    IN  NUMBER   DEFAULT NULL,
  p_cantidad       IN  NUMBER   DEFAULT 1,
  p_confirmar      IN  VARCHAR2 DEFAULT 'S',
  p_id_reserva     OUT reserva.id_reserva%TYPE,
  p_resultado      OUT VARCHAR2
)
IS
  v_id_aloj    reserva.id_alojamiento%TYPE;
  v_precio     servicio.precio%TYPE;
  v_estadia    NUMBER;
  v_servicios  NUMBER := 0;
  v_total      NUMBER;
  v_monto      NUMBER;
  v_nota_serv  VARCHAR2(400);
BEGIN
  SAVEPOINT sp_inicio;

  -- Paso 1: la reserva (cabecera + línea). Nace PENDIENTE: solo pasa a
  -- CONFIRMADA si el pago entra. sp_crear_reserva valida fechas,
  -- capacidad y disponibilidad, y bloquea la habitación con FOR UPDATE.
  pkg_turismouq.sp_crear_reserva(
    p_id_cliente    => p_id_cliente,
    p_id_habitacion => p_id_habitacion,
    p_fecha_in      => p_fecha_in,
    p_fecha_out     => p_fecha_out,
    p_num_huespedes => p_num_huespedes,
    p_id_reserva    => p_id_reserva,
    p_estado        => 'PENDIENTE');

  SELECT id_alojamiento INTO v_id_aloj FROM reserva WHERE id_reserva = p_id_reserva;

  SAVEPOINT sp_reserva;

  -- Paso 2: servicio opcional. Si falla, se deshace solo el servicio.
  IF p_id_servicio IS NOT NULL THEN
    BEGIN
      SELECT precio INTO v_precio FROM servicio WHERE id_servicio = p_id_servicio;

      -- La llave foránea (id_servicio, id_alojamiento) rechaza un servicio
      -- que no sea del mismo alojamiento de la reserva (ORA-02291)
      INSERT INTO reserva_servicio (id_reserva, id_servicio, id_alojamiento,
                                    cantidad, precio_unitario)
      VALUES (p_id_reserva, p_id_servicio, v_id_aloj, p_cantidad, v_precio);

      v_servicios := p_cantidad * v_precio;
      v_nota_serv := ' Servicio ' || p_id_servicio || ' agregado.';
    EXCEPTION
      WHEN OTHERS THEN
        ROLLBACK TO sp_reserva;      -- rollback parcial: solo el servicio
        v_servicios := 0;
        v_nota_serv := ' Servicio descartado (' || SQLERRM || ').';
    END;
  END IF;

  SAVEPOINT sp_antes_pago;

  -- Paso 3: el pago. Se inserta y después se revisa que cubra el total.
  SELECT SUM(valor_estadia) INTO v_estadia
  FROM   reserva_habitacion
  WHERE  id_reserva = p_id_reserva;

  v_total := v_estadia + v_servicios;
  v_monto := NVL(p_monto, v_total);

  BEGIN
    -- Los CHECK de PAGO rechazan montos <= 0 y métodos que no existen
    INSERT INTO pago (id_reserva, fecha_pago, monto, metodo, estado)
    VALUES (p_id_reserva, SYSDATE, v_monto, p_metodo, 'EXITOSO');

    IF v_monto <> v_total THEN
      RAISE_APPLICATION_ERROR(-20021,
        'El pago de ' || v_monto || ' no coincide con el total de la reserva (' || v_total || ')');
    END IF;

    UPDATE reserva SET estado = 'CONFIRMADA' WHERE id_reserva = p_id_reserva;
    p_resultado := 'CONFIRMADA: reserva ' || p_id_reserva || ' y pago de ' || v_total ||
                   ' guardados.' || v_nota_serv;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK TO sp_antes_pago;     -- rollback parcial: solo el pago
      p_resultado := 'PENDIENTE: reserva ' || p_id_reserva || ' guardada sin pago. ' ||
                     'Pago rechazado (' || SQLERRM || ').' || v_nota_serv;
  END;

  IF p_confirmar = 'S' THEN
    COMMIT;
  END IF;

EXCEPTION
  WHEN OTHERS THEN
    -- Falló la reserva: se deshace todo lo de este procedimiento
    ROLLBACK TO sp_inicio;
    p_id_reserva := NULL;
    RAISE;
END sp_reservar_y_pagar;
/

SHOW ERRORS PROCEDURE sp_reservar_y_pagar


-- =====================================================================
-- 2. Demostración paso a paso de un rollback parcial
-- =====================================================================
-- Reserva de prueba: cliente 7, del 26 al 28 de diciembre de 2026, en la
-- primera habitación libre esas noches. Cada paso muestra qué hay en la
-- base de datos.

-- Paso 1: INSERT de la reserva (cabecera y línea)
DECLARE
  v_hab   habitacion.id_habitacion%TYPE;
  v_aloj  habitacion.id_alojamiento%TYPE;
  v_res   reserva.id_reserva%TYPE;
BEGIN
  SELECT MIN(h.id_habitacion) INTO v_hab
  FROM   habitacion h
  WHERE  h.capacidad >= 2
  AND NOT EXISTS (SELECT 1
                  FROM   reserva_habitacion l
                  JOIN   reserva r ON r.id_reserva = l.id_reserva
                  WHERE  l.id_habitacion = h.id_habitacion
                  AND    r.estado IN ('CONFIRMADA', 'COMPLETADA')
                  AND    l.fecha_checkin  < DATE '2026-12-28'
                  AND    l.fecha_checkout > DATE '2026-12-26');

  SELECT id_alojamiento INTO v_aloj FROM habitacion WHERE id_habitacion = v_hab;

  INSERT INTO reserva (id_cliente, id_alojamiento, fecha_reserva,
                       fecha_checkin, fecha_checkout, estado)
  VALUES (7, v_aloj, SYSDATE, DATE '2026-12-26', DATE '2026-12-28', 'PENDIENTE')
  RETURNING id_reserva INTO v_res;

  INSERT INTO reserva_habitacion (id_reserva, id_alojamiento, id_habitacion,
                                  fecha_checkin, fecha_checkout, num_huespedes, valor_estadia)
  VALUES (v_res, v_aloj, v_hab, DATE '2026-12-26', DATE '2026-12-28', 2,
          pkg_turismouq.fn_valor_estadia(v_hab, DATE '2026-12-26', DATE '2026-12-28'));

  DBMS_OUTPUT.PUT_LINE('Paso 1: reserva ' || v_res || ' creada en la habitación ' || v_hab);
END;
/

-- Lo que hay: la reserva y su línea, sin pagos
SELECT r.id_reserva, r.estado, l.id_habitacion, l.valor_estadia,
       (SELECT COUNT(*) FROM pago p WHERE p.id_reserva = r.id_reserva) AS pagos
FROM   reserva r
JOIN   reserva_habitacion l ON l.id_reserva = r.id_reserva
WHERE  r.id_cliente = 7
AND    r.fecha_reserva >= DATE '2026-09-30';

-- Paso 2: punto de guardado antes del pago
SAVEPOINT antes_pago;

-- Paso 3: INSERT de un pago equivocado (1.000 pesos en vez del total)
INSERT INTO pago (id_reserva, fecha_pago, monto, metodo, estado)
SELECT r.id_reserva, SYSDATE, 1000, 'PSE', 'EXITOSO'
FROM   reserva r
WHERE  r.id_cliente = 7
AND    r.fecha_reserva >= DATE '2026-09-30';

-- Lo que hay: la reserva Y el pago equivocado
SELECT r.id_reserva, r.estado, p.id_pago, p.monto, p.metodo
FROM   reserva r
LEFT JOIN pago p ON p.id_reserva = r.id_reserva
WHERE  r.id_cliente = 7
AND    r.fecha_reserva >= DATE '2026-09-30';

-- Paso 4: se deshace SOLO lo que pasó después del punto de guardado
ROLLBACK TO antes_pago;

-- Lo que hay: la reserva sigue, el pago desapareció (ID_PAGO vacío)
SELECT r.id_reserva, r.estado, p.id_pago, p.monto, p.metodo
FROM   reserva r
LEFT JOIN pago p ON p.id_reserva = r.id_reserva
WHERE  r.id_cliente = 7
AND    r.fecha_reserva >= DATE '2026-09-30';

-- Paso 5: se confirma lo que quedó (la reserva PENDIENTE sin pago)
COMMIT;

SELECT r.id_reserva, r.estado,
       (SELECT COUNT(*) FROM reserva_habitacion l WHERE l.id_reserva = r.id_reserva) AS lineas,
       (SELECT COUNT(*) FROM pago p WHERE p.id_reserva = r.id_reserva)              AS pagos
FROM   reserva r
WHERE  r.id_cliente = 7
AND    r.fecha_reserva >= DATE '2026-09-30';


-- =====================================================================
-- 3. Pruebas de sp_reservar_y_pagar
-- =====================================================================
-- Las cuatro pruebas usan la primera habitación libre del 22 al 24 de
-- diciembre de 2026 que tenga servicios en su alojamiento, y fechas
-- distintas para no chocar entre ellas.

-- 3.1 Todo bien: reserva + servicio + pago exacto -> CONFIRMADA
DECLARE
  v_hab    habitacion.id_habitacion%TYPE;
  v_serv   servicio.id_servicio%TYPE;
  v_total  NUMBER;
  v_res    reserva.id_reserva%TYPE;
  v_txt    VARCHAR2(1000);
BEGIN
  DBMS_OUTPUT.PUT_LINE('--- Prueba 3.1: todo bien');

  SELECT MIN(h.id_habitacion) INTO v_hab
  FROM   habitacion h
  WHERE  h.capacidad >= 2
  AND EXISTS (SELECT 1 FROM servicio s WHERE s.id_alojamiento = h.id_alojamiento)
  AND NOT EXISTS (SELECT 1
                  FROM   reserva_habitacion l
                  JOIN   reserva r ON r.id_reserva = l.id_reserva
                  WHERE  l.id_habitacion = h.id_habitacion
                  AND    r.estado IN ('CONFIRMADA', 'COMPLETADA')
                  AND    l.fecha_checkin  < DATE '2026-12-24'
                  AND    l.fecha_checkout > DATE '2026-12-22');

  -- Un servicio del mismo alojamiento
  SELECT MIN(s.id_servicio) INTO v_serv
  FROM   servicio s
  JOIN   habitacion h ON h.id_alojamiento = s.id_alojamiento
  WHERE  h.id_habitacion = v_hab;

  -- Total esperado: estadía noche por noche + 2 unidades del servicio
  SELECT pkg_turismouq.fn_valor_estadia(v_hab, DATE '2026-12-22', DATE '2026-12-24') + 2 * s.precio
  INTO   v_total
  FROM   servicio s
  WHERE  s.id_servicio = v_serv;

  sp_reservar_y_pagar(8, v_hab, DATE '2026-12-22', DATE '2026-12-24', 2,
                      v_total, 'TARJETA_CREDITO', v_serv, 2, 'S', v_res, v_txt);
  DBMS_OUTPUT.PUT_LINE(v_txt);
END;
/

-- 3.2 Servicio que falla: un servicio de OTRO alojamiento. Rollback parcial
-- a sp_reserva: se pierde el servicio, pero la reserva y el pago quedan.
DECLARE
  v_hab    habitacion.id_habitacion%TYPE;
  v_serv   servicio.id_servicio%TYPE;
  v_res    reserva.id_reserva%TYPE;
  v_txt    VARCHAR2(1000);
BEGIN
  DBMS_OUTPUT.PUT_LINE('--- Prueba 3.2: servicio de otro alojamiento');

  SELECT MIN(h.id_habitacion) INTO v_hab
  FROM   habitacion h
  WHERE  h.capacidad >= 2
  AND NOT EXISTS (SELECT 1
                  FROM   reserva_habitacion l
                  JOIN   reserva r ON r.id_reserva = l.id_reserva
                  WHERE  l.id_habitacion = h.id_habitacion
                  AND    r.estado IN ('CONFIRMADA', 'COMPLETADA')
                  AND    l.fecha_checkin  < DATE '2026-12-30'
                  AND    l.fecha_checkout > DATE '2026-12-28');

  SELECT MIN(s.id_servicio) INTO v_serv
  FROM   servicio s
  WHERE  s.id_alojamiento <> (SELECT id_alojamiento FROM habitacion WHERE id_habitacion = v_hab);

  -- El pago es solo por la estadía, porque el servicio se va a descartar
  sp_reservar_y_pagar(9, v_hab, DATE '2026-12-28', DATE '2026-12-30', 2,
                      pkg_turismouq.fn_valor_estadia(v_hab, DATE '2026-12-28', DATE '2026-12-30'),
                      'PSE', v_serv, 1, 'S', v_res, v_txt);
  DBMS_OUTPUT.PUT_LINE(v_txt);
END;
/

-- 3.3 Pago que falla: el monto no coincide. Rollback parcial a
-- sp_antes_pago: la reserva queda PENDIENTE y sin pago.
DECLARE
  v_hab    habitacion.id_habitacion%TYPE;
  v_res    reserva.id_reserva%TYPE;
  v_txt    VARCHAR2(1000);
BEGIN
  DBMS_OUTPUT.PUT_LINE('--- Prueba 3.3: pago por un valor equivocado');

  SELECT MIN(h.id_habitacion) INTO v_hab
  FROM   habitacion h
  WHERE  h.capacidad >= 2
  AND NOT EXISTS (SELECT 1
                  FROM   reserva_habitacion l
                  JOIN   reserva r ON r.id_reserva = l.id_reserva
                  WHERE  l.id_habitacion = h.id_habitacion
                  AND    r.estado IN ('CONFIRMADA', 'COMPLETADA')
                  AND    l.fecha_checkin  < DATE '2026-12-18'
                  AND    l.fecha_checkout > DATE '2026-12-16');

  sp_reservar_y_pagar(10, v_hab, DATE '2026-12-16', DATE '2026-12-18', 1,
                      50000, 'EFECTIVO', NULL, 1, 'S', v_res, v_txt);
  DBMS_OUTPUT.PUT_LINE(v_txt);
END;
/

-- 3.4 La reserva falla (checkout antes del check-in): ROLLBACK TO
-- sp_inicio, no queda nada y el error sale al que llamó.
DECLARE
  v_antes    PLS_INTEGER;
  v_despues  PLS_INTEGER;
  v_res      reserva.id_reserva%TYPE;
  v_txt      VARCHAR2(1000);
BEGIN
  DBMS_OUTPUT.PUT_LINE('--- Prueba 3.4: la reserva misma falla');
  SELECT COUNT(*) INTO v_antes FROM reserva;
  BEGIN
    sp_reservar_y_pagar(11, 1, DATE '2026-12-20', DATE '2026-12-18', 1,
                        100000, 'PSE', NULL, 1, 'S', v_res, v_txt);
    DBMS_OUTPUT.PUT_LINE('FALLA: debió dar error');
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('Error esperado: ' || SQLERRM);
  END;
  SELECT COUNT(*) INTO v_despues FROM reserva;
  DBMS_OUTPUT.PUT_LINE('Reservas antes: ' || v_antes || ' | después: ' || v_despues);
END;
/

-- Lo que quedó de cada prueba: estado, líneas, servicios y pagos
SELECT r.id_cliente                                                           AS cliente,
       CASE r.id_cliente WHEN 7  THEN 'Demo paso a paso'
                         WHEN 8  THEN '3.1 Todo bien'
                         WHEN 9  THEN '3.2 Servicio falla'
                         WHEN 10 THEN '3.3 Pago falla' END                    AS prueba,
       r.id_reserva, r.estado,
       (SELECT COUNT(*) FROM reserva_habitacion l WHERE l.id_reserva = r.id_reserva) AS lineas,
       (SELECT COUNT(*) FROM reserva_servicio s  WHERE s.id_reserva = r.id_reserva) AS servicios,
       (SELECT COUNT(*) FROM pago p              WHERE p.id_reserva = r.id_reserva) AS pagos,
       (SELECT SUM(p.monto) FROM pago p          WHERE p.id_reserva = r.id_reserva) AS pagado
FROM   reserva r
WHERE  r.fecha_reserva >= DATE '2026-09-30'
AND    r.id_cliente BETWEEN 7 AND 11
ORDER BY r.id_cliente;


-- =====================================================================
-- 4. Limpieza: se borran las reservas de prueba de este script
-- =====================================================================
-- Comentar este bloque si se quieren dejar los datos para mostrarlos.
BEGIN
  FOR r IN (SELECT id_reserva FROM reserva
            WHERE  fecha_reserva >= DATE '2026-09-30'
            AND    id_cliente BETWEEN 7 AND 11) LOOP
    DELETE FROM reserva_servicio   WHERE id_reserva = r.id_reserva;
    DELETE FROM pago               WHERE id_reserva = r.id_reserva;
    DELETE FROM reserva_habitacion WHERE id_reserva = r.id_reserva;
    DELETE FROM reserva            WHERE id_reserva = r.id_reserva;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Datos de prueba borrados');
END;
/
