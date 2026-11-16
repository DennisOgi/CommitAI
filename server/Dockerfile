FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    APP_ENV=production

WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY commitai ./commitai

# Run as an unprivileged user.
RUN useradd --create-home --uid 10001 commitai && chown -R commitai /app
USER commitai

# Hosts like Render / Railway / Fly tell the app which port to use via $PORT; default 8000.
ENV PORT=8000
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD python -c "import os,urllib.request,sys; sys.exit(0 if urllib.request.urlopen(f'http://127.0.0.1:{os.environ.get(\"PORT\",\"8000\")}/health', timeout=4).status == 200 else 1)"

# One worker: the scheduler and bot subprocesses live in the API process.
# Scale out with more containers behind a load balancer (see README).
CMD ["sh", "-c", "exec uvicorn commitai.api:app --host 0.0.0.0 --port ${PORT:-8000} --proxy-headers --forwarded-allow-ips '*' --no-server-header"]
