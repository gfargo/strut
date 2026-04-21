import os

import psycopg
from fastapi import FastAPI, HTTPException

app = FastAPI(title="STACK_NAME_PLACEHOLDER")

DATABASE_URL = os.environ.get("DATABASE_URL", "")


@app.get("/")
def root():
    return {"service": "STACK_NAME_PLACEHOLDER", "status": "ok"}


@app.get("/health")
def health():
    if not DATABASE_URL:
        raise HTTPException(status_code=503, detail="DATABASE_URL not configured")
    try:
        with psycopg.connect(DATABASE_URL, connect_timeout=3) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"db unreachable: {exc}") from exc
    return {"status": "ok", "db": "up"}
