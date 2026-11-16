-- TurismoUQ - Bases de Datos II (2026-2), grupo 01N
-- Equipo: Andrés Ospina Vera, Juan Esteban Cuervo Jimenez
-- Script 0: usuario dueño del esquema
-- Se corre UNA vez, con la conexión XE_SYSTEM (usuario SYSTEM) apuntando al
-- contenedor XEPDB1 (service name XEPDB1, no SID). Completo con F5.
-- Después todos los scripts 01 a 10 se corren con el usuario TURISMOUQ, y el
-- 11 otra vez con SYSTEM.

SET SERVEROUTPUT ON

-- 0. Confirmar que estamos en XEPDB1 y no en el contenedor raíz (CDB$ROOT)
SELECT SYS_CONTEXT('USERENV', 'CON_NAME') AS contenedor,
       USER                               AS usuario
FROM   dual;


-- 1. Borrar el usuario si ya existe (el script se puede volver a correr)
-- Ojo: esto borra también todas sus tablas y datos.
DECLARE
  v_existe PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_existe FROM dba_users WHERE username = 'TURISMOUQ';
  IF v_existe > 0 THEN
    EXECUTE IMMEDIATE 'DROP USER turismouq CASCADE';
    DBMS_OUTPUT.PUT_LINE('Usuario TURISMOUQ borrado');
  END IF;
END;
/


-- 2. Crear el usuario dueño del esquema
CREATE USER turismouq IDENTIFIED BY "Turismo2026"
  DEFAULT TABLESPACE users
  TEMPORARY TABLESPACE temp
  QUOTA UNLIMITED ON users;


-- 3. Permisos que necesita para todas las entregas
--   Entrega 1: tablas y vistas
--   Entrega 2: paquete, disparadores, tablespace, vista materializada y su
--              refresco programado (CREATE JOB)
--   Entrega 3: procedimientos, vistas e índices (vienen con CREATE TABLE)
GRANT CREATE SESSION,
      CREATE TABLE,
      CREATE VIEW,
      CREATE SEQUENCE,
      CREATE PROCEDURE,
      CREATE TRIGGER,
      CREATE TYPE,
      CREATE SYNONYM,
      CREATE MATERIALIZED VIEW,
      CREATE JOB,
      CREATE TABLESPACE,
      UNLIMITED TABLESPACE
TO turismouq;


-- 4. Revisión
SELECT username, account_status, default_tablespace
FROM   dba_users
WHERE  username = 'TURISMOUQ';

SELECT privilege
FROM   dba_sys_privs
WHERE  grantee = 'TURISMOUQ'
ORDER BY privilege;
