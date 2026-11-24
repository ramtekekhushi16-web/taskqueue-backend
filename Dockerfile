FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
WORKDIR /srv/taskqueue

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
COPY migrations ./migrations
COPY alembic.ini .

RUN groupadd --system taskqueue && useradd --system --gid taskqueue --home-dir /srv/taskqueue taskqueue \
    && chown -R taskqueue:taskqueue /srv/taskqueue
USER taskqueue

EXPOSE 8000
CMD ["sh", "-c", "alembic upgrade head && uvicorn app.main:app --host 0.0.0.0 --port 8000"]
