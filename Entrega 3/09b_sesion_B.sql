-- TurismoUQ - Entrega 3 - Concurrencia: SESIÓN B
-- Abrir en OTRA hoja de trabajo NO compartida (Ctrl+Shift+N) de TurismoUQ.
-- Correr cada paso seleccionándolo y con Ctrl+Enter, en el orden de la
-- tabla de tiempos. La sesión A está en 09a_sesion_A.sql.

SET SERVEROUTPUT ON


-- ======================= EXPERIMENTO 1: ANTES (sin FOR UPDATE) ========

-- T2 (B): mientras A está en su pausa de 20 segundos. B también ve la
--         habitación libre (A todavía no ha guardado) y guarda de una vez.
EXEC sp_reservar_sin_bloqueo(p_id_cliente => 6, p_pausa => 0)

-- T4 (B): confirmar DESPUÉS de que A termine y haga COMMIT.
-- Resultado: las dos reservas quedan guardadas. Habitación vendida dos veces.
COMMIT;


-- ======================= EXPERIMENTO 2: DESPUÉS (con FOR UPDATE) ======

-- T6 (B): mientras A está en su pausa. B se queda ESPERANDO en el
--         FOR UPDATE (la hoja muestra que sigue ejecutando). Tomar la
--         captura en este momento. Sigue sola cuando A haga COMMIT (T7):
--         ya ve la reserva de A y responde ORA-20002.
EXEC sp_reservar_con_bloqueo(p_id_cliente => 6, p_pausa => 0)

-- T8 (B): cerrar la transacción de B
ROLLBACK;
