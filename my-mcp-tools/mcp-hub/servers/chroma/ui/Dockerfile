FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
COPY templates/ templates/
ENV PYTHONUNBUFFERED=1
# Matches chroma-mcp's HOME (see that Dockerfile) so both containers' Chroma default embedding
# function cache lands in the same place on the shared chroma_onnx_cache volume (compose.yaml).
# This container runs as root (no USER directive) so no permission setup is needed here, just
# the matching path.
ENV HOME=/home/chroma
RUN mkdir -p "$HOME"
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
