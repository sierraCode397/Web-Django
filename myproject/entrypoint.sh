#!/bin/bash
set -e

DB_HOST=db
DB_PORT=1433
DB_USER=sa
DB_PASSWORD='YourStrong!Passw0rd'
DB_NAME=django_db

echo "Esperando y asegurando que SQL Server esté accesible y que la BD '$DB_NAME' exista..."

# 1) esperar a que SQL Server acepte conexiones
# 2) conectarnos a master y crear la DB si no existe (con autocommit)
python - <<PY
import time, sys
try:
    import pyodbc
except Exception:
    print("ERROR: pyodbc no está disponible dentro del contenedor. Añade 'pyodbc' a requirements.txt y reconstruye la imagen.", file=sys.stderr)
    sys.exit(1)

host = "${DB_HOST}"
port = "${DB_PORT}"
user = "${DB_USER}"
pwd = "${DB_PASSWORD}"
dbname = "${DB_NAME}"

conn_str = f"DRIVER={{ODBC Driver 17 for SQL Server}};SERVER={host},{port};UID={user};PWD={pwd};TrustServerCertificate=yes;DATABASE=master"

# Intentar conectar varias veces (hasta ~120s)
conn = None
for attempt in range(60):
    try:
        conn = pyodbc.connect(conn_str, timeout=5)
        # IMPORTANT: habilitar autocommit para poder ejecutar CREATE DATABASE
        conn.autocommit = True
        print(f"Conectado a SQL Server en intento {attempt+1}")
        break
    except Exception as e:
        print("SQL Server no listo todavía (intentando)...", file=sys.stderr)
        time.sleep(2)
else:
    print("No se pudo conectar a SQL Server después de varios intentos.", file=sys.stderr)
    sys.exit(1)

try:
    cursor = conn.cursor()
    # Ejecutar CREATE DATABASE en autocommit (no dentro de transacción)
    cursor.execute(f"IF DB_ID(N'{dbname}') IS NULL CREATE DATABASE [{dbname}]")
    print("Base de datos asegurada:", dbname)
finally:
    try:
        cursor.close()
    except Exception:
        pass
    try:
        conn.close()
    except Exception:
        pass
PY

echo "Aplicando migraciones..."
# Para makemigrations se ejecute automáticamente, descomenta la siguiente línea:
# python manage.py makemigrations core || true
python manage.py migrate --noinput || true

echo "Creando superusuario por defecto si no existe y poblando items de ejemplo..."
python manage.py shell <<END
from django.contrib.auth import get_user_model
from core.models import Item

User = get_user_model()
if not User.objects.filter(username='admin').exists():
    User.objects.create_superuser('admin', 'admin@example.com', 'hola123')

if not Item.objects.exists():
    Item.objects.create(name='Item 1', description='Descripción del Item 1')
    Item.objects.create(name='Item 2', description='Descripción del Item 2')
    Item.objects.create(name='Item 3', description='Descripción del Item 3')
END

echo "Iniciando servidor Django..."
exec python manage.py runserver 0.0.0.0:8000

