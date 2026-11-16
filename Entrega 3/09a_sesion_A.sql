-- TurismoUQ - Entrega 3 - Concurrencia: SESIÓN A
-- Abrir en una hoja de trabajo NO compartida (Ctrl+Shift+N) de TurismoUQ.
-- Correr cada paso seleccionándolo y con Ctrl+Enter (o F5 sobre la
-- selección), en el orden de la tabla de tiempos T1, T2, ...
-- La sesión B está en 09b_sesion_B.sql.

SET SERVEROUTPUT ON


-- ======================= EXPERIMENTO 1: ANTES (sin FOR UPDATE) ========

-- T1 (A): revisa, ve la habitación libre y se queda 20 segundos "pensando"
--         antes de guardar. Apenas se lance, pasar a la sesión B (T2).
EXEC sp_reservar_sin_bloqueo(p_id_cliente => 5, p_pausa => 20)

-- T3 (A): cuando A termine, confirmar
COMMIT;

-- (B también hace COMMIT en T4. Después correr la sección 4 del script 09:
--  salen DOS reservas de la misma habitación y las mismas noches.)


-- ======================= EXPERIMENTO 2: DESPUÉS (con FOR UPDATE) ======

-- T5 (A): bloquea la habitación con FOR UPDATE, revisa y se queda 20
--         segundos antes de guardar. Apenas se lance, pasar a B (T6).
EXEC sp_reservar_con_bloqueo(p_id_cliente => 5, p_pausa => 20)

-- T7 (A): cuando A termine, confirmar. En ese momento B se desbloquea.
COMMIT;
