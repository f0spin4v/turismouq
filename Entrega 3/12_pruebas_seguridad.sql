-- TurismoUQ - Bases de Datos II (2026-2), grupo 01N
-- Equipo: Andrés Ospina Vera, Juan Esteban Cuervo Jimenez
-- Script 12: pruebas de seguridad - Entrega 3
-- Se corre DESPUÉS del 11, completo con F5, desde cualquier hoja de
-- SQL Developer: el script se conecta solo con cada usuario (CONNECT).
-- Si la conexión de SQL Developer no es localhost:1521/XEPDB1, cambiar la
-- cadena @localhost:1521/XEPDB1 en cada CONNECT.
--
-- Errores que deben salir (son la prueba de que la seguridad funciona):
--   ORA-00942  la tabla o vista no existe: así responde Oracle cuando el
--              usuario no tiene NINGÚN permiso sobre el objeto
--   ORA-01031  privilegios insuficientes: tiene algún permiso sobre el
--              objeto, pero no el que intenta usar

SET SERVEROUTPUT ON
SET DEFINE OFF


-- =====================================================================
-- 1. RECEPCIÓN: solo vistas, nunca tablas
-- =====================================================================
CONNECT u_recepcion/Recepcion2026@localhost:1521/XEPDB1

-- 1.1 Intenta leer la tabla RESERVA directamente: ORA-00942
SELECT COUNT(*) FROM turismouq.reserva;

-- 1.2 Intenta cambiar un cliente en la tabla: ORA-00942
UPDATE turismouq.cliente SET telefono = '3000000000' WHERE id_cliente = 1;

-- 1.3 Por las vistas sí puede trabajar
SELECT * FROM turismouq.v_rec_habitaciones
WHERE  municipio = 'Salento'
FETCH FIRST 5 ROWS ONLY;

-- Habitaciones de Salento libres del 5 al 7 de diciembre de 2026
SELECT h.id_habitacion, h.alojamiento, h.numero, h.capacidad
FROM   turismouq.v_rec_habitaciones h
WHERE  h.municipio = 'Salento'
AND NOT EXISTS (SELECT 1 FROM turismouq.v_rec_ocupacion o
                WHERE  o.id_habitacion  = h.id_habitacion
                AND    o.estado = 'CONFIRMADA'
                AND    o.fecha_checkin  < DATE '2026-12-07'
                AND    o.fecha_checkout > DATE '2026-12-05')
FETCH FIRST 5 ROWS ONLY;

-- 1.4 Registra un cliente nuevo por la vista
INSERT INTO turismouq.v_rec_clientes (tipo_documento, num_documento, nombres, apellidos,
                                      correo, telefono, ciudad_origen)
VALUES ('CC', '1094000001', 'Cliente', 'De Prueba', 'cliente.prueba.recepcion@correo.com',
        '3001234567', 'Armenia');

SELECT id_cliente, nombres, apellidos, correo
FROM   turismouq.v_rec_clientes
WHERE  correo = 'cliente.prueba.recepcion@correo.com';

-- 1.5 Reserva y pago con el procedimiento (sin COMMIT, solo para probar)
DECLARE
  v_hab  NUMBER;
  v_cli  NUMBER;
  v_res  NUMBER;
  v_txt  VARCHAR2(1000);
BEGIN
  SELECT id_cliente INTO v_cli FROM turismouq.v_rec_clientes
  WHERE  correo = 'cliente.prueba.recepcion@correo.com';

  SELECT MIN(h.id_habitacion) INTO v_hab
  FROM   turismouq.v_rec_habitaciones h
  WHERE  h.municipio = 'Salento' AND h.capacidad >= 2
  AND NOT EXISTS (SELECT 1 FROM turismouq.v_rec_ocupacion o
                  WHERE  o.id_habitacion  = h.id_habitacion
                  AND    o.estado = 'CONFIRMADA'
                  AND    o.fecha_checkin  < DATE '2026-12-07'
                  AND    o.fecha_checkout > DATE '2026-12-05');

  -- p_monto NULL: se cobra el total exacto; p_confirmar 'N': sin COMMIT
  turismouq.sp_reservar_y_pagar(v_cli, v_hab, DATE '2026-12-05', DATE '2026-12-07', 2,
                                NULL, 'TARJETA_DEBITO', NULL, 1, 'N', v_res, v_txt);
  DBMS_OUTPUT.PUT_LINE('Recepción: ' || v_txt);
END;
/

SELECT * FROM turismouq.v_rec_reservas
WHERE  cliente = 'Cliente De Prueba';

-- Se deshace la prueba de recepción (cliente y reserva)
ROLLBACK;


-- =====================================================================
-- 2. ADMINISTRADOR DE ALOJAMIENTO
-- =====================================================================
CONNECT u_admin_aloj/AdminAloj2026@localhost:1521/XEPDB1

-- 2.1 Puede cambiar el valor de una tarifa (y queda auditado con su usuario)
UPDATE turismouq.tarifa SET valor_noche = valor_noche + 1000 WHERE id_tarifa = 1;
COMMIT;

-- 2.2 No puede cambiar otra columna de TARIFA (su UPDATE es solo de valor_noche): ORA-01031
UPDATE turismouq.tarifa SET id_temporada = 2 WHERE id_tarifa = 1;

-- 2.3 Ve las reservas, pero no puede borrarlas: ORA-01031
SELECT COUNT(*) AS reservas FROM turismouq.reserva;
DELETE FROM turismouq.reserva WHERE id_reserva = 1;

-- 2.4 No ve los pagos (no tiene ningún permiso sobre PAGO): ORA-00942
SELECT COUNT(*) FROM turismouq.pago;


-- =====================================================================
-- 3. GERENTE: lee todo, no cambia nada
-- =====================================================================
CONNECT u_gerente/Gerente2026@localhost:1521/XEPDB1

-- 3.1 Ve la ocupación y los ingresos
SELECT nombre_comercial, municipio, anio, mes, pct_ocupacion
FROM   turismouq.mv_ocupacion_mensual
WHERE  anio = 2025 AND mes = 12
ORDER BY pct_ocupacion DESC
FETCH FIRST 5 ROWS ONLY;

SELECT SUM(monto) AS recaudo_2025
FROM   turismouq.pago
WHERE  estado = 'EXITOSO'
AND    fecha_pago >= DATE '2025-01-01' AND fecha_pago < DATE '2026-01-01';

-- 3.2 Intenta cambiar una tarifa: ORA-01031
UPDATE turismouq.tarifa SET valor_noche = 1 WHERE id_tarifa = 1;


-- =====================================================================
-- 4. AUDITOR: solo lectura de la auditoría
-- =====================================================================
CONNECT u_auditor/Auditor2026@localhost:1521/XEPDB1

-- 4.1 Ve el cambio que hizo el administrador en la prueba 2.1
SELECT operacion, id_tarifa, valor_anterior, valor_nuevo, usuario_bd,
       TO_CHAR(fecha_cambio, 'DD/MM/YYYY HH24:MI:SS') AS fecha_cambio
FROM   turismouq.auditoria_tarifa
WHERE  usuario_bd = 'U_ADMIN_ALOJ'
ORDER BY id_auditoria;

-- 4.2 Intenta borrar la auditoría para tapar el cambio: ORA-01031
DELETE FROM turismouq.auditoria_tarifa;


-- =====================================================================
-- 5. Se devuelve la tarifa a su valor (también queda auditado)
-- =====================================================================
CONNECT u_admin_aloj/AdminAloj2026@localhost:1521/XEPDB1
UPDATE turismouq.tarifa SET valor_noche = valor_noche - 1000 WHERE id_tarifa = 1;
COMMIT;


-- =====================================================================
-- 6. Perfil: pruebas a mano (no van con F5)
-- =====================================================================
-- 6.1 FAILED_LOGIN_ATTEMPTS = 3
--   En SQL Developer crear una conexión con u_gerente y una clave mala y
--   probarla 3 veces: ORA-01017 (usuario o clave inválidos). Al cuarto
--   intento, aunque la clave sea buena: ORA-28000 (la cuenta está
--   bloqueada). Para desbloquearla, con XE_SYSTEM:
--     ALTER USER u_gerente ACCOUNT UNLOCK
--
-- 6.2 SESSIONS_PER_USER = 2
--   Abrir tres hojas no compartidas (Ctrl+Shift+N) con una conexión de
--   u_recepcion. La tercera responde ORA-02391 (se excedió el límite de
--   sesiones simultáneas).
--
-- 6.3 IDLE_TIME = 15
--   Dejar una sesión de u_recepcion quieta más de 15 minutos y luego
--   correr cualquier consulta: ORA-02396 (se excedió el tiempo máximo de
--   inactividad).
