FROM python:3.11-slim

WORKDIR /app

# --- NEW: Install system build dependencies ---
RUN apt-get update && apt-get install -y \
    build-essential \
    poppler-utils \
    && rm -rf /var/lib/apt/lists/*

COPY app/requirements.txt .

# Upgrade pip first, then install requirements
RUN pip install --upgrade pip
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .

EXPOSE 8000
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
