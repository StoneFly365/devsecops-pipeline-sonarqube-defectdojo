-- Crea la base de datos de DefectDojo en el mismo servidor PostgreSQL
CREATE DATABASE defectdojo
    WITH OWNER = sonar
    ENCODING = 'UTF8'
    LC_COLLATE = 'en_US.utf8'
    LC_CTYPE = 'en_US.utf8'
    TEMPLATE = template0;

GRANT ALL PRIVILEGES ON DATABASE defectdojo TO sonar;
