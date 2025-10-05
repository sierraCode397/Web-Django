# Aplicación Django sencilla con SQL Server (Developer) en Docker

Este repositorio de ejemplo contiene una aplicación Django mínima (`myproject`) con una app llamada `core` que expone dos endpoints JSON para **listar** y **crear** objetos `Item`. La base de datos usada es **SQL Server (Developer)** ejecutada en Docker. También incluí `Dockerfile`, `docker-compose.yml` y un `entrypoint.sh` simple para poner todo en marcha.

> **Nota:** los containers para SQL Server requieren que el driver ODBC de Microsoft esté instalado en la imagen del contenedor de Django (esto está contemplado en el `Dockerfile`). Este setup es para desarrollo y aprendizaje.

---

## Estructura del proyecto

```
├── myproject
│   ├── core
│   │   ├── admin.py
│   │   ├── apps.py
│   │   ├── migrations
│   │   ├── models.py
│   │   ├── urls.py
│   │   └── views.py
│   ├── docker-compose.yml
│   ├── Dockerfile
│   ├── Dockerfile.sqlserver
│   ├── entrypoint.sh
│   ├── manage.py
│   ├── myproject
│   │   ├── asgi.py
│   │   ├── __init__.py
│   │   ├── __pycache__
│   │   ├── settings.py
│   │   ├── urls.py
│   │   └── wsgi.py
│   ├── requirements.txt
│   └── venv
│       ├── bin
│       ├── include
│       ├── lib
│       ├── lib64 -> lib
│       └── pyvenv.cfg
└── README.md

```

---

## docker-compose.yml

```yaml
version: '3.8'
services:
  db:
    build:
      context: .
      dockerfile: Dockerfile.sqlserver
    container_name: sqlserver_dev
    environment:
      - ACCEPT_EULA=Y
      - SA_PASSWORD=YourStrong!Passw0rd
    ports:
      - "1433:1433"
    volumes:
      - sqlserver-data:/var/opt/mssql

  web:
    build: .
    container_name: django_web
    depends_on:
      - db
    env_file: .env.example
    ports:
      - "8000:8000"
    volumes:
      - .:/code
    entrypoint: ["/bin/bash", "/code/entrypoint.sh"]

volumes:
  sqlserver-data:

```

---

## Dockerfile

```dockerfile
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /code

RUN apt-get update && apt-get install -y \
    curl \
    gnupg2 \
    apt-transport-https \
    ca-certificates \
    freetds-bin \
    unixodbc-dev \
    build-essential \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /usr/share/keyrings/microsoft-prod.gpg
RUN echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/debian/11/prod bullseye main" \
    > /etc/apt/sources.list.d/mssql-release.list

RUN apt-get update \
    && ACCEPT_EULA=Y apt-get install -y msodbcsql17 \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /code/
RUN pip install --upgrade pip \
    && pip install --no-cache-dir -r /code/requirements.txt

COPY . /code/

RUN chmod +x /code/entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/code/entrypoint.sh"]
CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]
```

## Dockerfile.sqlserver

```dockerfile
FROM mcr.microsoft.com/mssql/server:2019-latest

ENV ACCEPT_EULA=Y
ENV SA_PASSWORD=YourStrong!Passw0rd

USER root

# Instalar sqlcmd y tsql (freetds)
RUN apt-get update && \
    apt-get install -y mssql-tools unixodbc-dev freetds-bin && \
    echo 'export PATH="$PATH:/opt/mssql-tools/bin"' >> /etc/bash.bashrc && \
    rm -rf /var/lib/apt/lists/*

USER mssql

```


---

## requirements.txt

```
Django>=4.2
mssql-django
pyodbc
```

---

## .env.example

```
# Django
SECRET_KEY=dev-secret-key
DEBUG=1
ALLOWED_HOSTS=*

# SQL Server
DB_NAME=django_db
DB_USER=sa
DB_PASSWORD=YourStrong!Passw0rd
DB_HOST=db
DB_PORT=1433
```

---

## entrypoint.sh

```bash
#!/bin/bash
set -e

DB_HOST=db
DB_PORT=1433
DB_USER=sa
DB_PASSWORD='YourStrong!Passw0rd'
DB_NAME=django_db

echo "Esperando y asegurando que SQL Server esté accesible y que la BD '$DB_NAME' exista..."

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
```

---

## manage.py

```python
#!/usr/bin/env python
import os
import sys

if __name__ == '__main__':
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'myproject.settings')
    from django.core.management import execute_from_command_line
    execute_from_command_line(sys.argv)
```

---

## myproject/settings.py (resaltado — sólo lo esencial)

```python
import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = os.getenv('SECRET_KEY', 'dev-secret-key')
DEBUG = os.getenv('DEBUG', '1') == '1'
ALLOWED_HOSTS = os.getenv('ALLOWED_HOSTS', '*').split(',')

INSTALLED_APPS = [
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'core',
]

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

ROOT_URLCONF = 'myproject.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

WSGI_APPLICATION = 'myproject.wsgi.application'

DATABASES = {
    'default': {
        'ENGINE': 'mssql',
        'NAME': os.getenv('DB_NAME', 'django_db'),
        'USER': os.getenv('DB_USER', 'sa'),
        'PASSWORD': os.getenv('DB_PASSWORD', 'YourStrong!Passw0rd'),
        'HOST': os.getenv('DB_HOST', 'db'),
        'PORT': os.getenv('DB_PORT', '1433'),
        'OPTIONS': {
            'driver': 'ODBC Driver 17 for SQL Server',
        },
    }
}

# Internacionalización y estáticos (mínimos)
LANGUAGE_CODE = 'en-us'
TIME_ZONE = 'UTC'
USE_I18N = True
USE_L10N = True
USE_TZ = True

STATIC_URL = '/static/'
```

---

## myproject/urls.py

```python
from django.contrib import admin
from django.urls import path, include

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/', include('core.urls')),
]
```

---

## core/apps.py

```python
from django.apps import AppConfig

class CoreConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'core'
```

---

## core/models.py

```python
from django.db import models

class Item(models.Model):
    name = models.CharField(max_length=200)
    description = models.TextField(blank=True)

    def __str__(self):
        return self.name
```

---

## core/views.py

```python
from django.http import JsonResponse, HttpResponseNotAllowed
from django.views.decorators.csrf import csrf_exempt
import json

from .models import Item

@csrf_exempt
def items_list(request):
    if request.method == 'GET':
        items = list(Item.objects.values('id', 'name', 'description'))
        return JsonResponse({'items': items})

    if request.method == 'POST':
        try:
            body = request.body.decode('utf-8')
            if not body:
                return JsonResponse({'error': 'Empty body'}, status=400)
            payload = json.loads(body)
            item = Item.objects.create(
                name=payload.get('name', 'Unnamed'),
                description=payload.get('description', '')
            )
            return JsonResponse(
                {'id': item.id, 'name': item.name, 'description': item.description},
                status=201
            )
        except json.JSONDecodeError:
            return JsonResponse({'error': 'Invalid JSON'}, status=400)
        except Exception as e:
            return JsonResponse({'error': str(e)}, status=500)

    return HttpResponseNotAllowed(['GET', 'POST'])
```

---

## core/urls.py

```python
from django.urls import path
from . import views

urlpatterns = [
    path('items/', views.items_list, name='items_list'),
]
```

---

## Pasos para ejecutar (resumen)

1. Copia el repo a una carpeta local.
2. Edita `.env.example` y asegúrate de que `DB_PASSWORD` coincida con la contraseña del servicio `db` en `docker-compose.yml` (en este ejemplo `YourStrong!Passw0rd`).
3. Construye y levanta los servicios:

```bash
docker compose up --build

```

4. Entra al contenedor web si necesitas correr comandos manuales:

```bash
docker compose down -v
docker exec -it --user root sqlserver_dev bash
docker exec -it sqlserver_dev /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P 'YourStrong!Passw0rd'
```

5. Prueba los endpoints:

* `http://localhost:8000/admin` — lista items
* `http://localhost:8000/api/items/`
